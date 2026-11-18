import Foundation
import SwiftSoup

// MARK: - 输入一个域名，生成一个能用的书源
//
// 流程：抓首页 → 找搜索表单 → 猜搜索路径 → 抓搜索结果页 → 结构探测 → 产出规则
// 全程不需要用户懂 XPath。生成的源可以再手动微调。

struct AutoBuildResult: Sendable {
    var source: BookSource
    var log: [String]
    var confidence: Double
    var success: Bool
}

enum SourceAutoBuilder {

    static let searchInputNames = ["q", "kw", "key", "keyword", "searchkey", "wd",
                                  "word", "s", "query", "searchword", "k"]

    // MARK: 主流程

    static func build(siteURL raw: String, probeKeyword: String = "斗破苍穹") async -> AutoBuildResult {
        var log: [String] = []
        var source = BookSource()

        guard let normalized = normalizeSite(raw) else {
            log.append("网址不合法：\(raw)")
            source.bookSourceName = "无效地址"
            return AutoBuildResult(source: source, log: log, confidence: 0, success: false)
        }
        let host = URL(string: normalized)?.host ?? normalized
        source.bookSourceUrl = normalized
        source.bookSourceName = host
        source.bookSourceGroup = "自动生成"

        // 1) 首页
        var homeHTML = ""
        var homeDoc: Document?
        do {
            let r = try await HTTPClient.shared.request(url: normalized)
            homeHTML = r.text
            homeDoc = try? SwiftSoup.parse(homeHTML)
            log.append("首页 \(r.statusCode) · \(homeHTML.count) 字符")
        } catch {
            log.append("首页请求失败：\(error.localizedDescription)")
        }

        // 2) 搜索入口
        var searchTemplate = ""
        if let doc = homeDoc {
            searchTemplate = findSearchTemplate(in: doc, base: normalized)
            if !searchTemplate.isEmpty {
                log.append("找到搜索表单：\(searchTemplate)")
            }
        }
        if searchTemplate.isEmpty {
            // 逐个试探常见路径
            let guesses = searchTemplateGuesses(host: normalized)
            for g in guesses {
                let testURL = g.replacingOccurrences(of: "{{key}}", with: StringExt.urlEncode(probeKeyword))
                if let r = try? await HTTPClient.shared.request(url: testURL),
                   r.statusCode == 200, r.text.count > 800 {
                    if let doc = try? SwiftSoup.parse(r.text),
                       RuleProber.probeSearch(doc) != nil {
                        searchTemplate = g
                        log.append("猜测搜索路径命中：\(g)")
                        break
                    }
                }
            }
        }
        if searchTemplate.isEmpty {
            searchTemplate = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + "/search?q={{key}}"
            log.append("未找到搜索入口，使用默认模板")
        }
        source.searchUrl = searchTemplate

        // 3) 抓搜索结果页并探测
        let searchURL = searchTemplate.replacingOccurrences(
            of: "{{key}}", with: StringExt.urlEncode(probeKeyword))
        var confidence = 0.0
        do {
            let r = try await HTTPClient.shared.request(url: searchURL, referer: normalized)
            log.append("搜索页 \(r.statusCode) · \(r.text.count) 字符")
            if let doc = try? SwiftSoup.parse(r.text),
               let probe = RuleProber.probeSearch(doc) {
                source.ruleSearch.bookList = probe.bookList
                source.ruleSearch.name = probe.name
                source.ruleSearch.author = probe.author
                source.ruleSearch.coverUrl = probe.cover
                source.ruleSearch.bookUrl = probe.bookUrl
                source.ruleSearch.intro = probe.intro
                confidence = min(1.0, probe.score / 9.0)
                let hit = (try? doc.select(probe.bookList).size()) ?? 0
                log.append("列表探测：\(probe.bookList)（\(hit) 项）")
            } else {
                log.append("搜索页结构探测失败，回退自适应规则")
            }
        } catch {
            log.append("搜索页请求失败：\(error.localizedDescription)")
        }

        // 4) 详情/目录/正文：先用自适应规则，用户可一键校准
        applyAutoFallback(&source)

        // 5) 判断类型：首页图片密度高 → 漫画
        if let doc = homeDoc {
            let imgs = SelectorBridge.query("img", in: doc).count
            let links = SelectorBridge.query("a", in: doc).count
            if imgs > 12, imgs * 3 > max(1, links) {
                source.bookSourceType = SourceType.image.rawValue
                log.append("判定为漫画源（图片密度 \(imgs)/\(links)）")
            }
        }

        source.bookSourceComment = log.suffix(4).joined(separator: " · ")
        let ok = confidence > 0.15
        return AutoBuildResult(source: source, log: log,
                               confidence: confidence, success: ok)
    }

