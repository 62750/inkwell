import Foundation
import SwiftSoup

// MARK: - 规则求值器（Legado AnalyzeRule 等价物）
//
// 一条规则的处理管线：
//   1. 按 ||  拆（取第一个非空结果的分支）
//   2. 按 &&  拆（所有分支结果拼接，用于合并多字段）
//   3. 按 %%  拆（A 的结果里剔除 B 的结果）
//   4. 处理尾部 ##正则##替换  链
//   5. 引擎判定：@js: / <js> / @json: / @xpath: / @css: / // / $. / jsoup选择器
//   6. 去掉空字符串、修剪空白

struct RuleInput {
    var html: String?
    var dom: Element?
    var json: Any?
    var text: String?
    var baseUrl: String

    static func html(_ s: String, baseUrl: String) -> RuleInput {
        RuleInput(html: s, dom: (try? SwiftSoup.parse(s)), json: nil, text: nil, baseUrl: baseUrl)
    }
    static func json(_ s: String, baseUrl: String) -> RuleInput {
        let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8),
                                                    options: [.fragmentsAllowed]))
        return RuleInput(html: s, dom: nil, json: obj, text: s, baseUrl: baseUrl)
    }
    static func text(_ s: String, baseUrl: String) -> RuleInput {
        RuleInput(html: nil, dom: nil, json: nil, text: s, baseUrl: baseUrl)
    }
}

final class RuleEvaluator: @unchecked Sendable {

    private var variables: [String: String] = [:]
    /// 同一次解析里复用 @auto 探测结果，避免每个字段都遍历一遍 DOM
    private var autoCache: [String: String] = [:]

    func resetVariables() { variables.removeAll() }

    func setVariable(_ k: String, _ v: String) { variables[k] = v }

    /// 主入口：返回全部结果
    func eval(_ rule: String, input: RuleInput, env: JSEnv) -> [String] {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1) ||
        let orBranches = splitTopLevel(trimmed, by: "||")
        if orBranches.count > 1 {
            for branch in orBranches {
                let r = eval(branch, input: input, env: env)
                let cleaned = r.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !cleaned.isEmpty { return cleaned }
            }
            return []
        }

        // 2) &&
        let andBranches = splitTopLevel(trimmed, by: "&&")
        if andBranches.count > 1 {
            var out: [String] = []
            for branch in andBranches {
                out.append(contentsOf: eval(branch, input: input, env: env))
            }
            return dedupe(out)
        }

        // 3) %%
        let excluding = splitTopLevel(trimmed, by: "%%")
        if excluding.count > 1 {
            let base = eval(excluding[0], input: input, env: env)
            var minus = Set<String>()
            for ex in excluding.dropFirst() {
                for v in eval(ex, input: input, env: env) { minus.insert(v) }
            }
            return base.filter { !minus.contains($0) }
        }

