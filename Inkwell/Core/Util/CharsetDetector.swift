import Foundation

// MARK: - 编码探测
// 中文书源站点大量是 GBK / GB18030 / Big5，必须三级探测：
//   1) BOM
//   2) HTTP header / HTML meta
//   3) NSString 内置探测 + 兜底尝试表

enum CharsetDetector {

    static let fallbackEncodings: [String.Encoding] = [
        .utf8,
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue))),
        .unicode, .utf16LittleEndian, .utf16BigEndian, .isoLatin1
    ]

    static func decode(_ data: Data, declared: String? = nil) -> String {
        if data.isEmpty { return "" }

        // 1) BOM
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            return String(data: data, encoding: .utf16LittleEndian) ?? ""
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            return String(data: data, encoding: .utf16BigEndian) ?? ""
        }

        // 2) 声明的编码
        if let declared, let enc = encoding(named: declared),
           let s = String(data: data, encoding: enc) {
            return s
        }

        // 3) HTML meta / XML 声明
        if let head = String(data: data.prefix(4096), encoding: .isoLatin1),
           let cs = sniffDeclaredCharset(in: head),
           let enc = encoding(named: cs),
           let s = String(data: data, encoding: enc) {
            return s
        }

        // 4) 纯 UTF-8 直接通过（合法 UTF-8 概率极高）
        if let s = String(data: data, encoding: .utf8) { return s }

        // 5) NSString 探测
        var usedLossy: ObjCBool = false
        let detected = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding.utf8.rawValue,
                    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))).rawValue,
                    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.big5.rawValue))).rawValue
                ],
                .useOnlySuggestedEncodingsKey: false,
                .allowLossyKey: false
            ],
            convertedString: nil,
            usedLossyConversion: &usedLossy)

        if detected != 0,
           let s = String(data: data, encoding: String.Encoding(rawValue: detected)) {
            return s
        }

        // 6) 兜底
        for enc in fallbackEncodings {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func sniffDeclaredCharset(in head: String) -> String? {
        let patterns = [
            "<meta[^>]+charset\\s*=\\s*[\"']?([A-Za-z0-9_\\-]+)",
            "encoding\\s*=\\s*[\"']([A-Za-z0-9_\\-]+)[\"']"
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
               let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
               let r = Range(m.range(at: 1), in: head) {
                return String(head[r])
            }
        }
        return nil
    }

    static func encoding(named name: String) -> String.Encoding? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch n {
        case "utf-8", "utf8", "unicode-1-1-utf-8": return .utf8
        case "gbk", "gb2312", "gb-2312", "x-gbk", "cp936":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "gb18030", "gb-18030":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5", "big-5", "cp950":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "utf-16", "utf16": return .utf16
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "iso-8859-1", "latin1", "windows-1252": return .isoLatin1
        case "ascii", "us-ascii": return .ascii
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
            if cf != kCFStringEncodingInvalidId {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            }
            return nil
        }
    }
}

// MARK: - 日志（书源调试用）

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let level: Level
    let tag: String
    let message: String
    enum Level: String, Sendable { case debug = "D", info = "I", warn = "W", error = "E" }
}

actor LogCenter {
    static let shared = LogCenter()
    private var entries: [LogEntry] = []
    private let cap = 800

    func append(_ level: LogEntry.Level, tag: String, _ message: String) {
        entries.append(LogEntry(date: Date(), level: level, tag: tag, message: message))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        #if DEBUG
        print("[\(level.rawValue)][\(tag)] \(message)")
        #endif
    }

    func snapshot() -> [LogEntry] { entries }
    func clear() { entries.removeAll() }
}

func logD(_ tag: String, _ msg: @autoclosure () -> String) {
    let m = msg()
    Task { await LogCenter.shared.append(.debug, tag: tag, m) }
}
func logE(_ tag: String, _ msg: @autoclosure () -> String) {
    let m = msg()
    Task { await LogCenter.shared.append(.error, tag: tag, m) }
}
