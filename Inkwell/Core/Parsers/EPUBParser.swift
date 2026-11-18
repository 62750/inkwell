import Foundation
import ZIPFoundation
import SwiftSoup

// MARK: - EPUB 2 / EPUB 3 解析
//
// 流程：container.xml → OPF → metadata + manifest + spine
//      目录优先 nav.xhtml（EPUB3），退化到 toc.ncx（EPUB2），再退化到按 spine 拆分
// 图片资源统一解到临时目录，供阅读器加载

final class EPUBParser {

    struct ManifestItem {
        var id: String
        var href: String
        var mediaType: String
        var properties: String
    }

    private let archive: Archive
    private let tempDir: URL
    private var opfPath: String = ""
    private var opfDir: String = ""
    private var manifest: [String: ManifestItem] = [:]
    private var spine: [String] = []
    private var tocMap: [String: String] = [:]     // href(不含锚) → 标题

    init(url: URL, tempDir: URL) throws {
        guard let a = try? Archive(url: url, accessMode: .read) else {
            throw ParseError.corrupt("无法打开 EPUB 容器")
        }
        archive = a
        self.tempDir = tempDir
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func parse() throws -> ParsedBook {
        let container = try readEntryText("META-INF/container.xml")
        guard let rootPath = firstMatch(container,
                                        pattern: "<rootfile[^>]+full-path=[\"']([^\"']+)[\"']") else {
            throw ParseError.corrupt("container.xml 缺少 rootfile")
        }
        opfPath = rootPath
        opfDir = (opfPath as NSString).deletingLastPathComponent

        guard let opf = try? readEntryText(opfPath) else {
            throw ParseError.corrupt("读不到 OPF：\(opfPath)")
        }

        parseManifest(opf)
        let meta = parseMetadata(opf)
        parseSpine(opf)
        parseTOCMetadata()

        var chapters: [ParsedChapter] = []
        var fullText = ""

        for id in spine {
            guard let item = manifest[id] else { continue }
            let href = normalizePath(item.href)
            guard let html = try? readEntryText(href) else { continue }
            let (title, text) = extractChapterContent(html: html, href: href)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let resolvedTitle = tocMap[href] ?? title
            chapters.append(ParsedChapter(title: resolvedTitle.isEmpty ? "第\(chapters.count + 1)节" : resolvedTitle,
                                          text: text, resourcePath: href))
            fullText += text + "\n"
        }

        // spine 拿不到内容时降级：按 nav 里的链接顺序
        if chapters.isEmpty, !tocMap.isEmpty {
            for (href, title) in tocMap.sorted(by: { $0.key < $1.key }) {
                guard let html = try? readEntryText(href) else { continue }
                let (_, text) = extractChapterContent(html: html, href: href)
                guard !text.isEmpty else { continue }
                chapters.append(ParsedChapter(title: title, text: text, resourcePath: href))
                fullText += text + "\n"
            }
        }

        if chapters.isEmpty {
            // 最后兜底：把全书文本按章节正则再切一次
            if !fullText.isEmpty {
                let split = ChapterSplitter.split(fullText)
                chapters = split.chapters
            } else {
                throw ParseError.empty
            }
        }

        // 解压图片资源
        extractImages()

        return ParsedBook(title: meta.title.isEmpty ? "未命名" : meta.title,
                          author: meta.author,
                          intro: meta.intro,
                          coverData: coverData(meta.coverHref),
                          chapters: chapters,
                          format: .epub,
                          fullText: fullText)
    }

    // MARK: ZIP

    private func entry(for path: String) -> Entry? {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return archive.first { $0.path == clean || $0.path == clean.removingPercentEncoding }
    }

    private func readEntryText(_ path: String) throws -> String {
        guard let e = entry(for: path) else { throw ParseError.corrupt("缺少资源：\(path)") }
        var data = Data()
        _ = try archive.extract(e) { chunk in data.append(chunk) }
        return CharsetDetector.decode(data)
    }

    private func readEntryData(_ path: String) throws -> Data {
        guard let e = entry(for: path) else { throw ParseError.corrupt("缺少资源：\(path)") }
        var data = Data()
        _ = try archive.extract(e) { chunk in data.append(chunk) }
        return data
    }

    // MARK: OPF

    private struct Meta {
        var title = ""
        var author = ""
        var intro = ""
        var coverHref = ""
    }

    private func parseMetadata(_ opf: String) -> Meta {
        var m = Meta()
        m.title = firstMatch(opf, pattern: "<dc:title[^>]*>([\\s\\S]*?)</dc:title>") ?? ""
        m.title = StringExt.stripHTML(m.title)
        m.author = firstMatch(opf, pattern: "<dc:creator[^>]*>([\\s\\S]*?)</dc:creator>") ?? ""
        m.author = StringExt.stripHTML(m.author)
        m.intro = firstMatch(opf, pattern: "<dc:description[^>]*>([\\s\\S]*?)</dc:description>") ?? ""
        m.intro = StringExt.stripHTML(m.intro)

        // 封面：meta name="cover" content="id"
        if let coverID = firstMatch(opf, pattern: "<meta[^>]+name=[\"']cover[\"'][^>]+content=[\"']([^\"']+)[\"']"),
           let item = manifest[coverID] {
            m.coverHref = normalizePath(item.href)
        }
        return m
    }

    private func parseManifest(_ opf: String) {
        guard let re = try? NSRegularExpression(pattern: "<item\\b[^>]*>", options: []) else { return }
        let ns = opf as NSString
        for match in re.matches(in: opf, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let id = firstMatch(tag, pattern: "id=[\"']([^\"']+)[\"']"),
                  let href = firstMatch(tag, pattern: "href=[\"']([^\"']+)[\"']") else { continue }
            let media = firstMatch(tag, pattern: "media-type=[\"']([^\"']+)[\"']") ?? ""
            let props = firstMatch(tag, pattern: "properties=[\"']([^\"']+)[\"']") ?? ""
            manifest[id] = ManifestItem(id: id, href: href, mediaType: media, properties: props)
        }
    }

    private func parseSpine(_ opf: String) {
        guard let re = try? NSRegularExpression(pattern: "<itemref\\b[^>]*>", options: []) else { return }
        let ns = opf as NSString
        for match in re.matches(in: opf, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            if let idref = firstMatch(tag, pattern: "idref=[\"']([^\"']+)[\"']") {
                spine.append(idref)
            }
        }
    }

    // MARK: 目录

    private func parseTOCMetadata() {
        // EPUB3 nav
        if let navItem = manifest.values.first(where: { $0.properties.contains("nav") }) {
            let path = normalizePath(navItem.href)
            if let navHTML = try? readEntryText(path) {
                parseNav(navHTML, basePath: (path as NSString).deletingLastPathComponent)
            }
        }
        // EPUB2 ncx
        if tocMap.isEmpty,
           let ncx = manifest.values.first(where: { $0.mediaType.contains("dtbncx") || $0.href.hasSuffix(".ncx") }) {
            let path = normalizePath(ncx.href)
            if let ncxText = try? readEntryText(path) {
                parseNCX(ncxText, basePath: (path as NSString).deletingLastPathComponent)
            }
        }
    }

    private func parseNav(_ html: String, basePath: String) {
        guard let doc = try? SwiftSoup.parse(html) else { return }
        guard let navs = try? doc.select("nav"), navs.size() > 0 else { return }
        var target: Element? = navs.size() > 0 ? navs.get(0) : nil
        for i in 0..<navs.size() {
            let n = navs.get(i)
            let type = (try? n.attr("epub:type")) ?? ""
            if type.contains("toc") { target = n; break }
        }
        guard let nav = target else { return }
        guard let links = try? nav.select("a[href]") else { return }
        for i in 0..<links.size() {
            let a = links.get(i)
            let href = (try? a.attr("href")) ?? ""
            let title = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizePath(joinPath(basePath, href.components(separatedBy: "#").first ?? href))
            if !key.isEmpty, !title.isEmpty { tocMap[key] = title }
        }
    }

    private func parseNCX(_ xml: String, basePath: String) {
        guard let re = try? NSRegularExpression(
            pattern: "<navPoint[^>]*>[\\s\\S]*?<text[^>]*>([\\s\\S]*?)</text>[\\s\\S]*?src=[\"']([^\"']+)[\"']",
            options: []) else { return }
        let ns = xml as NSString
        for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let title = StringExt.stripHTML(ns.substring(with: m.range(at: 1)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let src = ns.substring(with: m.range(at: 2)).components(separatedBy: "#").first ?? ""
            let key = normalizePath(joinPath(basePath, src))
            if !key.isEmpty, !title.isEmpty { tocMap[key] = title }
        }
    }

    // MARK: 章节内容

    private func extractChapterContent(html: String, href: String) -> (String, String) {
        guard let doc = try? SwiftSoup.parse(html) else { return ("", "") }
        // 标题
        var title = ""
        if let heads = try? doc.select("h1, h2, h3, title"), heads.size() > 0 {
            title = ((try? heads.get(0).text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 正文容器
        let body = doc.body() ?? doc
        let candidates = ["#content", ".content", "#chaptercontent", "#htmlContent",
                          ".read-content", "article", ".text", "#booktext", ".chapter"]
        for sel in candidates {
            if let els = try? body.select(sel), els.size() > 0 {
                let el = els.get(0)
                let t = (try? el.text()) ?? ""
                if t.count > 50 { return (title, formatParagraphs(el)) }
            }
        }
        return (title, formatParagraphs(body))
    }

    /// 按段落保留结构，而不是把整章压成一行
    private func formatParagraphs(_ el: Element) -> String {
        var lines: [String] = []
        func walk(_ node: Element) {
            for child in node.getChildNodes() {
                if let e = child as? Element {
                    let tag = e.tagName().lowercased()
                    if ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "br"].contains(tag) {
                        let t = ((try? e.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { lines.append(t) }
                        if tag == "div" { walk(e) }
                    } else if ["script", "style", "svg"].contains(tag) {
                        continue
                    } else {
                        walk(e)
                    }
                }
            }
        }
        walk(el)
        if lines.isEmpty {
            return ((try? el.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: 图片

    private func extractImages() {
        let imgExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg"]
        for e in archive {
            let ext = (e.path as NSString).pathExtension.lowercased()
            guard imgExt.contains(ext) else { continue }
            let dest = tempDir.appendingPathComponent(e.path.safePathComponent)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            var data = Data()
            guard (try? archive.extract(e) { chunk in data.append(chunk) }) != nil else { continue }
            try? data.write(to: dest)
        }
    }

    private func coverData(_ href: String) -> Data? {
        guard !href.isEmpty, let d = try? readEntryData(href) else { return nil }
        return d.isEmpty ? nil : d
    }

    // MARK: 路径工具

    private func normalizePath(_ href: String) -> String {
        var h = href.removingPercentEncoding ?? href
        if h.hasPrefix("./") { h = String(h.dropFirst(2)) }
        if h.hasPrefix("/") { h = String(h.dropFirst()) }
        return joinPath(opfDir, h)
    }

    private func joinPath(_ base: String, _ rel: String) -> String {
        if rel.hasPrefix("/") { return String(rel.dropFirst()) }
        var comps = base.isEmpty ? [] : base.components(separatedBy: "/")
        for part in rel.components(separatedBy: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { if !comps.isEmpty { comps.removeLast() }; continue }
            comps.append(part)
        }
        return comps.joined(separator: "/")
    }

    private func firstMatch(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}

extension String {
    var safePathComponent: String {
        components(separatedBy: CharacterSet(charactersIn: "\\:*?\"<>|"))
            .joined(separator: "_")
    }
}
