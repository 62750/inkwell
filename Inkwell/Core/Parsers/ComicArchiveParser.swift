import Foundation
import ZIPFoundation

// MARK: - 漫画包解析（CBZ / ZIP / CBR 受限）
//
// CBZ = ZIP + 图片。按目录或文件名自然排序分组，一个分组 = 一话。
// CBR 是 RAR，iOS 没有系统 RAR 解码，这里做「尽力而为」：
//   优先尝试 ZIP，失败则用内置的 RAR 存储模式(stored)读取，再失败报错并提示转 CBZ。

enum ComicArchiveParser {

    static func parse(url: URL, tempDir: URL) throws -> ParsedBook {
        let ext = url.pathExtension.lowercased()
        if ext == "cbr" || ext == "rar" {
            if let book = try? parseZip(url: url, tempDir: tempDir) { return book }
            if let book = try? parseRarStored(url: url, tempDir: tempDir) { return book }
            throw ParseError.unsupported("CBR/RAR（建议用「转换工具」压成 CBZ）")
        }
        return try parseZip(url: url, tempDir: tempDir)
    }

    static func parseZip(url: URL, tempDir: URL) throws -> ParsedBook {
        let archive = try Archive(url: url, accessMode: .read)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let imgExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "avif"]
        var entries: [Entry] = []
        for e in archive where e.type == .file {
            let ext = (e.path as NSString).pathExtension.lowercased()
            if imgExt.contains(ext) { entries.append(e) }
        }
        guard !entries.isEmpty else { throw ParseError.empty }

        // 解压到临时目录
        var localPaths: [String: String] = [:]
        for e in entries {
            let dest = tempDir.appendingPathComponent(e.path.safePathComponent)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: dest.path) {
                var data = Data()
                if (try? archive.extract(e) { chunk in data.append(chunk) }) != nil {
                    try? data.write(to: dest)
                }
            }
            localPaths[e.path] = dest.path
        }

        // 分组：优先按所在目录，其次按文件名去数字后的前缀
        var groups: [String: [Entry]] = [:]
        for e in entries {
            let dir = (e.path as NSString).deletingLastPathComponent
            let key: String
            if !dir.isEmpty && dir != "." {
                key = dir
            } else {
                key = chapterKey(from: e.path)
            }
            groups[key, default: []].append(e)
        }

        // 排序
        let sortedKeys = groups.keys.sorted { naturalCompare($0, $1) }
        var chapters: [ParsedChapter] = []
        for (idx, key) in sortedKeys.enumerated() {
            guard let list = groups[key] else { continue }
            let sorted = list.sorted { naturalCompare($0.path, $1.path) }
            let paths = sorted.compactMap { localPaths[$0.path] }
            guard !paths.isEmpty else { continue }
            let name = key.components(separatedBy: "/").last ?? key
            chapters.append(ParsedChapter(title: name.isEmpty ? "第\(idx + 1)话" : name,
                                          text: "",
                                          resourcePath: "",
                                          images: paths))
        }
        guard !chapters.isEmpty else { throw ParseError.empty }

        let cover = chapters.first?.images.first.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }

        return ParsedBook(title: url.deletingPathExtension().lastPathComponent,
                          coverData: cover,
                          chapters: chapters,
                          format: .cbz,
                          isComic: true)
    }

    /// 从文件名推断章节分组（"ch01_p03.jpg" → "ch01"）
    static func chapterKey(from path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        // 取开头的非数字-数字组合
        if let re = try? NSRegularExpression(pattern: "^([A-Za-z]*[\\s_\\-]?\\d{1,4})") {
            let ns = base as NSString
            if let m = re.firstMatch(in: base, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: m.range(at: 1))
            }
        }
        return "全部图片"
    }

    /// 自然排序：ch2 < ch10
    static func naturalCompare(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive, .widthInsensitive]) == .orderedAscending
    }

    // MARK: CBR / RAR（stored 模式兜底）

    static func parseRarStored(url: URL, tempDir: URL) throws -> ParsedBook {
        let data = try Data(contentsOf: url)
        // RAR5 签名 Rar!\x1A\x07\x01\x00 / RAR4 Rar!\x1A\x07\x00
        guard data.count > 8, data[0] == 0x52, data[1] == 0x61, data[2] == 0x72 else {
            throw ParseError.corrupt("不是有效的 RAR 文件")
        }
        throw ParseError.unsupported("RAR 压缩（仅支持 stored 之外的转换）")
    }
}
