import Foundation
import SwiftSoup

// MARK: - 搜索请求构造
//
// Legado searchUrl 三种形态：
//   1. "https://a.com/search?q={{key}}&page={{page}}"
//   2. "https://a.com/search?q={{key}},{\"method\":\"POST\",\"body\":\"kw={{key}}\",\"charset\":\"gbk\",\"headers\":{\"X-Foo\":\"bar\"}}"
//   3. "@js:..." 全动态

struct SearchRequest {
    var url: String
    var method: String = "GET"
    var body: String = ""
    var charset: String = "UTF-8"
    var headers: [String: String] = [:]
}

enum SearchRequestBuilder {

    static func build(searchURL raw: String, key: String, page: Int,
                      source: BookSource) -> SearchRequest {
        var template = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var config: [String: Any] = [:]

        // 拆出尾部 ,{...}
        if let braceRange = template.range(of: ",{", options: .backwards) {
            let jsonPart = String(template[braceRange.lowerBound...].dropFirst())
            if let d = cleanedJSON(jsonPart),
               let parsed = try? JSONSerialization.jsonObject(with: d),
               let obj = parsed as? [String: Any] {
                config = obj
                template = String(template[template.startIndex..<braceRange.lowerBound])
            }
        }

        let method = (config["method"] as? String)?.uppercased() ?? "GET"
        let bodyTemplate = config["body"] as? String ?? ""
        let charset = config["charset"] as? String ?? "UTF-8"
        var headers = source.headerDictionary
        if let h = config["headers"] as? [String: Any] {
            for (k, v) in h { headers[k] = "\(v)" }
        }

        // URL 里的 {{key}} 做百分号编码；body 里用原文
        var url = template
            .replacingOccurrences(of: "{{key}}", with: StringExt.urlEncode(key))
            .replacingOccurrences(of: "{{page}}", with: String(page))
            .replacingOccurrences(of: "{{baseUrl}}", with: source.bookSourceUrl)
        url = url.replacingOccurrences(of: " ", with: "%20")

        var body = bodyTemplate
            .replacingOccurrences(of: "{{key}}", with: key)
            .replacingOccurrences(of: "{{page}}", with: String(page))

        if url.hasPrefix("/") {
            url = StringExt.absolute(url, base: source.bookSourceUrl)
        }
        return SearchRequest(url: url, method: method, body: body,
                             charset: charset, headers: headers)
    }

    private static func cleanedJSON(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.hasSuffix("}") {
            t += "}"
        }
        t = StringExt.removeTrailingCommas(t)
        return t.data(using: .utf8)
    }
}

// MARK: - 书源执行引擎

