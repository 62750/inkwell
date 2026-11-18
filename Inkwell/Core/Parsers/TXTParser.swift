import Foundation

// MARK: - TXT 解析
// 三件事：编码探测、章节识别、超长文本的存储策略（只存路径 + 偏移，正文按需读取）

enum TXTParser {

    static func parse(url: URL) throws -> ParsedBook {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw ParseError.empty }
        let encoding = detectEncoding(data)
        var text = CharsetDetector.decode(data, declared: encoding)
        guard !text.isEmpty else { throw ParseError.empty }

        text = normalize(text)
        let split = ChapterSplitter.split(text)

        let title = url.deletingPathExtension().lastPathComponent
        return ParsedBook(title: cleanBookTitle(title),
                          author: "",
                          intro: "",
                          coverData: nil,
                          chapters: split.chapters,
                          format: .txt,
                          fullText: text)
    }

    static func parse(text raw: String, hint: String = "未命名") -> ParsedBook {
        let text = normalize(raw)
        let split = ChapterSplitter.split(text)
        return ParsedBook(title: hint, chapters: split.chapters,
                          format: .txt, fullText: text)
    }

    // MARK: 编码

    static func detectEncoding(_ data: Data) -> String? {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { return "UTF-8" }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE { return "UTF-16LE" }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF { return "UTF-16BE" }
        // 用前 64KB 抽样判断
        let sample = data.prefix(65536)
        if String(data: sample, encoding: .utf8) != nil { return "UTF-8" }
        return nil    // 交给 CharsetDetector 走探测链
    }

    // MARK: 文本规整

    static func normalize(_ input: String) -> String {
        var t = input
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\r", with: "\n")
        t = t.replacingOccurrences(of: "\u{FEFF}", with: "")
        t = t.replacingOccurrences(of: "\u{0000}", with: "")
        // 全角空格保留（中文首行缩进），但把只有空白的行压成空行
        t = t.replacingOccurrences(of: "(?m)^[\\t \\u{3000}]+$", with: "",
                                   options: .regularExpression)
        // 3+ 连续空行压成 1
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t
    }

    static func cleanBookTitle(_ s: String) -> String {
        var t = s
        // 去掉常见下载站后缀
        let patterns = [
            "[\\(\\[（【][^\\)\\]）】]{0,20}(?:完结|全本|精校|txt|TXT|下载|无弹窗|最新章节)[^\\)\\]）】]{0,20}[\\)\\]）】]",
            "(_|\\s)*(?:全本|完结|精校版|txt下载)$",
            "^(?:www\\.|m\\.)[a-zA-Z0-9.\\-]+[_\\-\\s]*"
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按章读取正文（大文件不整本进内存时用）
    static func readChapterText(fileURL: URL, range: Range<Int>) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let full = CharsetDetector.decode(data)
        let chars = Array(full)
        let lower = max(0, min(range.lowerBound, chars.count))
        let upper = max(lower, min(range.upperBound, chars.count))
        return String(chars[lower..<upper])
    }
}
