import Foundation

// MARK: - 书籍格式

enum BookFormat: String, Codable, Sendable, CaseIterable {
    case online      // 在线书源
    case txt
    case epub
    case pdf
    case mobi        // mobi / azw / azw3
    case fb2
    case cbz         // cbz / zip 图片包
    case cbr         // cbr / rar(受限)
    case html
    case markdown

    var label: String {
        switch self {
        case .online: return "在线"
        case .txt: return "TXT"
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .mobi: return "MOBI"
        case .fb2: return "FB2"
        case .cbz: return "CBZ"
        case .cbr: return "CBR"
        case .html: return "HTML"
        case .markdown: return "MD"
        }
    }

    var isComicLike: Bool { self == .cbz || self == .cbr }

    static func from(fileExtension ext: String) -> BookFormat {
        switch ext.lowercased() {
        case "txt": return .txt
        case "epub": return .epub
        case "pdf": return .pdf
        case "mobi", "azw", "azw3", "prc": return .mobi
        case "fb2": return .fb2
        case "cbz", "zip": return .cbz
        case "cbr", "rar": return .cbr
        case "html", "htm", "xhtml": return .html
        case "md", "markdown": return .markdown
        default: return .txt
        }
    }
}

// MARK: - 书

struct Book: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var sourceId: String
    var sourceName: String
    var name: String
    var author: String
    var intro: String
    var kind: String
    var coverUrl: String
    var bookUrl: String
    var tocUrl: String
    var lastChapter: String
    var wordCount: String
    var format: BookFormat
    var type: SourceType
    var isLocal: Bool
    var localPath: String
    var addedAt: Date
    var lastReadAt: Date?
    var totalChapters: Int
    /// 本地书籍解析后的分章缓存键
    var cacheKey: String

    init(sourceId: String, sourceName: String, name: String, author: String = "",
         intro: String = "", kind: String = "", coverUrl: String = "",
         bookUrl: String, tocUrl: String = "", lastChapter: String = "",
         wordCount: String = "", format: BookFormat = .online,
         type: SourceType = .text, isLocal: Bool = false,
         localPath: String = "", totalChapters: Int = 0, cacheKey: String = "") {
        self.id = Book.makeId(sourceId: sourceId, bookUrl: bookUrl, name: name)
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.coverUrl = coverUrl
        self.bookUrl = bookUrl
        self.tocUrl = tocUrl
        self.lastChapter = lastChapter
        self.wordCount = wordCount
        self.format = format
        self.type = type
        self.isLocal = isLocal
        self.localPath = localPath
        self.addedAt = Date()
        self.lastReadAt = nil
        self.totalChapters = totalChapters
        self.cacheKey = cacheKey.isEmpty ? Book.makeId(sourceId: sourceId, bookUrl: bookUrl, name: name) : cacheKey
    }

    static func makeId(sourceId: String, bookUrl: String, name: String) -> String {
        let seed = "\(sourceId)|\(bookUrl)|\(name)"
        return "bk_" + String(seed.stableHash, radix: 16)
    }

    var displayAuthor: String { author.isEmpty ? "佚名" : author }
}

// MARK: - 章节

struct Chapter: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var bookId: String
    var index: Int
    var title: String
    var url: String
    var baseUrl: String
    var isVip: Bool
    var isVolume: Bool
    /// 本地 TXT 定位
    var startOffset: Int
    var endOffset: Int
    /// 本地 EPUB 资源路径
    var resourcePath: String

    init(bookId: String, index: Int, title: String, url: String = "",
         baseUrl: String = "", isVip: Bool = false, isVolume: Bool = false,
         startOffset: Int = -1, endOffset: Int = -1, resourcePath: String = "") {
        self.bookId = bookId
        self.index = index
        self.title = title
        self.url = url
        self.baseUrl = baseUrl
        self.isVip = isVip
        self.isVolume = isVolume
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.resourcePath = resourcePath
        self.id = "\(bookId)#\(index)"
    }
}

// MARK: - 阅读进度

struct ReadingProgress: Codable, Hashable, Sendable {
    var bookId: String
    var chapterIndex: Int
    var chapterTitle: String
    var pageInChapter: Int
    /// 章内字符偏移，跨设备/跨字号最稳定的定位
    var charOffset: Int
    var percent: Double
    var updatedAt: Date

    static func empty(bookId: String) -> ReadingProgress {
        ReadingProgress(bookId: bookId, chapterIndex: 0, chapterTitle: "",
                        pageInChapter: 0, charOffset: 0, percent: 0, updatedAt: Date())
    }
}

// MARK: - 书签 / 标注

struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var bookId: String
    var chapterIndex: Int
    var chapterTitle: String
    var charOffset: Int
    var excerpt: String
    var note: String
    var createdAt: Date = Date()
    var colorHex: String = "#E8B85C"
}

// MARK: - 搜索结果

struct SearchResult: Identifiable, Hashable, Sendable {
    var id: String { book.id }
    let book: Book
    let sourceName: String
}

// MARK: - 章节列表容器

struct TocResult: Sendable {
    var chapters: [Chapter]
    var nextPageUrl: String?
}

// MARK: - 章节正文

struct ContentResult: Sendable {
    var text: String            // 纯文本（已清理）
    var html: String            // 原始 HTML（保留图片）
    var imageUrls: [String]
    var nextPageUrl: String?
    var isComic: Bool
}

// MARK: - Hash 工具

extension String {
    var stableHash: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in self.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