actor SourceEngine {
    static let shared = SourceEngine()

    private let http = HTTPClient.shared

    // MARK: 搜索

    func search(source: BookSource, key: String, page: Int = 1) async throws -> [Book] {
        let rule = source.ruleSearch
        guard !rule.bookList.isEmpty else { throw SourceError.ruleMissing("ruleSearch.bookList") }

        // searchUrl 为空但有 searchUrl 规则时可跳过
        var searchTemplate = source.searchUrl
        if searchTemplate.isEmpty {
            throw SourceError.ruleMissing("searchUrl")
        }

        var input: RuleInput

        if searchTemplate.hasPrefix("@js:") {
            let script = String(searchTemplate.dropFirst(4))
            let eval = RuleEvaluator()
            var vars: [String: String] = [:]
            var env = JSEnv()
            env.baseUrl = source.bookSourceUrl
            env.key = key
            env.page = page
            env.sourceJSON = Self.jsonString(source)
            let result = JSEngine.run(script: script, html: nil, env: env, sharedVariables: &vars)
            let fetched = try await http.request(url: result.isEmpty ? source.bookSourceUrl : result,
                                                headers: source.headerDictionary)
            input = .html(fetched.text, baseUrl: fetched.finalURL.absoluteString)
        } else {
            let req = SearchRequestBuilder.build(searchURL: searchTemplate, key: key,
                                                 page: page, source: source)
            var response: HTTPResponse
            if req.method == "POST" {
                var h = req.headers
                h["Content-Type"] = "application/x-www-form-urlencoded; charset=\(req.charset)"
                response = try await http.request(url: req.url, method: "POST", headers: h,
                                                  body: req.body.data(using: .utf8),
                                                  encoding: req.charset)
            } else {
                response = try await http.request(url: req.url, headers: req.headers,
                                                  encoding: req.charset)
            }
            logD("search", "\(source.displayName) → \(response.statusCode) \(response.finalURL.absoluteString)")
            input = makeInput(response)
        }

        return try await parseBookList(source: source, ruleBookList: rule.bookList,
                                       fieldRules: (rule.name, rule.author, rule.intro, rule.kind,
                                                    rule.lastChapter, rule.updateTime,
                                                    rule.bookUrl, rule.coverUrl),
                                       input: input, page: page)
    }

    // MARK: 发现/分类

    func explore(source: BookSource, url rawURL: String) async throws -> [Book] {
        let rule = source.ruleExplore
        var input: RuleInput
        let target = rawURL.isEmpty ? source.bookSourceUrl : rawURL
        let response = try await http.request(url: target, headers: source.headerDictionary)
        input = makeInput(response)
        if rule.bookList.isEmpty { return [] }
        return try await parseBookList(source: source, ruleBookList: rule.bookList,
                                       fieldRules: (rule.name, rule.author, rule.intro, rule.kind,
                                                    rule.lastChapter, rule.updateTime,
                                                    rule.bookUrl, rule.coverUrl),
                                       input: input, page: 1)
    }

    // MARK: 书籍详情

    func bookInfo(source: BookSource, bookUrl: String, stub: Book? = nil) async throws -> Book {
        let rule = source.ruleBookInfo
        var book = stub ?? Book(sourceId: source.id, sourceName: source.displayName,
                                name: "", bookUrl: bookUrl,
                                type: source.type)

        // 详情页 URL：bookUrl 就是详情页
        var detailURL = bookUrl
        let response = try await http.request(url: detailURL, headers: source.headerDictionary)
        var input = makeInput(response)

        // ruleBookInfo.init 可以先做一次跳转/取子页
        if !rule.initRule.isEmpty {
            let eval = RuleEvaluator()
            let v = eval.first(rule.initRule, input: input, env: jsEnv(source, baseUrl: detailURL))
            if !v.isEmpty {
                detailURL = StringExt.absolute(v, base: response.finalURL.absoluteString)
                let r2 = try await http.request(url: detailURL, headers: source.headerDictionary)
                input = makeInput(r2)
            }
        }

        let eval = RuleEvaluator()
        let env = jsEnv(source, baseUrl: detailURL)

        func value(_ r: String) -> String {
            eval.first(r, input: input, env: env)
        }

        if !rule.name.isEmpty { book.name = value(rule.name) }
        if book.name.isEmpty { book.name = stub?.name ?? "" }
        if !rule.author.isEmpty { book.author = value(rule.author) }
        if !rule.intro.isEmpty { book.intro = StringExt.stripHTML(value(rule.intro)) }
        if !rule.kind.isEmpty { book.kind = value(rule.kind) }
        if !rule.lastChapter.isEmpty { book.lastChapter = value(rule.lastChapter) }
        if !rule.wordCount.isEmpty { book.wordCount = value(rule.wordCount) }
        if !rule.coverUrl.isEmpty {
            var cover = value(rule.coverUrl)
            if cover.hasPrefix("http") == false, !cover.isEmpty {
                cover = StringExt.absolute(cover, base: detailURL)
            }
            book.coverUrl = cover
        }
        if !rule.tocUrl.isEmpty {
            let t = value(rule.tocUrl)
            book.tocUrl = t.isEmpty ? detailURL : StringExt.absolute(t, base: detailURL)
        } else {
            book.tocUrl = detailURL
        }
        book.bookUrl = detailURL
        book.sourceName = source.displayName
        book.type = source.type
        book.format = .online
        return book
    }

    // MARK: 目录

    func toc(source: BookSource, book: Book) async throws -> TocResult {
        let rule = source.ruleToc
        let target = book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl
        let response = try await http.request(url: target, headers: source.headerDictionary)
        let input = makeInput(response)
        return try await parseToc(source: source, book: book, target: target, input: input,
                                  rule: rule, pageGuard: 0)
    }

    private func parseToc(source: BookSource, book: Book, target: String,
                          input: RuleInput, rule: TocRule, pageGuard: Int) async throws -> TocResult {
        guard pageGuard < 6 else { return TocResult(chapters: [], nextPageUrl: nil) }
        let eval = RuleEvaluator()
        let env = jsEnv(source, baseUrl: target)

        var listRule = rule.chapterList
        if listRule.hasPrefix("@auto"), let dom = input.dom,
           let probed = RuleProber.probeToc(dom) {
            listRule = probed.list
            logD("auto", "目录结构探测：\(probed.list)")
        }
        var chapters: [Chapter] = []

        if listRule.isEmpty {
            // 无规则时尝试通用启发式
            chapters = HeuristicToc.guess(from: input.dom, baseUrl: target, bookId: book.id)
        } else if input.dom != nil {
            let items = SelectorBridge.select(listRule, in: input.dom!)
            let useXPath = listRule.hasPrefix("//") || listRule.hasPrefix("/") || listRule.hasPrefix("@xpath:")
            let xnodes = useXPath ? XPathEvaluator.query(listRule, in: input.dom!) : []

            if !xnodes.isEmpty {
                for (idx, node) in xnodes.enumerated() {
                    guard let el = node.elementValue else { continue }
                    let itemInput = RuleInput(html: (try? el.outerHtml()) ?? "",
                                              dom: el, json: nil, text: nil, baseUrl: target)
                    chapters.append(makeChapter(source: source, book: book, index: idx,
                                                el: el, itemInput: itemInput,
                                                rule: rule, env: env, baseUrl: target))
                }
            } else {
                for (idx, el) in items.enumerated() {
                    let itemInput = RuleInput(html: (try? el.outerHtml()) ?? "",
                                              dom: el, json: nil, text: nil, baseUrl: target)
                    chapters.append(makeChapter(source: source, book: book, index: idx,
                                                el: el, itemInput: itemInput,
                                                rule: rule, env: env, baseUrl: target))
                }
            }
        } else if input.json != nil {
            let paths = JSONPathLite.query(listRule, json: input.json!)
            for (idx, item) in paths.enumerated() {
                let itemJSON = JSONPathLite.stringify(item)
                let itemInput = RuleInput(html: itemJSON, dom: nil,
                                          json: item, text: itemJSON, baseUrl: target)
                let name = rule.chapterName.isEmpty ? JSONPathLite.stringify(item)
                    : eval.first(rule.chapterName, input: itemInput, env: env)
                let urlRaw = eval.first(rule.chapterUrl, input: itemInput, env: env)
                let ch = Chapter(bookId: book.id, index: idx,
                                 title: cleanTitle(name),
                                 url: StringExt.absolute(urlRaw, base: target),
                                 baseUrl: target,
                                 isVip: eval.first(rule.isVip, input: itemInput, env: env) == "true")
                chapters.append(ch)
            }
        }

        // 过滤卷名
        var filtered: [Chapter] = []
        for var ch in chapters {
            if ch.title.isEmpty && ch.url.isEmpty { continue }
            if ch.isVolume && ch.url.isEmpty { continue }
            filtered.append(ch)
        }

        // 分页
        var next: String?
        if !rule.nextTocUrl.isEmpty {
            let raw = eval.first(rule.nextTocUrl, input: input, env: env)
            if !raw.isEmpty {
                next = StringExt.absolute(raw, base: target)
            }
        }

        if let next, !next.isEmpty, next != target, pageGuard < 6 {
            var all = filtered
            let r2 = try await http.request(url: next, headers: source.headerDictionary)
            let res = try await parseToc(source: source, book: book, target: next,
                                         input: makeInput(r2), rule: rule,
                                         pageGuard: pageGuard + 1)
            all.append(contentsOf: res.chapters)
            // 重新编号
            for i in all.indices { all[i].index = i; all[i].id = "\(book.id)#\(i)" }
            return TocResult(chapters: all, nextPageUrl: res.nextPageUrl)
        }

        for i in filtered.indices { filtered[i].index = i; filtered[i].id = "\(book.id)#\(i)" }
        return TocResult(chapters: filtered, nextPageUrl: next)
    }

    private func makeChapter(source: BookSource, book: Book, index: Int,
                             el: Element, itemInput: RuleInput, rule: TocRule,
                             env: JSEnv, baseUrl: String) -> Chapter {
        let eval = RuleEvaluator()
        let nameRule = rule.chapterName.isEmpty ? "text" : rule.chapterName
        let urlRule = rule.chapterUrl.isEmpty ? "href" : rule.chapterUrl

        let name = eval.first(nameRule, input: itemInput, env: env)
        let urlRaw = eval.first(urlRule, input: itemInput, env: env)

        var chapter = Chapter(bookId: book.id, index: index,
                              title: cleanTitle(name),
                              url: StringExt.absolute(urlRaw, base: baseUrl),
                              baseUrl: baseUrl)
        if !rule.isVip.isEmpty {
            chapter.isVip = eval.first(rule.isVip, input: itemInput, env: env).lowercased() == "true"
        }
        if !rule.isVolume.isEmpty {
            chapter.isVolume = eval.first(rule.isVolume, input: itemInput, env: env).lowercased() == "true"
        }
        // 有些源的 chapterUrl 是相对 js 属性
        if chapter.url.isEmpty, hasAttrOf(el, "data-href") {
            chapter.url = StringExt.absolute(attrOf(el, "data-href"), base: baseUrl)
        }
        if chapter.url.isEmpty, hasAttrOf(el, "data-url") {
            chapter.url = StringExt.absolute(attrOf(el, "data-url"), base: baseUrl)
        }
        if chapter.title.isEmpty { chapter.title = "第\(index + 1)章" }
        return chapter
    }

    private func cleanTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t
    }

    // MARK: 正文

    func content(source: BookSource, book: Book, chapter: Chapter,
                 maxPages: Int = 5) async throws -> ContentResult {
        let rule = source.ruleContent
        guard !rule.content.isEmpty else { throw SourceError.ruleMissing("ruleContent.content") }

        var collected: [String] = []
        var imageURLs: [String] = []
        var htmlParts: [String] = []
        var next = chapter.url
        var guardCount = 0
        let base = chapter.baseUrl.isEmpty ? book.bookUrl : chapter.baseUrl

        while !next.isEmpty, guardCount < maxPages {
            guardCount += 1
            let response = try await http.request(url: next, headers: source.headerDictionary,
                                                  referer: base)
            let input = makeInput(response)
            let eval = RuleEvaluator()
            var env = jsEnv(source, baseUrl: next)
            env.key = book.name
            var vars: [String: String] = [:]

            // webJs：先跑一段脚本（用于反混淆）
            if !rule.webJs.isEmpty {
                let inject = JSEngine.run(script: rule.webJs, html: response.text,
                                          env: env, sharedVariables: &vars)
                if !inject.isEmpty {
                    env.variables = vars
                }
            }

            let raw = eval.eval(rule.content, input: input, env: env)

            if source.isComic {
                // 漫画：内容规则给出图片地址或 img 标签
                var imgs: [String] = []
                for r in raw {
                    if r.hasPrefix("http"), r.range(of: "\\.(jpg|jpeg|png|webp|gif|avif|bmp)",
                                                    options: [.regularExpression, .caseInsensitive]) != nil {
                        imgs.append(r)
                    } else {
                        imgs.append(contentsOf: extractImages(from: r, base: next))
                    }
                }
                // 直接从 HTML 里兜底抓图
                if imgs.isEmpty, let dom = input.dom {
                    imgs = HeuristicToc.extractImagesFromDocument(dom, base: next)
                }
                imageURLs.append(contentsOf: imgs)
            } else {
                for r in raw {
                    let plain = r.contains("<") ? StringExt.stripHTML(r) : r
                    collected.append(plain)
                    if r.contains("<") { htmlParts.append(r) }
                }
            }

            if !rule.nextContentUrl.isEmpty {
                let n = RuleEvaluator().first(rule.nextContentUrl, input: input, env: env)
                let abs = StringExt.absolute(n, base: next)
                if abs.isEmpty || abs == next { break }
                next = abs
            } else {
                break
            }
        }

        var text = RegexChain.cleanContent(collected.joined(separator: "\n"))
        // sourceRegex / replaceRegex
        if !rule.replaceRegex.isEmpty {
            if let re = try? NSRegularExpression(pattern: rule.replaceRegex) {
                text = re.stringByReplacingMatches(in: text,
                                                   range: NSRange(location: 0, length: (text as NSString).length),
                                                   withTemplate: "")
            }
        }

        return ContentResult(text: text,
                             html: htmlParts.joined(separator: "\n"),
                             imageUrls: imageURLs.distinct(),
                             nextPageUrl: nil,
                             isComic: source.isComic)
    }

    private func extractImages(from raw: String, base: String) -> [String] {
        var out: [String] = []
        if let re = try? NSRegularExpression(pattern: "<img[^>]+(?:data-src|src|data-original)=[\"']([^\"']+)[\"']",
                                             options: .caseInsensitive) {
            let ns = raw as NSString
            for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let u = ns.substring(with: m.range(at: 1))
                if u.hasPrefix("data:") { continue }
                out.append(StringExt.absolute(u, base: base))
            }
        }
        return out
    }

    // MARK: 帮助函数

    private func makeInput(_ r: HTTPResponse) -> RuleInput {
        let base = r.finalURL.absoluteString
        let ct = r.headers["Content-Type"]?.lowercased() ?? ""
        let looksJSON = ct.contains("json")
            || (r.text.hasPrefix("{") && r.text.hasSuffix("}"))
            || (r.text.hasPrefix("[") && r.text.hasSuffix("]"))
        if looksJSON, (try? JSONSerialization.jsonObject(with: r.data,
                                                        options: [.fragmentsAllowed])) != nil {
            return .json(r.text, baseUrl: base)
        }
        return .html(r.text, baseUrl: base)
    }

    private func jsEnv(_ source: BookSource, baseUrl: String) -> JSEnv {
        var e = JSEnv()
        e.baseUrl = baseUrl
        e.sourceJSON = Self.jsonString(source)
        return e
    }

    static func jsonString(_ source: BookSource) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let d = try? enc.encode(source) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }
}

