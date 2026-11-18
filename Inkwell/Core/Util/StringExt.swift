import Foundation

// MARK: - 字符串工具

enum StringExt {

    /// 去掉 JSON 里 `}` / `]` 前的尾逗号（书源手写常见错误）
    static func removeTrailingCommas(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        let chars = Array(s)
        var i = 0
        // 记录是否在字符串字面量内，避免误伤 "... ,}" 这样的正文
        var inString = false
        var escaped = false
        while i < chars.count {
            let ch = chars[i]
            if inString {
                out.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                i += 1
                continue
            }
            if ch == "\"" { inString = true; out.append(ch); i += 1; continue }
            if ch == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    i += 1   // 丢掉这个逗号
                    continue
                }
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    /// HTML 实体解码 + 标签清理
    static func stripHTML(_ input: String) -> String {
        var s = input
        s = s.replacingOccurrences(of: "(?s)<(script|style)[^>]*>.*?</\\1>",
                                   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        return s
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        let map: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
            "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}", "&hellip;": "\u{2026}",
            "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&middot;": "\u{00B7}",
            "&times;": "\u{00D7}", "&divide;": "\u{00F7}", "&copy;": "\u{00A9}",
            "&reg;": "\u{00AE}", "&trade;": "\u{2122}", "&emsp;": "\u{3000}",
            "&ensp;": "\u{2002}", "&thinsp;": "\u{2009}"
        ]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        // &#123; / &#x1F600;
        if t.contains("&#") {
            let pattern = "&#(x?)([0-9A-Fa-f]{1,6});"
            if let re = try? NSRegularExpression(pattern: pattern) {
                var result = ""
                var last = t.startIndex
                re.enumerateMatches(in: t, range: NSRange(t.startIndex..., in: t)) { m, _, _ in
                    guard let m, let full = Range(m.range, in: t),
                          let hr = Range(m.range(at: 1), in: t),
                          let vr = Range(m.range(at: 2), in: t) else { return }
                    result += t[last..<full.lowerBound]
                    let isHex = !t[hr].isEmpty
                    let digits = String(t[vr])
                    if let code = UInt32(digits, radix: isHex ? 16 : 10),
                       let scalar = Unicode.Scalar(code) {
                        result.append(Character(scalar))
                    }
                    last = full.upperBound
                }
                result += t[last...]
                t = result
            }
        }
        return t
    }

    /// 归一化空白，同时保留段落分隔（\n\n）
    static func normalizeWhitespace(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\r", with: "\n")
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        t = t.replacingOccurrences(of: "\u{3000}\u{3000}", with: "\u{3000}")
        // 行内多余空格
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        // 3 个以上换行压成 2 个
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        // 每行首尾空白
        let lines = t.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 相对 URL 转绝对
    static func absolute(_ link: String, base: String) -> String {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return l }
        if l.hasPrefix("http://") || l.hasPrefix("https://") { return l }
        if l.hasPrefix("//") { return (base.hasPrefix("https") ? "https:" : "http:") + l }
        if l.hasPrefix("data:") || l.hasPrefix("blob:") { return l }
        guard let baseURL = URL(string: base) else { return l }
        if l.hasPrefix("/") {
            var comp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            comp?.path = l
            comp?.query = nil
            return comp?.url?.absoluteString ?? l
        }
        return URL(string: l, relativeTo: baseURL)?.absoluteString ?? l
    }

    /// Legado 的 {{ }} 变量、{{$.x}} JSON 取值
    static func expandVariables(_ template: String, key: String, page: Int,
                                baseUrl: String, variables: [String: String]) -> String {
        var out = template
        out = out.replacingOccurrences(of: "{{key}}", with: urlEncode(key))
        out = out.replacingOccurrences(of: "{{page}}", with: String(page))
        out = out.replacingOccurrences(of: "{{baseUrl}}", with: baseUrl)
        for (k, v) in variables {
            out = out.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        return out
    }

    static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "?#&=%+")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func urlDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    /// 从 URL 推断文件扩展名
    static func fileExtension(of url: String) -> String {
        guard let u = URL(string: url) else {
            return (url as NSString).pathExtension.lowercased()
        }
        let ext = u.pathExtension.lowercased()
        if ext.isEmpty { return "" }
        return ext
    }

    /// 安全的文件名
    static func safeFileName(_ s: String, maxLength: Int = 80) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|\n\r\t")
        var t = s.components(separatedBy: invalid).joined(separator: "_")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > maxLength { t = String(t.prefix(maxLength)) }
        return t.isEmpty ? "untitled" : t
    }

    static func matches(_ pattern: String, in text: String,
                        options: NSRegularExpression.Options = []) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }

    /// 中文数字转阿拉伯数字（章节号识别用）
    static func chineseNumberToInt(_ s: String) -> Int? {
        let map: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "壹": 1, "贰": 2,
            "叁": 3, "肆": 4, "伍": 5, "陆": 6, "柒": 7, "捌": 8, "玖": 9
        ]
        let units: [Character: Int] = [
            "十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000, "万": 10000
        ]
        if s.isEmpty { return nil }
        if let n = Int(s) { return n }
        var total = 0, section = 0, number = 0
        for ch in s {
            if let d = map[ch] {
                number = d
            } else if let u = units[ch] {
                if u == 10000 {
                    section = (section + number) * u
                    total += section
                    section = 0
                } else {
                    section += (number == 0 ? 1 : number) * u
                }
                number = 0
            } else {
                return nil
            }
        }
        return total + section + number
    }

    /// 估算字符串显示宽度（中文算 2）
    static func displayWidth(_ s: String) -> Int {
        var w = 0
        for scalar in s.unicodeScalars {
            w += scalar.value > 0x2E80 ? 2 : 1
        }
        return w
    }
}
