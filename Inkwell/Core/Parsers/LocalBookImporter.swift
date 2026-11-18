import Foundation

// MARK: - 本地文件导入器
//
// 任何格式进来 → ParsedBook → Book + [Chapter] + 正文缓存
// 大文本按章写进 DB，翻页时只读一章，避免整本驻留内存。

enum LocalBookImporter {

    struct Loaded {
        var book: Book
        var chapters: [Chapter]
        var parsed: ParsedBook
        var isComic: Bool
    }

    /// 解析文件（不落库）
    static func load(at url: URL) throws -> Loaded {
        let ext = url.pathExtension.lowercased()
        let format = BookFormat.from(fileExtension: ext)

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let stored = try copyIntoLibrary(url: url)

        var parsed: ParsedBook
        var isComic = false

        switch format {
        case .cbz, .cbr:
            let temp = try comicTempDir(for: stored)
            parsed = try ComicArchiveParser.parse(url: stored, tempDir: temp)
            isComic = true
            var book = baseBook(parsed, path: stored.path, format: format,
                                type: .image, isComic: true)
            let chapters = comicChapters(parsed, bookId: book.id)
            book.totalChapters = chapters.count
            if let cover = parsed.coverData { saveCover(cover, for: book.id) }
            return Loaded(book: book, chapters: chapters, parsed: parsed, isComic: true)

        case .epub:
            let temp = try extractDir(for: stored)
            parsed = try EPUBParser(url: stored, tempDir: temp).parse()

        case .pdf:
            parsed = try PDFParser.parse(url: stored)
            isComic = parsed.isComic

        case .mobi:
            parsed = try MobiParser.parse(url: stored)

        case .fb2:
            parsed = try FB2Parser.parse(url: stored)

        case .html:
            parsed = try HTMLTextParser.parse(url: stored)

        case .markdown:
            parsed = try MarkdownParser.parse(url: stored)

        case .txt, .online:
            parsed = try TXTParser.parse(url: stored)
        }

        var book = baseBook(parsed, path: stored.path, format: format,
                            type: isComic ? .image : .text, isComic: isComic)
        let chapters = textChapters(parsed, bookId: book.id, path: stored.path)
        book.totalChapters = chapters.count
        if let cover = parsed.coverData { saveCover(cover, for: book.id) }
        return Loaded(book: book, chapters: chapters, parsed: parsed, isComic: isComic)
    }

    /// 解析 + 落库，返回最终 Book
    @discardableResult
    static func importAndStore(at url: URL) throws -> Book {
        let loaded = try load(at: url)
        let repo = LibraryRepository.shared
        repo.saveBook(loaded.book)
        repo.saveChapters(loaded.chapters, bookId: loaded.book.id)

        if !loaded.isComic {
            for (i, pc) in loaded.parsed.chapters.enumerated() where i < loaded.chapters.count {
                let content = ContentResult(text: pc.text, html: "", imageUrls: [],
                                            nextPageUrl: nil, isComic: false)
                repo.saveContent(content, chapterId: loaded.chapters[i].id)
            }
        }
        return loaded.book
    }

    // MARK: 沙盒存储

    static var libraryDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func copyIntoLibrary(url: URL) throws -> URL {
        let dest = libraryDir.appendingPathComponent(
            StringExt.safeFileName(url.lastPathComponent, maxLength: 120))
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    static func extractDir(for url: URL) throws -> URL {
        let dir = libraryDir.appendingPathComponent(
            "unpack_" + StringExt.safeFileName(url.deletingPathExtension().lastPathComponent,
                                               maxLength: 60),
            isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func comicTempDir(for url: URL) throws -> URL {
        let dir = libraryDir.appendingPathComponent(
            "comic_" + InsecureDigest.sha1Hex(url.lastPathComponent), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: 组装

    private static func baseBook(_ p: ParsedBook, path: String,
                                 format: BookFormat, type: SourceType,
                                 isComic: Bool) -> Book {
        var b = Book(sourceId: "local", sourceName: "本地",
                     name: p.title, author: p.author, intro: p.intro,
                     bookUrl: path, format: format,
                     type: type, isLocal: true, localPath: path)
        b.cacheKey = InsecureDigest.sha1Hex(path)
        return b
    }

    private static func textChapters(_ p: ParsedBook, bookId: String, path: String) -> [Chapter] {
        p.chapters.enumerated().map { idx, pc in
            var c = Chapter(bookId: bookId, index: idx, title: pc.title, url: path,
                            baseUrl: path, resourcePath: pc.resourcePath)
            if let r = pc.range {
                c.startOffset = r.lowerBound
                c.endOffset = r.upperBound
            }
            return c
        }
    }

    private static func comicChapters(_ p: ParsedBook, bookId: String) -> [Chapter] {
        p.chapters.enumerated().map { idx, pc in
            var c = Chapter(bookId: bookId, index: idx, title: pc.title)
            c.resourcePath = pc.images.joined(separator: "\n")
            return c
        }
    }

    // MARK: 封面

    static var coverDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func saveCover(_ data: Data, for bookId: String) -> String {
        let url = coverDir.appendingPathComponent("\(bookId).jpg")
        try? data.write(to: url)
        return url.path
    }

    static func coverPath(for bookId: String) -> String? {
        let url = coverDir.appendingPathComponent("\(bookId).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }
}