        // 4) ## 正则链
        let (core, pairs) = RegexChain.partition(trimmed)
        var results = evalCore(core, input: input, env: env)
        if !pairs.isEmpty {
            results = RegexChain.apply(results, pairs: pairs)
        }
        // 5) 清洗
        return dedupe(results.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty })
    }

    func first(_ rule: String, input: RuleInput, env: JSEnv) -> String {
        eval(rule, input: input, env: env).first ?? ""
    }

    // MARK: - 核心引擎判定

    private func evalCore(_ rule: String, input: RuleInput, env: JSEnv) -> [String] {
        var r = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return [] }

        // @put:{k:rule}
        if r.hasPrefix("@put:") {
            return []
        }
        // @get:{k}
        if r.hasPrefix("@get:") {
            let key = String(r.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            return [variables[key] ?? ""]
        }

        // 内联 JS：<js>...</js>
        if let jsRange = r.range(of: "<js>"), let jsEnd = r.range(of: "</js>", range: jsRange.upperBound..<r.endIndex) {
            let prefix = String(r[r.startIndex..<jsRange.lowerBound])
            let script = String(r[jsRange.upperBound..<jsEnd.lowerBound])
            if prefix.isEmpty {
                return runJS(script, input: input, env: env)
            }
            let prefixResults = evalCore(prefix, input: input, env: env)
            return prefixResults.flatMap { _ in runJS(script, input: input, env: env) }
        }

        // 显式前缀
        // @auto: 现场探测（内置自适应源用）
        if r.hasPrefix("@auto:") || r.hasPrefix("@AUTO:") {
            let kind = String(r.dropFirst(6)).lowercased()
            return resolveAuto(kind, input: input)
        }

        if r.hasPrefix("@js:") || r.hasPrefix("js:") || r.hasPrefix("@JS:") {
            let script = r.replacingOccurrences(of: "@js:", with: "")
                .replacingOccurrences(of: "@JS:", with: "")
                .replacingOccurrences(of: "js:", with: "")
            return runJS(script, input: input, env: env)
        }
        if r.hasPrefix("@json:") || r.hasPrefix("@JSON:") {
            let path = String(r.dropFirst(6))
            return evalJSON(path, input: input)
        }
        if r.hasPrefix("@xpath:") || r.hasPrefix("@XPath:") || r.hasPrefix("@XPATH:") {
            let path = String(r.dropFirst(7))
            return evalXPath(path, input: input)
        }
        if r.hasPrefix("@css:") {
            let path = String(r.dropFirst(5))
            return evalCSS(path, input: input)
        }
        if r.hasPrefix("@text") && r.count > 5 {
            // @text:xxx 少见，忽略
        }

        // 纯 XPath
        if r.hasPrefix("//") || r.hasPrefix("/") || r.hasPrefix("(//") || r.hasPrefix("./") {
            return evalXPath(r, input: input)
        }

        // JSON 输入 + JSONPath
        if input.json != nil && (r.hasPrefix("$.") || r.hasPrefix("$[") || r.hasPrefix("$..")) {
            return evalJSON(r, input: input)
        }

        // 文本输入
        if let text = input.text, input.dom == nil {
            // 纯文本规则一般只有正则，已经在上面处理完了
            return [text]
        }

        // jsoup 选择器
        return evalCSS(r, input: input)
    }

    private func evalXPath(_ path: String, input: RuleInput) -> [String] {
        guard let dom = input.dom else { return [] }
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.hasPrefix("/") && !p.hasPrefix("(") { p = "//" + p }
        let nodes = XPathEvaluator.query(p, in: dom)
        if nodes.isEmpty {
            // 退化：Legado 里有些 XPath 其实是 jsoup CSS
            if p.contains("@") { return evalCSS(path, input: input) }
            return []
        }
        return nodes.map { $0.stringValue }
    }

    private func evalJSON(_ path: String, input: RuleInput) -> [String] {
        var json = input.json
        if json == nil, let h = input.html {
            json = try? JSONSerialization.jsonObject(with: Data(h.utf8),
                                                     options: [.fragmentsAllowed])
        }
        guard let json else { return [] }
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("@json:") { p = String(p.dropFirst(6)) }
        return JSONPathLite.queryStrings(p, json: json)
    }

    private func evalCSS(_ rule: String, input: RuleInput) -> [String] {
        guard let dom = input.dom else {
            // 只有 JSON 时，尝试把 JSON 当 HTML 再解析一次
            if let h = input.html, let d = try? SwiftSoup.parse(h) {
                return SelectorBridge.extract(rule, in: d)
            }
            return []
        }
        return SelectorBridge.extract(rule, in: dom)
    }

    private func runJS(_ script: String, input: RuleInput, env: JSEnv) -> [String] {
        var vars = variables
        var e = env
        e.baseUrl = input.baseUrl
        e.variables = vars
        let payload = input.html ?? input.text ?? ""
        let out = JSEngine.run(script: script, html: payload, env: e, sharedVariables: &vars)
        variables = vars
        if out.isEmpty { return [] }
        // JS 返回数组时用 \n 拼接，这里保持整体
        return out.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - 自适应探测

    /// @auto:name / author / cover / url / intro / content / images
    private func resolveAuto(_ kind: String, input: RuleInput) -> [String] {
        guard let dom = input.dom else { return [] }
        let cacheKey = "\(kind)#\(ObjectIdentifier(dom).hashValue)"
        if let cached = autoCache[cacheKey] {
            return cached.isEmpty ? [] : evalCSS(cached, input: input)
        }

        var derived = ""
        switch kind {
        case "name":
            derived = RuleProber.nameSelector(in: dom)
        case "author":
            derived = RuleProber.labeledSelector(in: dom, labels: ["作者", "作 者", "Author"])
        case "cover":
            derived = RuleProber.imageSelector(in: dom)
        case "url", "bookurl":
            derived = RuleProber.linkSelector(in: dom)
        case "intro":
            derived = RuleProber.classHintSelector(in: dom, hints: ["intro", "desc", "summary",
                                                                   "abstract", "brief"])
        case "content":
            derived = (RuleProber.probeContent(dom) ?? "") + "@html"
        case "images":
            if let c = RuleProber.probeImages(dom) { derived = c + "@src" }
        default:
            derived = ""
        }
        autoCache[cacheKey] = derived
        guard !derived.isEmpty else { return [] }
        return evalCSS(derived, input: input)
    }

    // MARK: - 工具

    /// 按顶层分隔符拆分（跳过引号、括号内）
    func splitTopLevel(_ s: String, by sep: String) -> [String] {
        guard !s.isEmpty, !sep.isEmpty else { return [s] }
        let sepChars = Array(sep)
        let chars = Array(s)
        var out: [String] = []
        var buf = ""
        var depth = 0
        var quote: Character?
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                buf.append(ch)
                if ch == q { quote = nil }
                i += 1
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; buf.append(ch); i += 1; continue }
            if ch == "(" || ch == "[" || ch == "{" { depth += 1; buf.append(ch); i += 1; continue }
            if ch == ")" || ch == "]" || ch == "}" { depth -= 1; buf.append(ch); i += 1; continue }
            if depth == 0, i + sepChars.count <= chars.count,
               Array(chars[i..<(i + sepChars.count)]) == sepChars {
                out.append(buf)
                buf = ""
                i += sepChars.count
                continue
            }
            buf.append(ch)
            i += 1
        }
        out.append(buf)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func dedupe(_ arr: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in arr {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}
