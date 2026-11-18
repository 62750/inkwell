import Foundation

/// 书源类型
enum SourceType: Int, Codable, CaseIterable, Sendable {
    case text = 0      // 文本小说
    case audio = 1     // 有声
    case image = 2     // 漫画
    case file = 3      // 文件下载

    var label: String {
        switch self {
        case .text: return "小说"
        case .audio: return "有声"
        case .image: return "漫画"
        case .file: return "文件"
        }
    }
}

// MARK: - 规则块

struct SearchRule: Codable, Hashable, Sendable {
    @AnyString var bookList = ""
    @AnyString var name = ""
    @AnyString var author = ""
    @AnyString var intro = ""
    @AnyString var kind = ""
    @AnyString var lastChapter = ""
    @AnyString var updateTime = ""
    @AnyString var bookUrl = ""
    @AnyString var coverUrl = ""
    @AnyString var wordCount = ""
}

struct ExploreRule: Codable, Hashable, Sendable {
    @AnyString var bookList = ""
    @AnyString var name = ""
    @AnyString var author = ""
    @AnyString var intro = ""
    @AnyString var kind = ""
    @AnyString var lastChapter = ""
    @AnyString var updateTime = ""
    @AnyString var bookUrl = ""
    @AnyString var coverUrl = ""
    @AnyString var wordCount = ""
}

struct BookInfoRule: Codable, Hashable, Sendable {
    @AnyString var initRule = ""
    @AnyString var name = ""
    @AnyString var author = ""
    @AnyString var intro = ""
    @AnyString var kind = ""
    @AnyString var lastChapter = ""
    @AnyString var updateTime = ""
    @AnyString var wordCount = ""
    @AnyString var coverUrl = ""
    @AnyString var tocUrl = ""
    @AnyString var canReName = ""
    @AnyString var downloadUrls = ""

    enum CodingKeys: String, CodingKey {
        case initRule = "init"
        case name, author, intro, kind, lastChapter, updateTime, wordCount
        case coverUrl, tocUrl, canReName, downloadUrls
    }
}

struct TocRule: Codable, Hashable, Sendable {
    @AnyString var chapterList = ""
    @AnyString var chapterName = ""
    @AnyString var chapterUrl = ""
    @AnyString var format = ""
    @AnyString var isVolume = ""
    @AnyString var isVip = ""
    @AnyString var isPay = ""
    @AnyString var updateTime = ""
    @AnyString var nextTocUrl = ""
}

struct ContentRule: Codable, Hashable, Sendable {
    @AnyString var content = ""
    @AnyString var nextContentUrl = ""
    @AnyString var webJs = ""
    @AnyString var sourceRegex = ""
    @AnyString var replaceRegex = ""
    @AnyString var imageStyle = ""
    @AnyString var payAction = ""
}

// MARK: - 书源

struct BookSource: Codable, Hashable, Identifiable, Sendable {
    var id: String = UUID().uuidString

    @AnyString var bookSourceUrl = ""
    @AnyString var bookSourceName = ""
    @AnyString var bookSourceGroup = ""
    @AnyInt var bookSourceType = 0
    @AnyString var bookSourceComment = ""
    @AnyString var bookSourceIcon = ""
    @AnyBool var enabled = true
    @AnyBool var enabledExplore = true
    @AnyInt var customOrder = 0
    @AnyInt var lastUpdateTime = 0
    @AnyInt var respondTime = 180_000
    @AnyInt var weight = 0

    @AnyString var searchUrl = ""
    @AnyString var exploreUrl = ""
    @AnyString var bookUrlPattern = ""
    @AnyString var header = ""
    @AnyString var loginUrl = ""
    @AnyString var loginUi = ""
    @AnyString var loginCheckJs = ""
    @AnyString var concurrentRate = ""
    @AnyString var jsLib = ""
    @AnyString var coverDecodeJs = ""
    @AnyString var variableComment = ""
    @AnyString var ruleSearchUrl = ""

    var ruleSearch = SearchRule()
    var ruleExplore = ExploreRule()
    var ruleBookInfo = BookInfoRule()
    var ruleToc = TocRule()
    var ruleContent = ContentRule()

