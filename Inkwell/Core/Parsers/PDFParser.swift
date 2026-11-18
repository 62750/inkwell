import Foundation
import PDFKit
import UIKit

// MARK: - PDF 解析
//
// 两条路线：
//   1. 文本型 PDF：抽每页文字，按页面/章节正则切章
//   2. 图片型 PDF（扫描件 / 漫画）：抽不到文字就按页渲染，阅读器逐页显示

enum PDFParser {

    struct Result {
        var book: ParsedBook
        var isImageBased: Bool
        var pageCount: Int
    }

    static func parse(url: URL) throws -> ParsedBook {
        guard let doc = PDFDocument(url: url) else { throw ParseError.corrupt("PDF 无法打开") }
        let pageCount = doc.pageCount
        guard pageCount > 0 else { throw ParseError.empty }

        var pageTexts: [String] = []
        var totalChars = 0
        for i in 0..<pageCount {
            let t = doc.page(at: i)?.string ?? ""
            pageTexts.append(t)
            totalChars += t.trimmingCharacters(in: .whitespacesAndNewlines).count
        }

        // 平均每页少于 30 个字符 → 判定为图片型
        let isImageBased = totalChars < pageCount * 30

        if isImageBased {
            // 图片型：每页一章，正文字段存 "pdf://page/N"
            var chapters: [ParsedChapter] = []
            for i in 0..<pageCount {
                chapters.append(ParsedChapter(title: "第 \(i + 1) 页",
                                              text: "",
                                              resourcePath: "pdf://page/\(i)"))
            }
            return ParsedBook(title: url.deletingPathExtension().lastPathComponent,
                              chapters: chapters, format: .pdf, isComic: true)
        }

        // 文本型：先按页拼接，再交给章节识别
        let full = pageTexts.enumerated().map { idx, t in
            "\n\n<!-- page \(idx) -->\n" + t
        }.joined()
        let cleaned = StringExt.normalizeWhitespace(full)

        var split = ChapterSplitter.split(cleaned)
        if split.chapters.count < 2 {
            // 按页分章
            var chapters: [ParsedChapter] = []
            for (i, t) in pageTexts.enumerated() {
                let body = StringExt.normalizeWhitespace(t)
                guard !body.isEmpty else { continue }
                chapters.append(ParsedChapter(title: "第 \(i + 1) 页", text: body,
                                              resourcePath: "pdf://page/\(i)"))
                if body.count > 20 { }
            }
            split = SplitResult(chapters: chapters, usedPattern: "按页", confidence: 0.5)
        }

        return ParsedBook(title: url.deletingPathExtension().lastPathComponent,
                          chapters: split.chapters,
                          format: .pdf,
                          fullText: cleaned)
    }

    /// 渲染某一页为图片（图片型 PDF 阅读用）
    static func renderPage(url: URL, index: Int, maxWidth: CGFloat = 1600) -> UIImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(maxWidth / max(bounds.width, 1), 3.0)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }
}
