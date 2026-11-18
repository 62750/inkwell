import Foundation
import SwiftSoup

// MARK: - MOBI / AZW / AZW3（PalmDB + PalmDOC）
//
// 覆盖 Kindle 系最常见的无 DRM 文件：
//   compression 1 (无压缩) / 2 (PalmDOC LZ77)
//   HUFF/CDIC(17480) 和加密文件（encryption != 0）不支持，会明确报出来。

enum MobiParser {

    static func parse(url: URL) throws -> ParsedBook {
        let data = try Data(contentsOf: url)
        let pdb = try PalmDatabase(data: data)

        guard pdb.type == "BOOK" else { throw ParseError.corrupt("不是 Palm BOOK 格式") }
        guard pdb.records.count > 1 else { throw ParseError.corrupt("记录数不足") }

        let rec0 = pdb.records[0]
        guard rec0.count >= 16 else { throw ParseError.corrupt("PalmDOC 头缺失") }

        let compression = Int(rec0.u16(0))
        let textLength = Int(rec0.u32(4))
        let recordCount = Int(rec0.u16(8))
        let encryption = Int(rec0.u16(12))

        guard encryption == 0 else {
            throw ParseError.unsupported("DRM 加密的 MOBI/AZW3")
        }

        // MOBI header
        var encoding = "CP1252"
        var firstImageIndex = 0
        var fullName = ""
        if rec0.count > 20, rec0.ascii(16, 4) == "MOBI" {
            let headerLen = Int(rec0.u32(20))
            let textEncoding = Int(rec0.u32(28))
            encoding = textEncoding == 65001 ? "UTF-8" : "CP1252"
            if rec0.count > 108 { firstImageIndex = Int(rec0.u32(108)) }
            if rec0.count > 92 {
                let nameOffset = Int(rec0.u32(84))
                let nameLength = Int(rec0.u32(88))
                // fullNameOffset/fullNameLength 相对 rec0 起点（MOBI 规范里是绝对偏移）
                if nameOffset > 0, nameLength > 0, nameOffset + nameLength <= rec0.count {
                    let bytes = rec0.subdata(in: nameOffset..<(nameOffset + nameLength))
                    fullName = CharsetDetector.decode(bytes, declared: encoding)
                }
            }
            _ = headerLen
        }

        // 解压文本记录
        var out = Data()
        let textRecords = min(recordCount, pdb.records.count - 1)
        for i in 1...max(1, textRecords) {
            guard i < pdb.records.count else { break }
            let rec = pdb.records[i]
            switch compression {
            case 1:
                out.append(rec)
            case 2:
                out.append(PalmDoc.decompress(rec))
            case 17480:
                throw ParseError.unsupported("HUFF/CDIC 压缩的 MOBI")
            default:
                throw ParseError.unsupported("未知压缩方式 \(compression)")
            }
        }
        if textLength > 0, out.count > textLength {
            out = out.prefix(textLength)
        }

        let html = decode(out, encoding: encoding)
        let text = htmlToText(html)
        let split = ChapterSplitter.split(text)

        // 封面：firstImageIndex 之后的第一个图片记录
        var cover: Data? = nil
        if firstImageIndex > 0, firstImageIndex < pdb.records.count {
            let candidate = pdb.records[firstImageIndex]
            if isImage(candidate) { cover = candidate }
        }

        let name = fullName.isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : fullName

        return ParsedBook(title: name,
                          coverData: cover,
                          chapters: split.chapters,
                          format: .mobi,
                          fullText: text)
    }

    private static func decode(_ data: Data, encoding: String) -> String {
        if encoding == "UTF-8" {
            if let s = String(data: data, encoding: .utf8) { return s }
        }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return CharsetDetector.decode(data)
    }

    private static func isImage(_ d: Data) -> Bool {
        guard d.count > 4 else { return false }
        if d[0] == 0xFF, d[1] == 0xD8 { return true }                       // jpeg
        if d[0] == 0x89, d[1] == 0x50, d[2] == 0x4E, d[3] == 0x47 { return true } // png
        if d[0] == 0x47, d[1] == 0x49, d[2] == 0x46 { return true }         // gif
        return false
    }

