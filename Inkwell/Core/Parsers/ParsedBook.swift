import Foundation

// MARK: - 本地文件解析的统一产物

struct ParsedChapter: Sendable {
    var title: String
    var text: String
    /// EPUB 里的资源路径（重新打开时用）
    var resourcePath: String = ""
    /// TXT 里在全文中的字符区间
    var range: Range<Int>?
    /// 漫画章节：图片路径（包内）
    var images: [String] = []
}

struct ParsedBook: Sendable {
    var title: String
    var author: String = ""
    var intro: String = ""
    var coverData: Data? = nil
    var chapters: [ParsedChapter]
    var format: BookFormat
    var isComic: Bool = false
    /// 全书合并文本（TXT/HTML 用，便于按偏移取章）
    var fullText: String = ""
}

enum ParseError: LocalizedError {
    case unsupported(String)
    case corrupt(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupported(let e): return "暂不支持的格式：\(e)"
        case .corrupt(let m): return "文件损坏：\(m)"
        case .empty: return "文件内容为空"
        }
    }
}
