import Foundation

// MARK: - 章节自动识别
//
// 不用规则也行：多套正则族并行打分，取命中最多且最稳的那一族。
// 目标：中文网文 / 轻小说 / 出版书 / 英文小说 / 无标题流水文 都能切。

struct SplitResult: Sendable {
    var chapters: [ParsedChapter]
    var usedPattern: String
    var confidence: Double
}

enum ChapterSplitter {

    struct Pattern {
        let name: String
        let regex: String
        /// 命中后是否需要再看下一行是否为空/短，提高准确率
        let requireFollowingBlank: Bool
        let weight: Double
    }

    static let patterns: [Pattern] = [
        // 中文：第X章 / 第一百二十回 / 第三节
        Pattern(name: "中文第N章",
                regex: "(?m)^[\\t ]{0,6}(第[零〇一二三四五六七八九十百千万两0-9０-９]{1,12}[章節节回話话卷集部篇幕][\\t ]{0,4}[^\\n]{0,40})$",
                requireFollowingBlank: false, weight: 1.0),
        // 中文：序章 / 楔子 / 番外
        Pattern(name: "中文特殊章",
                regex: "(?m)^[\\t ]{0,6}((?:序章|序言|序|楔子|引子|前言|尾声|后记|後記|番外|外传|外傳|终章|終章|大结局|大結局)[\\t ]{0,4}[^\\n]{0,30})$",
                requireFollowingBlank: false, weight: 0.9),
        // 英文：Chapter 12 / CHAPTER XII
        Pattern(name: "English Chapter",
                regex: "(?m)^[\\t ]{0,4}((?:Chapter|CHAPTER|Ch\\.)[\\t ]+[0-9IVXLCDMivxlcdm]{1,8}[^\\n]{0,50})$",
                requireFollowingBlank: false, weight: 1.0),
        // 英文：Part / Prologue / Epilogue
        Pattern(name: "English Special",
                regex: "(?m)^[\\t ]{0,4}((?:Prologue|Epilogue|Part[\\t ]+[0-9IVXLCDM]+|Interlude)[^\\n]{0,40})$",
                requireFollowingBlank: false, weight: 0.85),
        // 纯数字 + 分隔符：12、标题
        Pattern(name: "数字编号",
                regex: "(?m)^[\\t ]{0,6}([0-9０-９]{1,4}[、.．，,：:\\-—][\\t ]{0,3}[^\\n]{1,40})$",
                requireFollowingBlank: false, weight: 0.7),
        // 括号编号：【12】标题
        Pattern(name: "括号编号",
                regex: "(?m)^[\\t ]{0,6}([【\\[（(][0-9０-９]{1,4}[】\\]）)][\\t ]{0,3}[^\\n]{0,40})$",
                requireFollowingBlank: false, weight: 0.7),
        // 卷一 标题
        Pattern(name: "卷",
                regex: "(?m)^[\\t ]{0,6}(卷[零〇一二三四五六七八九十百0-9０-９]{1,6}[\\t ]{0,4}[^\\n]{0,40})$",
                requireFollowingBlank: false, weight: 0.8)
    ]

    /// 主入口
    static func split(_ text: String) -> SplitResult {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var best: (Pattern, [NSTextCheckingResult], Double)?

        for p in patterns {
            guard let re = try? NSRegularExpression(
                pattern: p.regex,
                options: [.anchorsMatchLines, .caseInsensitive]) else { continue }
            let ns = normalized as NSString
            let matches = re.matches(in: normalized,
                                     range: NSRange(location: 0, length: ns.length))
            guard matches.count >= 2 else { continue }

            // 过滤掉疑似正文误命中：标题行不能太长、不能以句号结尾
            var valid: [NSTextCheckingResult] = []
            for m in matches {
                let line = ns.substring(with: m.range(at: 1))
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.count > 60 { continue }
                if t.hasSuffix("。") || t.hasSuffix("，") { continue }
                if t.contains("　　") { continue }
                valid.append(m)
            }
            guard valid.count >= 2 else { continue }

            // 密度评分：平均每章字数是否合理（300 ~ 30000）
            let totalLen = normalized.count
            let avg = Double(totalLen) / Double(valid.count)
            var densityScore = 1.0
            if avg < 200 { densityScore = 0.2 }
            else if avg < 500 { densityScore = 0.6 }
            else if avg > 80_000 { densityScore = 0.3 }

            let score = p.weight * densityScore * min(1.0, Double(valid.count) / 10.0 + 0.5)
            if best == nil || score > best!.2 {
                best = (p, valid, score)
            }
        }

        if let (pattern, matches, score) = best, score > 0.25 {
            let chapters = buildChapters(normalized, matches: matches)
            if chapters.count >= 2 {
                return SplitResult(chapters: chapters, usedPattern: pattern.name,
                                   confidence: min(1.0, score))
            }
        }

        // 失败：按固定长度切（每 4000 字一段），或整本一章
        let fallback = splitByLength(normalized, chunkSize: 4000)
        return SplitResult(chapters: fallback, usedPattern: "固定长度", confidence: 0.2)
    }

    static func buildChapters(_ text: String, matches: [NSTextCheckingResult]) -> [ParsedChapter] {
        let ns = text as NSString
        var chapters: [ParsedChapter] = []

        // 第一个标题前若有内容，归入「前言」
        let firstStart = matches.first?.range.location ?? 0
        if firstStart > 200 {
            let head = ns.substring(with: NSRange(location: 0, length: firstStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty {
                chapters.append(ParsedChapter(title: "前言", text: head,
                                              range: 0..<firstStart))
            }
        }

        for (i, m) in matches.enumerated() {
            let titleRange = m.range(at: 1)
            let title = ns.substring(with: titleRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyStart = m.range.location + m.range.length
            let bodyEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            guard bodyEnd > bodyStart else { continue }
            let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(ParsedChapter(title: cleanTitle(title), text: body,
                                          range: bodyStart..<bodyEnd))
        }
        return chapters
    }

    static func cleanTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "[\\t ]{2,}", with: " ", options: .regularExpression)
        // 去掉标题尾部装饰
        t = t.replacingOccurrences(of: "[\\-—_=*~·]{2,}$", with: "", options: .regularExpression)
        return t.isEmpty ? "无标题" : t
    }

    static func splitByLength(_ text: String, chunkSize: Int) -> [ParsedChapter] {
        guard text.count > chunkSize else {
            return [ParsedChapter(title: "全文", text: text, range: 0..<text.count)]
        }
        var chapters: [ParsedChapter] = []
        var offset = 0
        var index = 1
        let chars = Array(text)
        while offset < chars.count {
            let end = min(offset + chunkSize, chars.count)
            var cut = end
            // 尽量在段落处断开
            if end < chars.count {
                var probe = end
                while probe > offset + chunkSize / 2, chars[probe - 1] != "\n" { probe -= 1 }
                if probe > offset + chunkSize / 2 { cut = probe }
            }
            let seg = String(chars[offset..<cut])
            chapters.append(ParsedChapter(title: "第 \(index) 段", text: seg,
                                          range: offset..<cut))
            offset = cut
            index += 1
        }
        return chapters
    }
}
