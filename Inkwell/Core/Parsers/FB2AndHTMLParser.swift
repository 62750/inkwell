import Foundation
import SwiftSoup

// MARK: - FB2 / HTML / Markdown 解析

enum FB2Parser {

    static func parse(url: URL) throws -> ParsedBook {
        let data = try Data(contentsOf: url)
        let text = CharsetDetector.decode(data)
        guard let doc = try? SwiftSoup.parse(text, "", Parser.xmlParser()) else {
            throw ParseError.corrupt("FB2 XML 解析失败")
        }

        var title = ""
        if let els = try? doc.select("book-title"), els.size() > 0,
           let t = try? els.get(0).text() {
            title = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var author = ""
        if let authors = try? doc.select("author"), authors.size() > 0 {
            let el = authors.get(0)
            var parts: [String] = []
            for tag in ["first-name", "middle-name", "last-name", "nickname"] {
                if let sub = try? el.select(tag), sub.size() > 0,
                   let t = try? sub.get(0).text(), !t.isEmpty {
                    parts.append(t.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            author = parts.joined(separator: " ")
        }

        var intro = ""
        if let els = try? doc.select("annotation"), els.size() > 0,
           let t = try? els.get(0).text() {
            intro = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var chapters: [ParsedChapter] = []
        let sections = SelectorBridge.query("body > section", in: doc)
        if sections.isEmpty {
            var whole = ""
            if let body = try? doc.select("body"), body.size() > 0,
               let t = try? body.get(0).text() {
                whole = t
            }
            chapters = ChapterSplitter.split(whole).chapters
        } else {
            for (i, sec) in sections.enumerated() {
                var sectionTitle = ""
                if let titles = try? sec.select("title"), titles.size() > 0,
                   let t = try? titles.get(0).text() {
                    sectionTitle = t.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let body = paragraphs(of: sec)
                guard !body.isEmpty else { continue }
                chapters.append(ParsedChapter(title: sectionTitle.isEmpty ? "第\(i + 1)节" : sectionTitle,
                                              text: body))
            }
        }
        if chapters.isEmpty { throw ParseError.empty }
        return ParsedBook(title: title.isEmpty ? "未命名" : title,
                          author: author, intro: intro,
                          chapters: chapters, format: .fb2)
    }

    private static func paragraphs(of el: Element) -> String {
        var lines: [String] = []
        for p in SelectorBridge.query("p", in: el) {
            if let t = try? p.text() {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
        }
        if lines.isEmpty {
            if let t = try? el.text() {
                return t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }
        return lines.joined(separator: "\n\n")
    }
}

enum HTMLTextParser {

    static func parse(url: URL) throws -> ParsedBook {
        let data = try Data(contentsOf: url)
        let html = CharsetDetector.decode(data)
        return parse(html: html, title: url.deletingPathExtension().lastPathComponent,
                     format: .html)
    }

    static func parse(html: String, title: String, format: BookFormat) -> ParsedBook {
        guard let doc = try? SwiftSoup.parse(html) else {
            let split = ChapterSplitter.split(StringExt.stripHTML(html))
            return ParsedBook(title: title, chapters: split.chapters, format: format)
        }

        let contentSelectors = ["#content", "#chaptercontent", ".content", ".read-content",
                                "#booktext", ".text", "article", "#article", ".article-content"]
        var bodyText = ""
        for sel in contentSelectors {
            if let els = try? doc.select(sel), els.size() > 0,
               let t = try? els.get(0).text(), t.count > 100 {
                bodyText = t
                break
            }
        }

        var docTitle = ""
        if let t = try? doc.title() { docTitle = t.trimmingCharacters(in: .whitespacesAndNewlines) }

        var chapters: [ParsedChapter] = []
        if bodyText.isEmpty {
            let full = paragraphs(of: doc.body() ?? doc)
            if full.count > 3000 {
                chapters = ChapterSplitter.split(full).chapters
            } else {
                chapters = [ParsedChapter(title: docTitle.isEmpty ? title : docTitle, text: full)]
            }
        } else {
            chapters = [ParsedChapter(title: title,
                                      text: StringExt.normalizeWhitespace(bodyText))]
        }
        return ParsedBook(title: docTitle.isEmpty ? title : docTitle,
                          chapters: chapters, format: format)
    }

    static func paragraphs(of el: Element) -> String {
        var lines: [String] = []
        for child in el.getChildNodes() {
            guard let e = child as? Element else { continue }
            let tag = e.tagName().lowercased()
            if ["script", "style", "nav", "footer", "header", "aside"].contains(tag) { continue }
            if ["p", "div", "h1", "h2", "h3", "h4", "h5", "li", "blockquote"].contains(tag) {
                if let t = try? e.text() {
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { lines.append(trimmed) }
                }
                if tag == "div" {
                    let inner = paragraphs(of: e)
                    if !inner.isEmpty { lines.append(inner) }
                }
            }
        }
        let joined = lines.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return StringExt.normalizeWhitespace(joined)
    }
}

enum MarkdownParser {

    static func parse(url: URL) throws -> ParsedBook {
        let data = try Data(contentsOf: url)
        let raw = CharsetDetector.decode(data)
        let lines = raw.components(separatedBy: "\n")
        var chapters: [ParsedChapter] = []
        var currentTitle = url.deletingPathExtension().lastPathComponent
        var buffer: [String] = []

        func flush() {
            let t = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                chapters.append(ParsedChapter(title: currentTitle, text: stripMarkdown(t)))
            }
            buffer.removeAll()
        }

        for line in lines {
            if line.hasPrefix("#") {
                let content = String(line.drop(while: { $0 == "#" }))
                    .trimmingCharacters(in: .whitespaces)
                if !content.isEmpty {
                    flush()
                    currentTitle = content
                    continue
                }
            }
            buffer.append(line)
        }
        flush()

        if chapters.isEmpty {
            return ParsedBook(title: currentTitle,
                              chapters: ChapterSplitter.split(raw).chapters,
                              format: .markdown, fullText: raw)
        }
        return ParsedBook(title: currentTitle,
                          chapters: chapters, format: .markdown, fullText: raw)
    }

    static func stripMarkdown(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^>\\s?", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^[-*+]\\s+", with: "· ", options: .regularExpression)
        return StringExt.normalizeWhitespace(t)
    }
}