    /// 只做校准：给已有源重新探一遍搜索规则
    static func calibrate(source: BookSource,
                          keyword: String = "斗破苍穹") async -> (BookSource, [String]) {
        var s = source
        var log: [String] = []
        let probeKey = keyword
        let searchURL = s.searchUrl.isEmpty
            ? s.bookSourceUrl
            : s.searchUrl.replacingOccurrences(of: "{{key}}", with: StringExt.urlEncode(probeKey))
        guard let r = try? await HTTPClient.shared.request(url: searchURL,
                                                          headers: s.headerDictionary) else {
            return (s, ["校准失败：页面取不到"])
        }
        guard let doc = try? SwiftSoup.parse(r.text) else {
            return (s, ["校准失败：HTML 解析失败"])
        }

        if s.type == .image {
            if let imgRule = RuleProber.probeImages(doc) {
                s.ruleContent.content = imgRule + "@src"
                log.append("图片规则：\(imgRule)")
            }
        } else if let probe = RuleProber.probeSearch(doc) {
            s.ruleSearch.bookList = probe.bookList
            s.ruleSearch.name = probe.name
            if !probe.author.isEmpty { s.ruleSearch.author = probe.author }
            if !probe.cover.isEmpty { s.ruleSearch.coverUrl = probe.cover }
            if !probe.bookUrl.isEmpty { s.ruleSearch.bookUrl = probe.bookUrl }
            log.append("搜索规则已更新：\(probe.bookList)")
        } else if let toc = RuleProber.probeToc(doc) {
            s.ruleToc.chapterList = toc.list
            s.ruleToc.chapterName = toc.name
            s.ruleToc.chapterUrl = toc.url
            log.append("目录规则已更新：\(toc.list)")
        } else if let content = RuleProber.probeContent(doc) {
            s.ruleContent.content = content + "@html"
            log.append("正文规则已更新：\(content)")
        } else {
            log.append("没探测出可用结构")
        }
        s.bookSourceComment = log.joined(separator: " · ")
        return (s, log)
    }

    // MARK: 搜索表单

    static func findSearchTemplate(in doc: Document, base: String) -> String {
        // 1) <form> 里带搜索 input
        for form in SelectorBridge.query("form", in: doc) {
            let inputs = SelectorBridge.query("input", in: form)
            for input in inputs {
                let name = attrOf(input, "name")
                guard searchInputNames.contains(name.lowercased()) else { continue }
                var action = attrOf(form, "action")
                if action.isEmpty { action = base }
                action = StringExt.absolute(action, base: base)
                let method = attrOf(form, "method").uppercased()
                if method == "POST" {
                    // POST 表单转成 Legado 的 ,{...} 形态
                    var params: [String] = []
                    for i in inputs {
                        let n = attrOf(i, "name")
                        guard !n.isEmpty else { continue }
                        let v = attrOf(i, "value")
                        params.append("\(n)=\(n == name ? "{{key}}" : v)")
                    }
                    let body = params.joined(separator: "&")
                    return "\(action),{\"method\":\"POST\",\"body\":\"\(body)\"}"
                }
                return action.contains("?")
                    ? "\(action)&\(name)={{key}}"
                    : "\(action)?\(name)={{key}}"
            }
        }
        // 2) 页面里的搜索链接（?q= 之类）
        for a in SelectorBridge.query("a[href]", in: doc) {
            let href = attrOf(a, "href")
            guard href.contains("search") || href.contains("-search") else { continue }
            if href.contains("q=") || href.contains("key") || href.contains("wd=") {
                return StringExt.absolute(href, base: base)
            }
        }
        return ""
    }

    static func searchTemplateGuesses(host: String) -> [String] {
        let base = host.hasPrefix("http") ? host
            : "https://" + host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return [
            "\(trimmed)/search?q={{key}}",
            "\(trimmed)/search?keyword={{key}}",
            "\(trimmed)/search?searchkey={{key}}",
            "\(trimmed)/search?wd={{key}}",
            "\(trimmed)/s?q={{key}}",
            "\(trimmed)/search/{{key}}",
            "\(trimmed)/index.php?q={{key}}",
            "\(trimmed)/so/{{key}}"
        ]
    }

    static func normalizeSite(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            return s
        }
        // 纯域名
        if s.contains(".") && !s.contains(" ") {
            return "https://" + s
        }
        return nil
    }

    // MARK: 自适应兜底规则

    /// 探测失败时，把源标记成 @auto，运行时现场推导
    static func applyAutoFallback(_ source: inout BookSource) {
        if source.ruleSearch.bookList.isEmpty {
            source.ruleSearch.bookList = "@auto:list"
            source.ruleSearch.name = "@auto:name"
            source.ruleSearch.author = "@auto:author"
            source.ruleSearch.coverUrl = "@auto:cover"
            source.ruleSearch.bookUrl = "@auto:url"
        }
        if source.ruleBookInfo.name.isEmpty { source.ruleBookInfo.name = "@auto:name" }
        if source.ruleToc.chapterList.isEmpty {
            source.ruleToc.chapterList = "@auto:chapterList"
            source.ruleToc.chapterName = "text"
            source.ruleToc.chapterUrl = "href"
        }
        if source.ruleContent.content.isEmpty {
            source.ruleContent.content = source.type == .image
                ? "@auto:images"
                : "@auto:content"
        }
    }
}
