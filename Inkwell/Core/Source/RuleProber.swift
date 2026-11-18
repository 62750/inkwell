import Foundation
import SwiftSoup

// MARK: - 规则自动探测引擎
//
// 内置书源不写死 CSS —— 站点改版后死规则 30 天内必废。
// 这里改为「结构自适应」：运行时分析 DOM 结构，现场推导出选择器。
//
// 两种探测：
//   1. 结构聚类：找出页面里「同构重复块」最多的容器（列表/目录/图集）
//   2. 文本密度：找出正文容器（Readability 的核心思路）
//
// 产出的选择器直接就是 Legado 规则字符串，可以回写进书源。

enum RuleProber {

    static let maxElements = 9000
    static let maxDepth = 22

    // MARK: 结构聚类

    struct Cluster {
        let parent: Element
        let tag: String
        let children: [Element]
        let score: Double
        var childSelector: String   // 相对文档根，指向这些子元素
    }

    /// 找出页面中重复度最高的同构块容器
    static func clusters(_ root: Element, hintWords: [String],
                         minCount: Int = 4, maxCount: Int = 400) -> [Cluster] {
        var result: [Cluster] = []
        let all = flatten(root)

        for parent in all {
            let kids = parent.children().toArray()
            guard kids.count >= minCount else { continue }

            // 按 (tag + class 集合) 分组
            var groups: [String: [Element]] = [:]
            for k in kids {
                let key = tagOf(k).lowercased() + "|" + classesOf(k).sorted().joined(separator: ".")
                groups[key, default: []].append(k)
            }

            for (key, list) in groups {
                guard list.count >= minCount, list.count <= maxCount else { continue }
                let tag = key.components(separatedBy: "|")[0]

                let score = clusterScore(parent: parent, children: list,
                                         tag: tag, hintWords: hintWords)
                guard score > 0 else { continue }

                let selector = childSelector(parent: parent, tag: tag,
                                             children: list, root: root)
                guard !selector.isEmpty else { continue }
                result.append(Cluster(parent: parent, tag: tag, children: list,
                                      score: score, childSelector: selector))
            }
        }
        return result.sorted { $0.score > $1.score }
    }

    private static func clusterScore(parent: Element, children: [Element],
                                     tag: String, hintWords: [String]) -> Double {
        var score = 0.0
        let n = Double(children.count)

        // 1) 链接浓度：列表项通常都带详情链接
        let withLink = children.filter { hasAttrOf($0, "href") || !SelectorBridge.query("a[href]", in: $0).isEmpty }
        let linkRatio = Double(withLink.count) / n
        score += linkRatio * 3.0

        // 2) 文本长度合理性：标题式短文本 2~80 字
        let lengths = children.map { textLength($0) }
        let avg = lengths.reduce(0, +) / max(1, lengths.count)
        if (2...80).contains(avg) { score += 1.6 }
        else if avg <= 200 { score += 0.5 }
        else { score -= 0.8 }

        // 3) 数量：太少不像列表，太多像导航
        if (5...120).contains(children.count) { score += 1.5 }
        else if children.count > 200 { score -= 0.6 }

        // 4) 容器语义提示
        let own = (classesOf(parent).joined(separator: " ") + " " + idOf(parent)).lowercased()
        for w in hintWords where own.contains(w) { score += 1.2; break }

        // 5) 每项内部要有标题级结构
        let withHeading = children.filter { !SelectorBridge.query("h1,h2,h3,h4,h5,a", in: $0).isEmpty }
        score += Double(withHeading.count) / n * 1.0

        // 6) 纯导航/页脚的容器降权
        let parentTag = tagOf(parent).lowercased()
        if ["nav", "footer", "header", "aside"].contains(parentTag) { score -= 3 }
        if own.contains("nav") || own.contains("footer") || own.contains("menu") { score -= 2 }

        // 7) tag 惩罚：span/div 混排常见于噪声
        if tag == "span" { score -= 0.6 }
        return score
    }

