import Foundation

// MARK: - 宽松解码包装器
// Legado 书源里同一字段可能是 String / Int / Double / Bool，且经常带空值。
// 全部统一成 String，避免一份书源因为一个字段类型不对整包导入失败。

@propertyWrapper
struct AnyString: Codable, Hashable, Sendable {
    var wrappedValue: String

    init(wrappedValue: String = "") { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.wrappedValue = ""; return }
        if let s = try? c.decode(String.self) { self.wrappedValue = s; return }
        if let b = try? c.decode(Bool.self) { self.wrappedValue = b ? "true" : "false"; return }
        if let i = try? c.decode(Int.self) { self.wrappedValue = String(i); return }
        if let d = try? c.decode(Double.self) {
            self.wrappedValue = d == d.rounded() ? String(Int64(d)) : String(d)
            return
        }
        // 数组/字典字段（例如 loginUi）序列化回字符串，方便原样保存
        if let any = try? c.decode(AnyJSON.self) {
            self.wrappedValue = any.rawJSON ?? ""
            return
        }
        self.wrappedValue = ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

@propertyWrapper
struct AnyInt: Codable, Hashable, Sendable {
    var wrappedValue: Int

    init(wrappedValue: Int = 0) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self.wrappedValue = i; return }
        if let s = try? c.decode(String.self) {
            self.wrappedValue = Int(s.trimmingCharacters(in: .whitespaces)) ?? 0
            return
        }
        if let d = try? c.decode(Double.self) { self.wrappedValue = Int(d); return }
        if let b = try? c.decode(Bool.self) { self.wrappedValue = b ? 1 : 0; return }
        self.wrappedValue = 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

@propertyWrapper
struct AnyBool: Codable, Hashable, Sendable {
    var wrappedValue: Bool

    init(wrappedValue: Bool = true) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.wrappedValue = true; return }
        if let b = try? c.decode(Bool.self) { self.wrappedValue = b; return }
        if let i = try? c.decode(Int.self) { self.wrappedValue = i != 0; return }
        if let s = try? c.decode(String.self) {
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            self.wrappedValue = !(t == "false" || t == "0" || t == "" || t == "no")
            return
        }
        self.wrappedValue = true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

// MARK: - 任意 JSON 兜底（丢弃而不是抛错）

struct AnyJSON: Codable, Sendable {
    let rawJSON: String?
    let value: AnySendable?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            rawJSON = s; value = .string(s); return
        }
        if let a = try? c.decode([AnyJSON].self) {
            rawJSON = Self.encodeRaw(a.map { $0.value?.foundation ?? NSNull() })
            value = .array(a); return
        }
        if let d = try? c.decode([String: AnyJSON].self) {
            rawJSON = Self.encodeRaw(d.mapValues { $0.value?.foundation ?? NSNull() })
            value = .object(d); return
        }
        rawJSON = nil; value = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }

    private static func encodeRaw(_ any: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(any) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum AnySendable: Sendable {
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    var foundation: Any {
        switch self {
        case .string(let s): return s
        case .array(let a): return a.map { $0.value?.foundation ?? NSNull() }
        case .object(let d): return d.mapValues { $0.value?.foundation ?? NSNull() }
        }
    }
}

enum LenientDecoder {
    static func make() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return d
    }

    /// 容忍单个对象 / 数组 / 带 BOM / 尾逗号 的书源文件
    static func decodeSources(from data: Data) -> [BookSource] {
        var cleaned = data
        if cleaned.count >= 3, cleaned[0] == 0xEF, cleaned[1] == 0xBB, cleaned[2] == 0xBF {
            cleaned = cleaned.subdata(in: 3..<cleaned.count)
        }
        let decoder = make()
        if let arr = try? decoder.decode([BookSource].self, from: cleaned) { return arr }
        if let one = try? decoder.decode(BookSource.self, from: cleaned) { return [one] }
        // 包在 {"data": [...]} 里的情况
        if let raw = try? JSONSerialization.jsonObject(with: cleaned),
           let obj = raw as? [String: Any] {
            for key in ["data", "sources", "bookSources", "items", "list"] {
                if let inner = obj[key] {
                    let innerData = try? JSONSerialization.data(withJSONObject: inner)
                    if let d = innerData, let arr = try? decoder.decode([BookSource].self, from: d) {
                        return arr
                    }
                }
            }
            // 单条对象再试一次（去掉非法尾逗号）
            if let s = String(data: cleaned, encoding: .utf8) {
                let fixed = StringExt.removeTrailingCommas(s)
                if let d = fixed.data(using: .utf8),
                   let arr = try? decoder.decode([BookSource].self, from: d) {
                    return arr
                }
                if let d = fixed.data(using: .utf8),
                   let one = try? decoder.decode(BookSource.self, from: d) {
                    return [one]
                }
            }
        }
        return []
    }
}
