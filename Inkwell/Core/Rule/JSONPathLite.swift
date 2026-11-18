import Foundation

// MARK: - 精简 JSONPath
//
// 覆盖 Legado 里常见的写法：
//   $.data.list[*].name
//   $.data.name
//   $..name                   递归下降
//   data.list[0].name         省略 $. 前缀
//   $.items[*].title
//   $['data']['name']
//   $..book[?(@.id==1)].name  (只支持等值)

final class JSONPathLite {

    enum Segment {
        case key(String)
        case index(Int)
        case wildcard
        case recursiveKey(String)
        case filter(key: String, value: String)
        case sliceAll
    }

    static func parse(_ path: String) -> [Segment] {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("$") { p = String(p.dropFirst()) }
        var segs: [Segment] = []
        var i = p.startIndex

        while i < p.endIndex {
            let ch = p[i]
            if ch == "." {
                if p.index(after: i) < p.endIndex, p[p.index(after: i)] == "." {
                    // 递归下降
                    i = p.index(i, offsetBy: 2)
                    // 读 key 直到 . 或 [
                    var key = ""
                    while i < p.endIndex, p[i] != "." , p[i] != "[" {
                        key.append(p[i]); i = p.index(after: i)
                    }
                    if key.isEmpty { segs.append(.wildcard) }
                    else { segs.append(.recursiveKey(key)) }
                    continue
                }
                i = p.index(after: i)
                continue
            }
            if ch == "[" {
                guard let close = p[i...].firstIndex(of: "]") else { break }
                let inner = String(p[p.index(after: i)..<close]).trimmingCharacters(in: .whitespaces)
                if inner == "*" {
                    segs.append(.wildcard)
                } else if inner.hasPrefix("?(") {
                    // [?(@.key=='v')]
                    var body = inner
                    body = body.replacingOccurrences(of: "?(", with: "")
                    body = body.replacingOccurrences(of: ")", with: "")
                    body = body.replacingOccurrences(of: "@.", with: "")
                    let parts = body.components(separatedBy: "==")
                    if parts.count == 2 {
                        let k = parts[0].trimmingCharacters(in: .whitespaces)
                        var v = parts[1].trimmingCharacters(in: .whitespaces)
                        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                        segs.append(.filter(key: k, value: v))
                    } else {
                        segs.append(.wildcard)
                    }
                } else if inner.hasPrefix("'") || inner.hasPrefix("\"") {
                    let k = inner.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    segs.append(.key(k))
                } else if let n = Int(inner) {
                    segs.append(.index(n))
                } else if inner.contains(":") {
                    segs.append(.sliceAll)
                } else {
                    segs.append(.key(inner))
                }
                i = p.index(after: close)
                continue
            }
            // 裸 key
            var key = ""
            while i < p.endIndex, p[i] != "." , p[i] != "[" {
                key.append(p[i]); i = p.index(after: i)
            }
            if !key.isEmpty { segs.append(.key(key)) }
            if i < p.endIndex, p[i] == "." { i = p.index(after: i) }
        }
        return segs
    }

    static func query(_ path: String, json: Any) -> [Any] {
        var current: [Any] = [json]
        for seg in parse(path) {
            var next: [Any] = []
            for node in current {
                switch seg {
                case .key(let k):
                    if let d = node as? [String: Any], let v = d[k] { next.append(v) }
                case .index(let n):
                    if let a = node as? [Any] {
                        let idx = n < 0 ? a.count + n : n
                        if idx >= 0, idx < a.count { next.append(a[idx]) }
                    }
                case .wildcard, .sliceAll:
                    if let a = node as? [Any] { next.append(contentsOf: a) }
                    else if let d = node as? [String: Any] { next.append(contentsOf: d.values) }
                case .recursiveKey(let k):
                    next.append(contentsOf: recursiveFind(k, in: node))
                case .filter(let k, let v):
                    if let a = node as? [Any] {
                        for item in a {
                            if let d = item as? [String: Any],
                               let val = d[k], "\(val)" == v {
                                next.append(item)
                            }
                        }
                    }
                }
            }
            current = next
            if current.isEmpty { return [] }
        }
        return current
    }

    private static func recursiveFind(_ key: String, in node: Any, depth: Int = 0) -> [Any] {
        guard depth < 12 else { return [] }
        var out: [Any] = []
        if let d = node as? [String: Any] {
            if let v = d[key] { out.append(v) }
            for (_, v) in d { out.append(contentsOf: recursiveFind(key, in: v, depth: depth + 1)) }
        } else if let a = node as? [Any] {
            for v in a { out.append(contentsOf: recursiveFind(key, in: v, depth: depth + 1)) }
        }
        return out
    }

    /// 结果拍平成字符串数组
    static func queryStrings(_ path: String, json: Any) -> [String] {
        query(path, json: json).map { stringify($0) }
    }

    static func stringify(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                return d == d.rounded() ? String(Int64(d)) : String(d)
            }
            return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        case is NSNull: return ""
        case let d as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: d) {
                return String(data: data, encoding: .utf8) ?? ""
            }
            return ""
        case let a as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: a) {
                return String(data: data, encoding: .utf8) ?? ""
            }
            return ""
        default: return "\(v)"
        }
    }
}
