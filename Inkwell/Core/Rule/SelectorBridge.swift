import Foundation
import SwiftSoup

// MARK: - jsoup 风格选择器桥
//
// Legado 规则的主体语法是 "选择器@取值"：
//   class.book-list@tag.li@text
//   class.cover@tag.img@src
//   tag.h1@text
//   id.content@html
//   div#main > ul.list li@ownText
//
// 这里把它翻译成 SwiftSoup 的 CSS 查询再取值。

enum SelectorSegment {
    case css(String)
    case extract(String)
}

enum SelectorBridge {

    /// 把 Legado 规则拆成「选择器段 / 取值段」
    static func split(_ rule: String) -> [SelectorSegment] {
        let raw = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }

        var segments: [SelectorSegment] = []
        var buffer = ""
        var bracket = 0
        var quote: Character?

        func flush(asCSS: Bool) {
            let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard !t.isEmpty else { return }
            if asCSS {
                segments.append(.css(normalizeCSS(t)))
            } else {
                // 判断是取值方式还是继续选择
                if isExtractToken(t) {
                    segments.append(.extract(t))
                } else if looksLikeSelector(t) {
                    segments.append(.css(normalizeCSS(t)))
                } else {
                    segments.append(.extract(t))
                }
            }
        }

        for ch in raw {
            if let q = quote {
                buffer.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; buffer.append(ch); continue }
            if ch == "[" { bracket += 1; buffer.append(ch); continue }
            if ch == "]" { bracket -= 1; buffer.append(ch); continue }
            if ch == "@" && bracket == 0 {
                flush(asCSS: segments.isEmpty)
                continue
            }
            buffer.append(ch)
        }
        flush(asCSS: segments.isEmpty)
        return segments
    }

    static func isExtractToken(_ t: String) -> Bool {
        let lower = t.lowercased()
        switch lower {
        case "text", "textnodes", "owntext", "html", "outerhtml", "all", "content",
             "innerhtml", "tostring":
            return true
        default: return false
        }
    }

    static func looksLikeSelector(_ t: String) -> Bool {
        if t.hasPrefix("tag.") || t.hasPrefix("class.") || t.hasPrefix("id.") { return true }
        if t.hasPrefix(".") || t.hasPrefix("#") { return true }
        if t.hasPrefix(">") || t.hasPrefix(":") { return true }
        // 形如 div.list
        if t.contains(".") || t.contains(" ") || t.contains(">") || t.contains("[") {
            let firstToken = t.split(separator: ".").first.map(String.init) ?? t
            if firstToken.rangeOfCharacter(from: CharacterSet(charactersIn: " \t>#[]")) != nil {
                return true
            }
            if ["div", "span", "a", "li", "ul", "ol", "p", "img", "h1", "h2", "h3",
                "h4", "h5", "table", "tr", "td", "dl", "dd", "dt"].contains(firstToken) {
                return true
            }
        }
        return false
    }

    /// Legado 的 tag./class./id. 前缀转 CSS
    static func normalizeCSS(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "tag.", with: "#__TAG__#")
        t = t.replacingOccurrences(of: "class.", with: ".")
        t = t.replacingOccurrences(of: "id.", with: "#")
        t = t.replacingOccurrences(of: "#__TAG__#", with: "")
        // "tag.div" 处理完会变成 "div"；"a tag.span" 里的 tag. 也变空
        // 清理多余空格
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// 执行选择器链
    static func select(_ rule: String, in root: Element) -> [Element] {
        let segments = split(rule)
        guard let first = segments.first else { return [] }
        if case .css(let css) = first {
            var current: [Element] = query(css, in: root)
            for seg in segments.dropFirst() {
                switch seg {
                case .css(let next):
                    current = current.flatMap { query(next, in: $0) }
                case .extract:
                    // 选择阶段遇到取值段，停止
                    return current
                }
            }
            return current
        }
        return []
    }

    /// 取值：返回字符串结果集
    static func extract(_ rule: String, in root: Element) -> [String] {
        let segments = split(rule)
        guard !segments.isEmpty else { return [] }

        var elements: [Element] = []
        var extractKind = "text"
        var isElementStage = false   // 已进入取值段

        for (i, seg) in segments.enumerated() {
            switch seg {
            case .css(let css):
                if i == 0 {
                    elements = query(css, in: root)
                } else {
                    elements = elements.flatMap { query(css, in: $0) }
                }
                isElementStage = true
            case .extract(let kind):
                extractKind = kind
                isElementStage = true
            }
        }

        if elements.isEmpty { return [] }

        let lower = extractKind.lowercased()
        switch lower {
        case "text", "tostring":
            return elements.map { ((try? $0.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        case "textnodes":
            return elements.map { el in
                el.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "owntext":
            return elements.map { ($0.ownText()).trimmingCharacters(in: .whitespacesAndNewlines) }
        case "html", "innerhtml":
            return elements.map { (try? $0.html()) ?? "" }
        case "outerhtml":
            return elements.map { (try? $0.outerHtml()) ?? "" }
        case "all":
            return elements.map { (try? $0.outerHtml()) ?? "" }
        case "content":
            return elements.map { el in
                if hasAttrOf(el, "content") { return attrOf(el, "content") }
                return (try? el.html()) ?? ""
            }
        default:
            // 属性名
            return elements.compactMap { el in
                if hasAttrOf(el, extractKind) { return attrOf(el, extractKind) }
                let lowerAttr = extractKind.lowercased()
                if hasAttrOf(el, lowerAttr) { return attrOf(el, lowerAttr) }
                return nil
            }
        }
    }

    /// CSS 查询（带容错：多个候选、非法选择器降级）
    static func query(_ css: String, in root: Element) -> [Element] {
        let q = css.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if q == "*" { return allElementsOf(root) }
        if q.hasPrefix(">") {
            let sub = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            return root.children().toArray().flatMap { query(sub, in: $0) }
        }
        do {
            return try root.select(q).toArray()
        } catch {
            // 退化：如果是逗号分隔的多个选择器，逐个尝试
            if q.contains(",") {
                return q.split(separator: ",").flatMap { query(String($0), in: root) }
            }
            return []
        }
    }
}