    static func htmlToText(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else {
            return StringExt.stripHTML(html)
        }
        // 删掉 mbp:pagebreak 之类的分页标记，转成空行
        _ = try? doc.select("mbp\\:pagebreak").forEach { _ in }
        var lines: [String] = []
        let body = doc.body() ?? doc
        func walk(_ el: Element) {
            for child in el.getChildNodes() {
                if let e = child as? Element {
                    let tag = e.tagName().lowercased()
                    if ["script", "style", "svg"].contains(tag) { continue }
                    if ["p", "div", "h1", "h2", "h3", "h4", "li", "blockquote"].contains(tag) {
                        let t = ((try? e.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { lines.append(t) }
                        walk(e)
                    } else {
                        walk(e)
                    }
                }
            }
        }
        walk(body)
        if lines.isEmpty { return StringExt.stripHTML(html) }
        return StringExt.normalizeWhitespace(lines.joined(separator: "\n\n"))
    }
}

// MARK: - PalmDOC 解压

enum PalmDoc {
    static func decompress(_ input: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](input)
        var i = 0
        out.reserveCapacity(bytes.count * 2)

        while i < bytes.count {
            let b = Int(bytes[i]); i += 1
            if b == 0 { break }
            if b >= 1 && b <= 8 {
                let n = min(b, bytes.count - i)
                out.append(contentsOf: bytes[i..<(i + n)])
                i += n
            } else if b <= 0x7F {
                out.append(UInt8(b))
            } else if b >= 0xC0 {
                out.append(0x20)
                out.append(UInt8(b ^ 0x80))
            } else {
                guard i < bytes.count else { break }
                let b2 = Int(bytes[i]); i += 1
                let combined = (b << 8) | b2
                let distance = (combined >> 3) & 0x07FF
                let length = (combined & 0x07) + 3
                guard distance > 0, distance <= out.count else { break }
                let start = out.count - distance
                let outBytes = [UInt8](out)
                for k in 0..<length {
                    let idx = start + k
                    if idx < outBytes.count {
                        out.append(outBytes[idx])
                    } else {
                        // 重叠复制
                        let last = out.count - distance
                        if last >= 0, last < out.count {
                            out.append([UInt8](out)[last])
                        }
                    }
                }
            }
        }
        return out
    }
}

// MARK: - PalmDB 读取

struct PalmDatabase {
    let name: String
    let type: String
    let creator: String
    let records: [Data]

    init(data: Data) throws {
        guard data.count > 86 else { throw ParseError.corrupt("PalmDB 头过短") }
        name = String(data: data.subdata(in: 0..<32), encoding: .utf8)?
            .replacingOccurrences(of: "\0", with: "") ?? ""
        type = data.ascii(60, 4)
        creator = data.ascii(64, 4)
        let numRecords = Int(data.u16(76))
        guard numRecords > 0, numRecords < 100_000 else {
            throw ParseError.corrupt("记录数异常")
        }
        let listStart = 78
        guard data.count >= listStart + numRecords * 8 else {
            throw ParseError.corrupt("记录表越界")
        }

        var offsets: [Int] = []
        for i in 0..<numRecords {
            let off = Int(data.u32(listStart + i * 8))
            offsets.append(off)
        }
        var result: [Data] = []
        result.reserveCapacity(numRecords)
        for i in 0..<numRecords {
            let start = offsets[i]
            let end = (i + 1 < numRecords) ? offsets[i + 1] : data.count
            guard start < data.count, end <= data.count, end >= start else {
                result.append(Data())
                continue
            }
            result.append(data.subdata(in: start..<end))
        }
        records = result
    }
}

// MARK: - Data 读取辅助

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes { ptr -> UInt16 in
            let base = ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt16(base[0]) << 8 | UInt16(base[1])
        }
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { ptr -> UInt32 in
            let base = ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return (UInt32(base[0]) << 24) | (UInt32(base[1]) << 16)
                | (UInt32(base[2]) << 8) | UInt32(base[3])
        }
    }

    func ascii(_ offset: Int, _ length: Int) -> String {
        guard offset + length <= count else { return "" }
        return String(data: subdata(in: offset..<(offset + length)), encoding: .ascii) ?? ""
    }
}