    /// 生成指向「父容器下所有同 tag 子元素」的选择器
    private static func childSelector(parent: Element, tag: String,
                                      children: [Element], root: Element) -> String {
        let base = selectorPath(for: parent, in: root)
        // 组内子元素是否被 class 进一步约束（更精确，优先）
        let classes = classesOf(children.first).sorted()
        if let uniqueClass = classes.first(where: { isValidIdent($0) }),
           isDiscriminating(selector: ".\(uniqueClass)", count: children.count, root: root) {
            let prefixed = base.isEmpty ? ".\(uniqueClass)" : "\(base) .\(uniqueClass)"
            return prefixed
        }
        guard !base.isEmpty else { return tag }
        return "\(base) > \(tag)"
    }

    private static func isDiscriminating(selector: String, count: Int, root: Element) -> Bool {
        guard let els = try? root.select(selector) else { return false }
        let n = els.size()
        return n >= count && n <= count * 3 + 4
    }

    /// 元素在文档中的唯一/近似唯一路径
    static func selectorPath(for e: Element, in root: Element) -> String {
        let id = idOf(e)
        if !id.isEmpty, isValidIdent(id) { return "#\(id)" }

        let classes = classesOf(e).sorted().filter { isValidIdent($0) }
        for c in classes {
            if let els = try? root.select(".\(c)"), els.size() <= 6 {
                return ".\(c)"
            }
        }
        // 组合两三个 class
        if classes.count >= 2 {
            let combo = "." + classes.prefix(3).joined(separator: ".")
            if let els = try? root.select(combo), els.size() <= 6 { return combo }
        }
        // 退化到 tag + 父级
        let tag = tagOf(e).lowercased()
        if let p = e.parent(), p !== root {
            let parentPath = selectorPath(for: p, in: root)
            if !parentPath.isEmpty { return "\(parentPath) \(tag)" }
        }
        return tag
    }

    // MARK: 搜索页探测

    struct SearchProbe {
        var bookList: String
        var name: String
        var author: String
        var cover: String
        var bookUrl: String
        var intro: String
        var score: Double
    }

    static func probeSearch(_ root: Element) -> SearchProbe? {
        let candidates = clusters(root, hintWords: ["result", "list", "book", "novel", "item",
                                                   "search", "grid", "card", "story"])
        for c in candidates.prefix(8) {
            guard let first = c.children.first else { continue }
            let nameRule = nameSelector(in: first)
            let urlRule = linkSelector(in: first)
            guard !nameRule.isEmpty, !urlRule.isEmpty else { continue }

            let coverRule = imageSelector(in: first)
            let authorRule = labeledSelector(in: first, labels: ["作者", "author", "作家"])
            let introRule = classHintSelector(in: first, hints: ["intro", "desc", "summary",
                                                                 "abstract", "brief", "content"])
            return SearchProbe(bookList: c.childSelector,
                               name: nameRule, author: authorRule,
                               cover: coverRule, bookUrl: urlRule,
                               intro: introRule, score: c.score)
        }
        return nil
    }

    // MARK: 目录页探测

    static func probeToc(_ root: Element) -> (list: String, name: String, url: String)? {
        let candidates = clusters(root, hintWords: ["chapter", "catalog", "dir", "list",
                                                    "section", "volume", "mulu", "zhang"],
                                  minCount: 5)
        for c in candidates.prefix(10) {
            // 目录项必须是 <a>
            let anchors = c.children.filter { tagOf($0).lowercased() == "a" && hasAttrOf($0, "href") }
            let isAnchorList = anchors.count >= max(5, c.children.count / 2)

            if isAnchorList {
                return (c.childSelector, "text", "href")
            }
            guard let first = c.children.first else { continue }
            let a = SelectorBridge.query("a[href]", in: first).first
            if let a {
                let aTag = tagOf(a).lowercased()
                let rule = c.childSelector + " > " + aTag
                return (rule, "text", "href")
            }
        }
        return nil
    }

    // MARK: 正文探测（文本密度）

