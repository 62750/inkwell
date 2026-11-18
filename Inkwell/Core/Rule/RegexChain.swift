import Foundation

// MARK: - 规则后处理链
//
// Legado 规则尾部可以挂任意多个正则：
//   规则##正则##替换      正则匹配到的替换成「替换」
//   规则##正则           只保留匹配部分（多个匹配拼接）
//   规则##正则###         匹配到的直接删除（替换为空）
//   规则##正则##$1        支持捕获组
// 还有 {{ }} 变量、<js>...</js> 内嵌脚本。

enum RegexChain {

    /// 拆分 "core##p1##r1##p2##r2"  → (core, [(p1,r1),(p2,r2)])
    /// 说明：Legado 里成对出现，最后单个 pattern 表示「取匹配」
    static func partition(_ rule: String) -> (core: String, pairs: [(String, String?)]) {
        // 需要跳过引号内的 ##
        var parts: [String] = []
        var buf = ""
        var quote: Character?
        var i = rule.startIndex
        while i < rule.endIndex {
            let ch = rule[i]
            if let q = quote {
                buf.append(ch)
                if ch == q { quote = nil }
                i = rule.index(after: i)
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; buf.append(ch); i = rule.index(after: i); continue }
            if ch == "#", rule.index(after: i) < rule.endIndex, rule[rule.index(after: i)] == "#" {
                parts.append(buf)
                buf = ""
                i = rule.index(i, offsetBy: 2)
                continue
            }
            buf.append(ch)
            i = rule.index(after: i)
        }
        parts.append(buf)

        guard parts.count > 1 else { return (rule, []) }
        let core = parts[0]
        var pairs: [(String, String?)] = []
        var idx = 1
        while idx < parts.count {
            let pattern = parts[idx]
            if idx + 1 < parts.count {
                pairs.append((pattern, parts[idx + 1]))
                idx += 2
            } else {
                pairs.append((pattern, nil))
                idx += 1
            }
        }
        return (core, pairs)
    }

    /// 应用正则链到一组结果
    static func apply(_ input: [String], pairs: [(String, String?)]) -> [String] {
        guard !pairs.isEmpty else { return input }
        var current = input
        for (pattern, replacement) in pairs {
            let opts: NSRegularExpression.Options = [.dotMatchesLineSeparators]
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { continue }
            if let replacement {
                current = current.map { s in
                    let ns = s as NSString
                    let tpl = replacement.isEmpty ? "" : replacement
                    return re.stringByReplacingMatches(
                        in: s, range: NSRange(location: 0, length: ns.length),
                        withTemplate: tpl)
                }
            } else {
                // 只保留匹配
                current = current.flatMap { s -> [String] in
                    let ns = s as NSString
                    let ms = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
                    if ms.isEmpty { return [] }
                    return ms.map { m in
                        if m.numberOfRanges > 1 {
                            return ns.substring(with: m.range(at: 1))
                        }
                        return ns.substring(with: m.range)
                    }
                }
            }
        }
        return current
    }

    /// 取第一个捕获组的常用简写：正则只写 pattern 时取 group(1)
    static func firstGroup(_ input: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = input as NSString
        guard let m = re.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        if m.numberOfRanges > 1 { return ns.substring(with: m.range(at: 1)) }
        return ns.substring(with: m.range)
    }

    /// 清理正文里的广告行 / 站点声明
    static func cleanContent(_ text: String, extraPatterns: [String] = []) -> String {
        var t = text
        let defaults = [
            "(?m)^\\s*(本章未完|请记住本站|手机用户请|加入书签|投推荐票|一秒记住)[^\\n]*$",
            "(?m)^\\s*第?\\s*[（(]?\\s*\\d+\\s*[/／]\\s*\\d+\\s*[)）]?\\s*页\\s*$",
            "(?m)^\\s*(www\\.|m\\.)[a-zA-Z0-9\\-.]+\\s*$",
            "(?m)^\\s*[a-zA-Z0-9\\-]+\\.(com|net|cc|org|xyz|vip|cn|la|info)\\s*$"
        ]
        for p in defaults + extraPatterns {
            t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return StringExt.normalizeWhitespace(t)
    }
}
