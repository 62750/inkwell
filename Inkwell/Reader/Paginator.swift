import Foundation
import UIKit
import CoreText

// MARK: - 分页排版引擎
//
// 用 NSLayoutManager 一次性完成排版，按行片段高度切页，
// 得到「第 n 页 → 字符区间」，翻页/定位进度都基于字符索引，换字号不丢位置。

struct PaginatedChapter: Sendable {
    var ranges: [NSRange]
    var text: String
    var totalHeight: CGFloat

    var pageCount: Int { ranges.count }

    func range(ofPage index: Int) -> NSRange {
        guard index >= 0, index < ranges.count else { return NSRange(location: 0, length: 0) }
        return ranges[index]
    }
}

final class Paginator {

    /// 同步分页（在后台线程调用）
    static func paginate(text: String,
                         settings: ReadingSettings,
                         size: CGSize,
                         indentFirstParagraph: Bool = true) -> PaginatedChapter {
        guard size.width > 10, size.height > 10 else {
            return PaginatedChapter(ranges: [NSRange(location: 0, length: (text as NSString).length)],
                                    text: text, totalHeight: 0)
        }

        let attributed = ParagraphStyleBuilder.attributed(text, settings: settings,
                                                          indent: indentFirstParagraph)
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: size.width,
                                                    height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        layout.ensureLayout(for: container)

        let fullRange = NSRange(location: 0, length: storage.length)
        let totalRect = layout.usedRect(for: container)
        let totalHeight = totalRect.height

        var pages: [NSRange] = []
        var pageStartChar = 0
        var pageTop: CGFloat = 0
        let pageHeight = size.height

        var index = 0
        let glyphCount = layout.numberOfGlyphs
        if glyphCount == 0 {
            return PaginatedChapter(ranges: [NSRange(location: 0, length: 0)],
                                    text: text, totalHeight: 0)
        }

        while index < glyphCount {
            var lineGlyphRange = NSRange()
            let lineRect = layout.lineFragmentRect(forGlyphAt: index,
                                                   effectiveRange: &lineGlyphRange)
            let lineBottom = lineRect.maxY
            if lineBottom > pageTop + pageHeight + 0.5, index > pageStartChar {
                // 当前行放不下 → 结束本页
                let charRange = layout.characterRange(
                    forGlyphRange: NSRange(location: pageStartChar, length: index - pageStartChar),
                    actualGlyphRange: nil)
                pages.append(charRange)
                pageStartChar = index
                pageTop = lineRect.minY
                continue
            }
            // 前进到下一行
            let advance = max(1, lineGlyphRange.length)
            index = lineGlyphRange.location + advance
        }

        let tailRange = layout.characterRange(forGlyphRange: NSRange(location: pageStartChar,
                                                                    length: glyphCount - pageStartChar),
                                              actualGlyphRange: nil)
        if tailRange.length > 0 || pages.isEmpty {
            pages.append(tailRange)
        }
        // 清掉空页
        pages = pages.filter { $0.length > 0 }
        if pages.isEmpty { pages = [NSRange(location: 0, length: 0)] }

        return PaginatedChapter(ranges: pages, text: text, totalHeight: totalHeight)
    }

    /// 根据字符偏移定位页码
    static func pageIndex(forCharacter offset: Int, in paginated: PaginatedChapter) -> Int {
        guard !paginated.ranges.isEmpty else { return 0 }
        for (i, r) in paginated.ranges.enumerated() {
            if offset < r.location + r.length { return i }
        }
        return paginated.ranges.count - 1
    }

    /// 渲染某一页的富文本（供 UITextView / UILabel 显示）
    static func pageAttributedString(paginated: PaginatedChapter,
                                     page index: Int,
                                     settings: ReadingSettings) -> NSAttributedString {
        guard index >= 0, index < paginated.ranges.count else { return NSAttributedString() }
        let ns = paginated.text as NSString
        let r = paginated.ranges[index]
        guard r.location + r.length <= ns.length else { return NSAttributedString() }
        let slice = ns.substring(with: r)
        // 页首段落不缩进（因为承接上一页），但若本页从章首开始则缩进
        let indent = index > 0 ? false : settings.firstLineIndent
        return ParagraphStyleBuilder.attributed(slice, settings: settings, indent: indent)
    }
}

// MARK: - 行首禁则处理
//
// CoreText 对中文标点的避头尾只做了一部分，这里在分段前做一次预处理：
// 行首不放 。，、；：？！）》」』】,...
// 行尾不放 （《「『【
// 做法：在可能断行的位置插入 WORD JOINER (U+2060) 或者替换为不换行形式。

enum Kinsoku {

    static let noLineStart: Set<Character> = Set("。，、；：？！）》」』】〕｝’”%,.;:?!)]}>")
    static let noLineEnd: Set<Character> = Set("（《「『【〔｛‘“([{<")

    /// 简易处理：把「行尾禁则字符」与后一个字绑定
    static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = ""
        out.reserveCapacity(text.count + text.count / 20)
        let chars = Array(text)
        for i in 0..<chars.count {
            let c = chars[i]
            if noLineEnd.contains(c), i + 1 < chars.count, chars[i + 1] != "\n" {
                out.append(c)
                out.append("\u{2060}")   // WORD JOINER 抑制断行
                continue
            }
            out.append(c)
        }
        return out
    }

    /// 更精细：避免标点出现在行首（依赖排版结果，这里只在段内做「标点前不断行」）
    static func bindPrecedingPunctuation(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        for i in 0..<chars.count {
            let c = chars[i]
            if noLineStart.contains(c), !out.isEmpty, out.last != "\n" {
                out.append("\u{2060}")
                out.append(c)
                continue
            }
            out.append(c)
        }
        return out
    }
}

// MARK: - 文本清洗（进入排版前）

enum ReaderTextPreparer {

    static func prepare(_ raw: String, settings: ReadingSettings) -> String {
        var t = raw
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\r", with: "\n")
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        // 去掉每行已有缩进，统一由排版控制
        if settings.firstLineIndent {
            t = t.replacingOccurrences(of: "(?m)^[\\u{3000} \\t]+", with: "",
                                       options: .regularExpression)
        }
        // 段间多余空行
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return Kinsoku.apply(t)
    }
}