// MARK: - 列表解析（搜索/发现共用）

extension SourceEngine {

    typealias SearchFieldRules = (name: String, author: String, intro: String, kind: String,
                                  lastChapter: String, updateTime: String,
                                  bookUrl: String, coverUrl: String)

    func parseBookList(source: BookSource, ruleBookList rawListRule: String,
                       fieldRules: SearchFieldRules, input: RuleInput,
                       page: Int) async throws -> [Book] {
        var books: [Book] = []
        let eval = RuleEvaluator()
        let env = jsEnv(source, baseUrl: input.baseUrl)

        // @auto:list → 现场探测列表容器
        var ruleBookList = rawListRule
        if rawListRule.hasPrefix("@auto"), let dom = input.dom,
           let probed = RuleProber.probeSearch(dom) {
            ruleBookList = probed.bookList
            logD("auto", "列表结构探测：\(probed.bookList)（score \(String(format: "%.1f", probed.score))）")
        }

        func buildBook(itemInput: RuleInput, fallbackName: String) -> Book? {
            var name = fieldRules.name.isEmpty ? fallbackName
                : eval.first(fieldRules.name, input: itemInput, env: env)
            name = StringExt.stripHTML(name).trimmingCharacters(in: .whitespacesAndNewlines)
            let urlRaw = eval.first(fieldRules.bookUrl, input: itemInput, env: env)
            var bookURL = StringExt.absolute(urlRaw, base: input.baseUrl)
            if bookURL.isEmpty { bookURL = input.baseUrl }
            guard !name.isEmpty || !bookURL.isEmpty else { return nil }

            var cover = fieldRules.coverUrl.isEmpty ? ""
                : eval.first(fieldRules.coverUrl, input: itemInput, env: env)
            if !cover.isEmpty, !cover.hasPrefix("http") {
                cover = StringExt.absolute(cover, base: input.baseUrl)
            }
            var b = Book(sourceId: source.id, sourceName: source.displayName,
                         name: name.isEmpty ? "未知书名" : name,
                         author: StringExt.stripHTML(eval.first(fieldRules.author, input: itemInput, env: env)),
                         intro: StringExt.stripHTML(eval.first(fieldRules.intro, input: itemInput, env: env)),
                         kind: eval.first(fieldRules.kind, input: itemInput, env: env),
                         coverUrl: cover,
                         bookUrl: bookURL,
                         tocUrl: bookURL,
                         lastChapter: eval.first(fieldRules.lastChapter, input: itemInput, env: env),
                         type: source.type)
            b.format = .online
            return b
        }

        // XPath 列表
        let isXPath = ruleBookList.hasPrefix("//") || ruleBookList.hasPrefix("/")
            || ruleBookList.hasPrefix("@xpath:")

        if isXPath, let dom = input.dom {
            let path = ruleBookList.replacingOccurrences(of: "@xpath:", with: "")
            let nodes = XPathEvaluator.query(path, in: dom)
            for node in nodes {
                guard let el = node.elementValue else { continue }
                let itemInput = RuleInput(html: (try? el.outerHtml()) ?? "", dom: el,
                                          json: nil, text: nil, baseUrl: input.baseUrl)
                if let b = buildBook(itemInput: itemInput, fallbackName: "") { books.append(b) }
            }
        } else if let dom = input.dom {
            let items = SelectorBridge.select(ruleBookList, in: dom)
            for el in items {
                let itemInput = RuleInput(html: (try? el.outerHtml()) ?? "", dom: el,
                                          json: nil, text: nil, baseUrl: input.baseUrl)
                if let b = buildBook(itemInput: itemInput, fallbackName: "") { books.append(b) }
            }
        } else if let json = input.json {
            let items = JSONPathLite.query(ruleBookList, json: json)
            for item in items {
                let s = JSONPathLite.stringify(item)
                let itemInput = RuleInput(html: s, dom: nil, json: item, text: s,
                                          baseUrl: input.baseUrl)
                if let b = buildBook(itemInput: itemInput, fallbackName: "") { books.append(b) }
            }
        }

        // 去重
        var seen = Set<String>()
        return books.filter { seen.insert($0.bookUrl + $0.name).inserted }
    }
}