    static func probeContent(_ root: Element) -> String? {
        var best: (Element, Double)?
        for e in flatten(root) {
            let tag = tagOf(e).lowercased()
            if ["script", "style", "nav", "header", "footer", "aside", "form", "select"].contains(tag) {
                continue
            }
            let len = textLength(e)
            guard len >= 260 else { continue }
            let linkDensity = self.linkDensity(e)
            guard linkDensity < 0.4 else { continue }

            let paragraphs = SelectorBridge.query("p", in: e).count
                + SelectorBridge.query("br", in: e).count
            var score = Double(len) * (1.0 - linkDensity)
            score += Double(paragraphs) * 40
            // 正文容器常带语义词
            let own = (classesOf(e).joined(separator: " ") + " " + idOf(e)).lowercased()
            if own.contains("content") || own.contains("article") || own.contains("chapter")
                || own.contains("read") || own.contains("text") || own.contains("body") {
                score *= 1.5
            }
            // 层级太深降权（通常是装饰性容器）
            if depth(of: e) > 18 { score *= 0.7 }

            if best == nil || score > best!.1 { best = (e, score) }
        }
        guard let best else { return nil }
        let path = selectorPath(for: best.0, in: root)
        return path.isEmpty ? nil : path
    }

    // MARK: 漫画图片探测

    static func probeImages(_ root: Element) -> String? {
        bestImageContainer(root)
    }

    static func bestImageContainer(_ root: Element) -> String? {
        var best: (Element, Int)?
        for e in flatten(root) {
            let imgs = SelectorBridge.query("img", in: e)
            guard imgs.count >= 1 else { continue }
            // 过滤头像/logo：只算 src 里像漫画图的
            let real = imgs.filter { img in
                let src = attrOf(img, "src").isEmpty
                    ? (attrOf(img, "data-src").isEmpty ? attrOf(img, "data-original") : attrOf(img, "data-src"))
                    : attrOf(img, "src")
                guard !src.isEmpty else { return false }
                let lower = src.lowercased()
                if lower.contains("logo") || lower.contains("avatar") || lower.contains("icon") { return false }
                if lower.hasPrefix("data:") { return false }
                return true
            }
            guard !real.isEmpty else { continue }
            if best == nil || real.count > best!.1 {
                best = (e, real.count)
            }
        }
        guard let best, best.1 >= 1 else { return nil }
        let path = selectorPath(for: best.0, in: root)
        guard !path.isEmpty else { return "img" }
        return "\(path) img"
    }

    // MARK: 字段探测（在单个列表项内）