    enum CodingKeys: String, CodingKey {
        case id
        case bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType
        case bookSourceComment, bookSourceIcon, enabled, enabledExplore
        case customOrder, lastUpdateTime, respondTime, weight
        case searchUrl, exploreUrl, bookUrlPattern, header
        case loginUrl, loginUi, loginCheckJs, concurrentRate, jsLib
        case coverDecodeJs, variableComment, ruleSearchUrl
        case ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        _bookSourceUrl = try c.decodeIfPresent(AnyString.self, forKey: .bookSourceUrl) ?? AnyString(wrappedValue: "")
        _bookSourceName = try c.decodeIfPresent(AnyString.self, forKey: .bookSourceName) ?? AnyString(wrappedValue: "")
        _bookSourceGroup = try c.decodeIfPresent(AnyString.self, forKey: .bookSourceGroup) ?? AnyString(wrappedValue: "")
        _bookSourceType = try c.decodeIfPresent(AnyInt.self, forKey: .bookSourceType) ?? AnyInt(wrappedValue: 0)
        _bookSourceComment = try c.decodeIfPresent(AnyString.self, forKey: .bookSourceComment) ?? AnyString(wrappedValue: "")
        _bookSourceIcon = try c.decodeIfPresent(AnyString.self, forKey: .bookSourceIcon) ?? AnyString(wrappedValue: "")
        _enabled = try c.decodeIfPresent(AnyBool.self, forKey: .enabled) ?? AnyBool(wrappedValue: true)
        _enabledExplore = try c.decodeIfPresent(AnyBool.self, forKey: .enabledExplore) ?? AnyBool(wrappedValue: true)
        _customOrder = try c.decodeIfPresent(AnyInt.self, forKey: .customOrder) ?? AnyInt(wrappedValue: 0)
        _lastUpdateTime = try c.decodeIfPresent(AnyInt.self, forKey: .lastUpdateTime) ?? AnyInt(wrappedValue: 0)
        _respondTime = try c.decodeIfPresent(AnyInt.self, forKey: .respondTime) ?? AnyInt(wrappedValue: 180000)
        _weight = try c.decodeIfPresent(AnyInt.self, forKey: .weight) ?? AnyInt(wrappedValue: 0)
        _searchUrl = try c.decodeIfPresent(AnyString.self, forKey: .searchUrl) ?? AnyString(wrappedValue: "")
        _exploreUrl = try c.decodeIfPresent(AnyString.self, forKey: .exploreUrl) ?? AnyString(wrappedValue: "")
        _bookUrlPattern = try c.decodeIfPresent(AnyString.self, forKey: .bookUrlPattern) ?? AnyString(wrappedValue: "")
        _header = try c.decodeIfPresent(AnyString.self, forKey: .header) ?? AnyString(wrappedValue: "")
        _loginUrl = try c.decodeIfPresent(AnyString.self, forKey: .loginUrl) ?? AnyString(wrappedValue: "")
        _loginUi = try c.decodeIfPresent(AnyString.self, forKey: .loginUi) ?? AnyString(wrappedValue: "")
        _loginCheckJs = try c.decodeIfPresent(AnyString.self, forKey: .loginCheckJs) ?? AnyString(wrappedValue: "")
        _concurrentRate = try c.decodeIfPresent(AnyString.self, forKey: .concurrentRate) ?? AnyString(wrappedValue: "")
        _jsLib = try c.decodeIfPresent(AnyString.self, forKey: .jsLib) ?? AnyString(wrappedValue: "")
        _coverDecodeJs = try c.decodeIfPresent(AnyString.self, forKey: .coverDecodeJs) ?? AnyString(wrappedValue: "")
        _variableComment = try c.decodeIfPresent(AnyString.self, forKey: .variableComment) ?? AnyString(wrappedValue: "")
        _ruleSearchUrl = try c.decodeIfPresent(AnyString.self, forKey: .ruleSearchUrl) ?? AnyString(wrappedValue: "")
        ruleSearch = (try? c.decode(SearchRule.self, forKey: .ruleSearch)) ?? SearchRule()
        ruleExplore = (try? c.decode(ExploreRule.self, forKey: .ruleExplore)) ?? ExploreRule()
        ruleBookInfo = (try? c.decode(BookInfoRule.self, forKey: .ruleBookInfo)) ?? BookInfoRule()
        ruleToc = (try? c.decode(TocRule.self, forKey: .ruleToc)) ?? TocRule()
        ruleContent = (try? c.decode(ContentRule.self, forKey: .ruleContent)) ?? ContentRule()
    }

    // MARK: 便利

    var type: SourceType { SourceType(rawValue: bookSourceType) ?? .text }
    var isComic: Bool { type == .image }
    var displayName: String { bookSourceName.isEmpty ? (URL(string: bookSourceUrl)?.host ?? "未命名源") : bookSourceName }
    var host: String { URL(string: bookSourceUrl)?.host ?? bookSourceUrl }

    var groupList: [String] {
        bookSourceGroup
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" || $0 == "；" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 解析 header 字段：既支持 JSON 字符串，也支持 "k=v&k2=v2"
    var headerDictionary: [String: String] {
        let raw = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [:] }
        if raw.hasPrefix("{"), let d = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: d),
           let obj = parsed as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in obj { out[k] = "\(v)" }
            return out
        }
        var out: [String: String] = [:]
        if raw.contains("@") {
            // "UA@Referer" 形式的裸 header
            let parts = raw.split(separator: "@").map(String.init)
            if parts.count >= 2 {
                out["User-Agent"] = parts[0]
                out["Referer"] = parts[1]
                if parts.count >= 3, !parts[2].isEmpty { out["Cookie"] = parts[2] }
                return out
            }
        }
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    static func == (lhs: BookSource, rhs: BookSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - 示例源（首次启动内置，方便直接验证引擎）

extension BookSource {
    static func starterSources() -> [BookSource] {
        var txt = BookSource()
        txt.bookSourceName = "演示·静态HTML源"
        txt.bookSourceUrl = "https://example.com"
        txt.bookSourceGroup = "演示"
        txt.bookSourceType = 0
        txt.searchUrl = "https://example.com/search?q={{key}}"
        txt.ruleSearch.bookList = "class.book-list@tag.li"
        txt.ruleSearch.name = "tag.h3@text"
        txt.ruleSearch.author = "class.author@text"
        txt.ruleSearch.bookUrl = "tag.a@href"
        txt.ruleSearch.coverUrl = "tag.img@src"
        txt.ruleSearch.intro = "class.intro@text"
        txt.ruleBookInfo.name = "tag.h1@text"
        txt.ruleBookInfo.author = "class.author@text"
        txt.ruleBookInfo.intro = "class.intro@text"
        txt.ruleBookInfo.coverUrl = "class.cover@tag.img@src"
        txt.ruleToc.chapterList = "class.chapter-list@tag.a"
        txt.ruleToc.chapterName = "text"
        txt.ruleToc.chapterUrl = "href"
        txt.ruleContent.content = "class.content@html"
        txt.bookSourceComment = "内置演示源，仅用于验证规则引擎是否工作"
        return [txt]
    }
}