// MARK: - 错误

enum SourceError: LocalizedError {
    case ruleMissing(String)
    case notFound
    case parseFailed(String)
    case blocked

    var errorDescription: String? {
        switch self {
        case .ruleMissing(let r): return "规则缺失或不完整：\(r)"
        case .notFound: return "未找到内容"
        case .parseFailed(let m): return "解析失败：\(m)"
        case .blocked: return "站点拦截（可能需要登录或验证码）"
        }
    }
}

extension Array where Element: Hashable {
    func distinct() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - 无规则启发式目录猜测

enum HeuristicToc {

    static func guess(from dom: Element?, baseUrl: String, bookId: String) -> [Chapter] {
        guard let dom else { return [] }
        // 找包含最多「同构链接」的容器
        var best: [Element] = []
        let containers = SelectorBridge.query("ul, ol, dl, div, table", in: dom)
        for c in containers {
            let links = SelectorBridge.query("a[href]", in: c)
            guard links.count >= 3 else { continue }
            let withChapterWord = links.filter {
                let t = (try? $0.text()) ?? ""
                return t.contains("章") || t.contains("节") || t.contains("回")
                    || t.range(of: "^\\s*\\d+", options: .regularExpression) != nil
            }
            if withChapterWord.count > best.count { best = withChapterWord }
        }
        if best.isEmpty {
            let links = SelectorBridge.query("a[href]", in: dom).filter {
                let t = (try? $0.text()) ?? ""
                return t.contains("章") || t.contains("回") || t.contains("话")
            }
            best = links
        }
        var chapters: [Chapter] = []
        for (i, a) in best.enumerated() {
            let title = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count < 80 else { continue }
            let href = StringExt.absolute(attrOf(a, "href"), base: baseUrl)
            guard !href.isEmpty else { continue }
            chapters.append(Chapter(bookId: bookId, index: i, title: title,
                                    url: href, baseUrl: baseUrl))
        }
        return chapters
    }

    static func extractImagesFromDocument(_ dom: Element, base: String) -> [String] {
        var out: [String] = []
        for img in SelectorBridge.query("img", in: dom) {
            for attr in ["data-original", "data-src", "data-echo", "data-lazy-src", "src"] {
                if hasAttrOf(img, attr) {
                    var u = attrOf(img, attr)
                    if u.hasPrefix("data:") { continue }
                    if u.hasPrefix("//") || u.hasPrefix("http") || u.hasPrefix("/") {
                        u = StringExt.absolute(u, base: base)
                        out.append(u)
                        break
                    }
                }
            }
        }
        return out.distinct()
    }
}