    static func nameSelector(in item: Element) -> String {
        // 1) 标题标签
        for tag in ["h1", "h2", "h3", "h4", "h5"] {
            let els = SelectorBridge.query(tag, in: item)
            if let e = els.first {
                let t = ((try? e.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 1 { return "\(tag)@text" }
            }
        }
        // 2) 带 title 属性的链接
        for a in SelectorBridge.query("a", in: item) {
            if hasAttrOf(a, "title"), attrOf(a, "title").count >= 1 { return "tag.a@title" }
        }
        // 3) 最长文本的链接
        let anchors = SelectorBridge.query("a", in: item)
            .sorted { textLength($0) > textLength($1) }
        if let a = anchors.first, textLength(a) > 0 {
            return "tag.a@text"
        }
        // 4) 兜底：item 自身
        return "text"
    }

    static func linkSelector(in item: Element) -> String {
        for a in SelectorBridge.query("a", in: item) where hasAttrOf(a, "href") {
            let href = attrOf(a, "href")
            if href.isEmpty || href.hasPrefix("#") || href.hasPrefix("javascript") { continue }
            return "tag.a@href"
        }
        if hasAttrOf(item, "href") { return "@href" }
        return ""
    }

    static func imageSelector(in item: Element) -> String {
        for img in SelectorBridge.query("img", in: item) {
            for attr in ["data-src", "data-original", "data-echo", "src"] where hasAttrOf(img, attr) {
                let v = attrOf(img, attr)
                if v.isEmpty || v.hasPrefix("data:") { continue }
                return "tag.img@\(attr)"
            }
        }
        return ""
    }

    /// 形如「作者：xxx」的行内文本 → 正则规则
    static func labeledSelector(in item: Element, labels: [String]) -> String {
        let full = ((try? item.text()) ?? "")
        for label in labels {
            let pattern = "\(label)\\s*[:：]\\s*([^\\s|<]{1,24})"
            if let v = RegexChain.firstGroup(full, pattern: pattern), !v.isEmpty {
                return "##\(pattern)##$1"
            }
        }
        return ""
    }

    /// 按 class 语义找子元素
    static func classHintSelector(in item: Element, hints: [String]) -> String {
        for e in flatten(item) {
            let own = classesOf(e).joined(separator: " ").lowercased()
            for h in hints where own.contains(h) {
                let t = textLength(e)
                guard t > 2, t < 800 else { continue }
                if let cls = classesOf(e).sorted().first(where: isValidIdent) {
                    return ".\(cls)@text"
                }
                return "tag.\(tagOf(e).lowercased())@text"
            }
        }
        return ""
    }

    // MARK: 详情页探测

    struct DetailProbe {
        var name: String
        var author: String
        var intro: String
        var cover: String
        var tocUrl: String
    }

    static func probeDetail(_ root: Element) -> DetailProbe {
        var name = ""
        for tag in ["h1", "h2"] {
            if let e = SelectorBridge.query(tag, in: root).first, textLength(e) >= 1 {
                name = "\(tag)@text"
                break
            }
        }
        if name.isEmpty, let meta = SelectorBridge.query("meta[property='og:title']", in: root).first {
            _ = meta
            name = "tag.title@text"
        }

        let full = ((try? root.text()) ?? "")
        var author = ""
        for label in ["作者", "作 者", "Author"] {
            let p = "\(label)\\s*[:：]\\s*([^\\s|<]{1,24})"
            if RegexChain.firstGroup(full, pattern: p) != nil {
                author = "##\(p)##$1"
                break
            }
        }

        var intro = ""
        for hint in ["intro", "desc", "summary", "abstract", "brief", "jianjie"] {
            if let e = SelectorBridge.query(".\(hint)", in: root).first, textLength(e) > 20 {
                intro = ".\(hint)@text"
                break
            }
        }
        if intro.isEmpty {
            let p = "简\\s*介\\s*[:：]\\s*([\\s\\S]{20,600}?)(?:章节目录|最新章节|$)"
            if RegexChain.firstGroup(full, pattern: p) != nil {
                intro = "##\(p)##$1"
            }
        }

        var cover = ""
        if let og = SelectorBridge.query("meta[property='og:image']", in: root).first {
            _ = og
            cover = "tag.meta@content"
        }
        if cover.isEmpty, let img = SelectorBridge.query("img", in: root)
            .first(where: { attrOf($0, "src").contains("cover") || classesOf($0).contains("cover") }) {
            _ = img
            cover = "class.cover@tag.img@src"
        }

        // 目录入口：文本含「目录/章节」的链接
        var tocUrl = ""
        for a in SelectorBridge.query("a[href]", in: root) {
            let t = ((try? a.text()) ?? "")
            if t.contains("章节目录") || t.contains("全部章节") || t.contains("目录") {
                if let cls = classesOf(a).sorted().first(where: isValidIdent) {
                    tocUrl = ".\(cls)@href"
                } else {
                    tocUrl = "tag.a@href"
                }
                break
            }
        }
        return DetailProbe(name: name, author: author, intro: intro,
                           cover: cover, tocUrl: tocUrl)
    }

    // MARK: 工具

    static func flatten(_ root: Element) -> [Element] {
        var out: [Element] = []
        var queue: [(Element, Int)] = [(root, 0)]
        var head = 0
        while head < queue.count, out.count < maxElements {
            let (e, d) = queue[head]
            head += 1
            out.append(e)
            if d >= maxDepth { continue }
            for c in e.children().toArray() {
                queue.append((c, d + 1))
            }
        }
        return out
    }

    static func textLength(_ e: Element) -> Int {
        ((try? e.text())?.count) ?? 0
    }

    static func linkDensity(_ e: Element) -> Double {
        let total = textLength(e)
        guard total > 0 else { return 1 }
        let linkLen = SelectorBridge.query("a", in: e).reduce(0) { $0 + textLength($1) }
        return Double(linkLen) / Double(total)
    }

    static func depth(of e: Element) -> Int {
        var d = 0
        var cur = e.parent()
        while let c = cur { d += 1; cur = c.parent(); if d > 40 { break } }
        return d
    }

    static func isValidIdent(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 48 else { return false }
        let bad = CharacterSet(charactersIn: " \t\n/\\#[]()>+~*:,'\"")
        return s.rangeOfCharacter(from: bad) == nil
    }
}
