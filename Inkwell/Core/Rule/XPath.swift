import Foundation
import SwiftSoup

// MARK: - XPath 求值引擎
//
// iOS 上没有 NSXMLDocument，SwiftSoup 只提供 CSS 选择器。
// 而 Legado 生态里 80% 的书源规则是 XPath，所以这里手写一个覆盖常用子集的求值器。
//
// 支持：
//   /  //  .  ..  *  name  @attr  text()  node()
//   [n] [last()] [last()-n] [position()>n] [@a] [@a='v'] [@a!='v']
//   [contains(@a,'v')] [starts-with(@a,'v')] [ends-with(@a,'v')]
//   [text()='v'] [contains(text(),'v')] [not(...)] [matches(...,'re')]
//   [string-length(text())>n] [child] [.//desc] [child[@a='v']]
//   A | B  联合

// MARK: 节点抽象

enum XNode {
    case element(Element)
    case attribute(name: String, value: String, owner: Element)
    case text(String)

    var stringValue: String {
        switch self {
        case .element(let e):
            return (try? e.text()) ?? ""
        case .attribute(_, let v, _):
            return v
        case .text(let t):
            return t
        }
    }

    var elementValue: Element? {
        if case .element(let e) = self { return e }
        return nil
    }

    var outerHTML: String {
        switch self {
        case .element(let e): return (try? e.outerHtml()) ?? ""
        case .attribute(_, let v, _): return v
        case .text(let t): return t
        }
    }

    var innerHTML: String {
        switch self {
        case .element(let e): return (try? e.html()) ?? ""
        default: return stringValue
        }
    }
}

// MARK: 步骤

enum XAxis {
    case child
    case descendant       // //
    case descendantOrSelf
    case parent
    case selfAxis
    case attribute        // @x
    case ancestor
    case followingSibling
    case precedingSibling
}

enum XTest {
    case name(String)
    case anyElement                 // *
    case textNode                   // text()
    case anyNode                    // node()
    case attribute(String)          // @href
}

indirect enum XPredicate {
    case index(Int)                  // [2]
    case last
    case lastOffset(Int)             // [last()-1]
    case positionGT(Int)
    case positionLT(Int)
    case positionEQ(Int)
    case attrExists(String)
    case attrEquals(String, String)
    case attrNotEquals(String, String)
    case containsAttr(String, String)
    case startsWithAttr(String, String)
    case endsWithAttr(String, String)
    case textEquals(String)
    case textNotEquals(String)
    case containsText(String)
    case startsWithText(String)
    case endsWithText(String)
    case matchesText(String)
    case matchesAttr(String, String)
    case stringLengthGT(Int)
    case stringLengthLT(Int)
    case not(XPredicate)
    case and(XPredicate, XPredicate)
    case or(XPredicate, XPredicate)
    case hasChild([XStep])           // [div]  [.//a]
}

struct XStep {
    var axis: XAxis
    var test: XTest
    var predicates: [XPredicate] = []

    var isAttributeStep: Bool {
        if case .attribute = test { return true }
        if axis == .attribute { return true }
        return false
    }
}

// MARK: - 解析器

final class XPathParser {
    private let chars: [Character]
    private var pos = 0

    init(_ s: String) { chars = Array(s) }

    static func parse(_ expression: String) -> [[XStep]] {
        // 顶层 | 联合
        let branches = splitUnion(expression)
        return branches.compactMap { branch in
            let p = XPathParser(branch)
            return p.parsePath()
        }
    }

    private static func splitUnion(_ s: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var inQuote: Character?
        var cur = ""
        for ch in s {
            if let q = inQuote {
                cur.append(ch)
                if ch == q { inQuote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { inQuote = ch; cur.append(ch); continue }
            if ch == "[" { depth += 1; cur.append(ch); continue }
            if ch == "]" { depth -= 1; cur.append(ch); continue }
            if ch == "|" && depth == 0 { out.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out
    }

    private var current: Character? { pos < chars.count ? chars[pos] : nil }

    private func peek(_ n: Int = 1) -> Character? {
        pos + n < chars.count ? chars[pos + n] : nil
    }

    private func skipSpace() {
        while let c = current, c == " " || c == "\n" || c == "\t" || c == "\r" { pos += 1 }
    }

    func parsePath() -> [XStep]? {
        var steps: [XStep] = []
        skipSpace()
        // 起始：绝对路径 / 或 //
        var pendingDescendant = false
        if current == "/" {
            pos += 1
            if current == "/" { pos += 1; pendingDescendant = true }
            else if current == nil { return [] }
            // 绝对路径仍从文档根开始
        }
        while true {
            skipSpace()
            guard current != nil else { break }
            if current == "/" {
                pos += 1
                if current == "/" { pos += 1; pendingDescendant = true; continue }
                else { continue }
            }
            if current == "[" { break }
            guard let step = parseStep(descendant: pendingDescendant) else { return nil }
            pendingDescendant = false
            steps.append(step)
        }
        return steps
    }

    private func parseStep(descendant: Bool) -> XStep? {
        skipSpace()

        // ..  父节点
        if current == ".", peek() == "." {
            pos += 2
            var step = XStep(axis: .parent, test: .anyNode)
            step.predicates = parsePredicates()
            return step
        }
        // .  自身
        if current == ".", peek() != "/" {
            pos += 1
            var step = XStep(axis: .selfAxis, test: .anyNode)
            step.predicates = parsePredicates()
            if step.predicates.isEmpty && (current == "/" || current == nil) {
                // 单独的 "." 无意义，跳过
                return nil
            }
            return step
        }
        // @attr
        if current == "@" {
            pos += 1
            let name = readName()
            var step = XStep(axis: .attribute, test: .attribute(name))
            step.predicates = parsePredicates()
            return step
        }

        let axis: XAxis = descendant ? .descendant : .child

        // text() / node() / comment()
        if let fn = readFunctionNameIfMatches(["text", "node", "comment"]) {
            var step = XStep(axis: axis,
                             test: fn == "text" ? .textNode : .anyNode)
            step.predicates = parsePredicates()
            return step
        }

        // * 或 name 或 *[name]
        if current == "*" {
            pos += 1
            var step = XStep(axis: axis, test: .anyElement)
            step.predicates = parsePredicates()
            return step
        }

        let name = readName()
        guard !name.isEmpty else { return nil }
        var step = XStep(axis: axis, test: .name(name.lowercased()))
        step.predicates = parsePredicates()
        return step
    }

    private func readFunctionNameIfMatches(_ names: [String]) -> String? {
        let save = pos
        let n = readName()
        guard let c = current, c == "(" else { pos = save; return nil }
        if names.contains(n.lowercased()) {
            pos += 1                    // (
            if current == ")" { pos += 1 }
            return n.lowercased()
        }
        pos = save
        return nil
    }

    private func readName() -> String {
        skipSpace()
        var s = ""
        while let c = current,
              c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." || c == ":" || c == "*" {
            if c == "." && peek() == "." { break }
            s.append(c)
            pos += 1
        }
        return s
    }

    private func parsePredicates() -> [XPredicate] {
        var out: [XPredicate] = []
        while true {
            skipSpace()
            guard current == "[" else { break }
            pos += 1
            if let p = parseBooleanExpr() {
                out.append(p)
            } else {
                // 无法解析时跳过整段
                skipToMatchingBracket()
            }
            skipSpace()
            if current == "]" { pos += 1 }
        }
        return out
    }

    private func skipToMatchingBracket() {
        var depth = 1
        var quote: Character?
        while let c = current {
            pos += 1
            if let q = quote {
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "[" { depth += 1 }
            if c == "]" { depth -= 1; if depth == 0 { return } }
        }
    }

    // MARK: 布尔表达式（predicate 内部）

    private func parseBooleanExpr() -> XPredicate? {
        var left = parseBooleanTerm()
        while true {
            skipSpace()
            if let c = current, c == "]" { break }
            let save = pos
            let op = readKeyword()          // and / or / &&
            if op == "and" || op == "&&" {
                guard let right = parseBooleanTerm() else { pos = save; break }
                left = left.map { .and($0, right) } ?? right
            } else if op == "or" || op == "|" {
                guard let right = parseBooleanTerm() else { pos = save; break }
                left = left.map { .or($0, right) } ?? right
            } else {
                pos = save
                break
            }
        }
        return left
    }

    private func parseBooleanTerm() -> XPredicate? {
        skipSpace()
        let save = pos
        if readKeyword() == "not" {
            skipSpace()
            if current == "(" {
                pos += 1
                let inner = parseBooleanExpr()
                skipSpace()
                if current == ")" { pos += 1 }
                if let inner { return .not(inner) }
                return nil
            }
            pos = save
        }

        // 纯数字 => 位置索引
        if let c = current, c.isNumber {
            var num = ""
            while let d = current, d.isNumber { num.append(d); pos += 1 }
            skipSpace()
            // [2] 或 [2]/child
            if current == "]" || current == "/" || current == nil {
                return .index(Int(num) ?? 1)
            }
            // 2 < position() 之类，罕见，忽略
            skipToMatchingBracket()
            return nil
        }

        // last()
        let save2 = pos
        let fn = readKeyword()
        switch fn {
        case "last":
            skipSpace()
            if current == "(" { pos += 1 }
            skipSpace()
            if current == ")" { pos += 1 }
            skipSpace()
            if current == "-" {
                pos += 1
                skipSpace()
                var num = ""
                while let d = current, d.isNumber { num.append(d); pos += 1 }
                return .lastOffset(Int(num) ?? 0)
            }
            return .last

        case "position":
            skipSpace()
            if current == "(" { pos += 1 }
            skipSpace()
            if current == ")" { pos += 1 }
            skipSpace()
            let cmp = readCompareOperator()
            skipSpace()
            var num = ""
            while let d = current, d.isNumber { num.append(d); pos += 1 }
            guard let v = Int(num) else { return nil }
            switch cmp {
            case ">": return .positionGT(v)
            case "<": return .positionLT(v)
            case ">=": return .positionGT(v - 1)
            case "<=": return .positionLT(v + 1)
            default: return .positionEQ(v)
            }

        case "contains", "starts-with", "ends-with", "matches", "string-length":
            skipSpace()
            if current == "(" { pos += 1 }
            skipSpace()
            let target = readArg()
            skipSpace()
            var arg = ""
            if current == "," {
                pos += 1
                skipSpace()
                arg = readStringLiteralOrRaw()
                skipSpace()
            }
            if current == ")" { pos += 1 }
            switch fn {
            case "contains":
                if target == "text()" { return .containsText(arg) }
                if target.hasPrefix("@") { return .containsAttr(String(target.dropFirst()), arg) }
                return .containsText(arg)
            case "starts-with":
                if target == "text()" { return .startsWithText(arg) }
                if target.hasPrefix("@") { return .startsWithAttr(String(target.dropFirst()), arg) }
                return .startsWithText(arg)
            case "ends-with":
                if target == "text()" { return .endsWithText(arg) }
                if target.hasPrefix("@") { return .endsWithAttr(String(target.dropFirst()), arg) }
                return .endsWithText(arg)
            case "matches":
                if target.hasPrefix("@") { return .matchesAttr(String(target.dropFirst()), arg) }
                return .matchesText(arg)
            case "string-length":
                let cmp = readCompareOperator()
                var num = ""
                while let d = current, d.isNumber { num.append(d); pos += 1 }
                let v = Int(num) ?? 0
                return cmp == "<" ? .stringLengthLT(v) : .stringLengthGT(v)
            default:
                return nil
            }

        case "text":
            skipSpace()
            if current == "(" { pos += 1 }
            skipSpace()
            if current == ")" { pos += 1 }
            skipSpace()
            let cmp = readCompareOperator()
            skipSpace()
            if cmp.isEmpty { return .containsText("") }   // 仅 text() 存在性判断
            let v = readStringLiteralOrRaw()
            if cmp == "!=" { return .textNotEquals(v) }
            return .textEquals(v)

        default:
            // @attr 比较
            if fn.hasPrefix("@") {
                let attr = String(fn.dropFirst())
                skipSpace()
                let cmp = readCompareOperator()
                skipSpace()
                if cmp.isEmpty { return .attrExists(attr) }
                let v = readStringLiteralOrRaw()
                if cmp == "!=" { return .attrNotEquals(attr, v) }
                return .attrEquals(attr, v)
            }
            // 子路径 predicate：[div] 或 [.//a] 或 [a[@x]]
            pos = save
            if let sub = parseSubPathPredicate() { return .hasChild(sub) }
            pos = save2
            skipToMatchingBracket()
            return nil
        }
    }

    private func parseSubPathPredicate() -> [XStep]? {
        // 尝试解析一段子路径直到 ]
        let start = pos
        var depth = 0
        var inQ: Character?
        var end = pos
        while end < chars.count {
            let c = chars[end]
            if let q = inQ { if c == q { inQ = nil }; end += 1; continue }
            if c == "\"" || c == "'" { inQ = c; end += 1; continue }
            if c == "[" { depth += 1 }
            if c == "]" { if depth == 0 { break }; depth -= 1 }
            end += 1
        }
        guard end <= chars.count else { return nil }
        let sub = String(chars[start..<end])
        guard !sub.isEmpty else { return nil }
        let p = XPathParser(sub)
        let steps = p.parsePath()
        if var steps, !steps.isEmpty {
            // 第一个步骤如果不是 descendant/self，补成 child
            if steps[0].axis == .child && sub.hasPrefix(".") {
                steps[0].axis = .selfAxis
            }
            return steps
        }
        return nil
    }

    private func readCompareOperator() -> String {
        skipSpace()
        if current == "!" , peek() == "=" { pos += 2; return "!=" }
        if current == ">" , peek() == "=" { pos += 2; return ">=" }
        if current == "<" , peek() == "=" { pos += 2; return "<=" }
        if current == "=" { pos += 1; return "=" }
        if current == ">" { pos += 1; return ">" }
        if current == "<" { pos += 1; return "<" }
        return ""
    }

    private func readStringLiteralOrRaw() -> String {
        skipSpace()
        guard let q = current, q == "\"" || q == "'" else {
            var s = ""
            while let c = current, c != "]" && c != ")" && c != "," {
                s.append(c); pos += 1
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
        pos += 1
        var s = ""
        while let c = current, c != q {
            if c == "\\", let n = peek() {
                switch n {
                case "n": s.append("\n")
                case "t": s.append("\t")
                default: s.append(n)
                }
                pos += 2
                continue
            }
            s.append(c); pos += 1
        }
        if current == q { pos += 1 }
        return s
    }

    private func readArg() -> String {
        skipSpace()
        if let q = current, q == "\"" || q == "'" {
            return readStringLiteralOrRaw()
        }
        var s = ""
        while let c = current, c != ")" && c != "," {
            s.append(c); pos += 1
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func readKeyword() -> String {
        skipSpace()
        var s = ""
        // 允许 && ||
        if current == "&", peek() == "&" { pos += 2; return "&&" }
        if current == "|", peek() == "|" { pos += 2; return "or" }
        if current == "|" { pos += 1; return "|" }
        if current == "@" {
            pos += 1
            var name = ""
            while let c = current, c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" {
                name.append(c); pos += 1
            }
            return "@" + name
        }
        while let c = current, c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" {
            s.append(c); pos += 1
        }
        return s.lowercased()
    }
}

// MARK: - 求值器

struct XPathEvaluator {

    static func query(_ expression: String, in root: Element) -> [XNode] {
        let branches = XPathParser.parse(expression)
        var out: [XNode] = []
        for steps in branches {
            let nodes = evaluate(steps, context: [.element(root)])
            out.append(contentsOf: nodes)
        }
        // 去重（同一节点可能出现多次）
        var seen = Set<String>()
        var uniq: [XNode] = []
        for n in out {
            let key = identity(n)
            if seen.insert(key).inserted { uniq.append(n) }
        }
        return uniq
    }

    static func stringValue(_ expression: String, in root: Element) -> String {
        query(expression, in: root).map { $0.stringValue }.joined(separator: "\n")
    }

    private static func identity(_ n: XNode) -> String {
        switch n {
        case .element(let e):
            return "E\(ObjectIdentifier(e).hashValue)"
        case .attribute(let name, _, let owner):
            return "A\(ObjectIdentifier(owner).hashValue)_\(name)"
        case .text(let t):
            return "T\(t.hashValue)"
        }
    }

    static func evaluate(_ steps: [XStep], context: [XNode]) -> [XNode] {
        var current = context
        for step in steps {
            var next: [XNode] = []
            for node in current {
                next.append(contentsOf: apply(step, to: node))
            }
            current = next
            if current.isEmpty { return [] }
        }
        return current
    }

    private static func apply(_ step: XStep, to node: XNode) -> [XNode] {
        // 1) 选轴
        var candidates: [XNode] = []

        switch step.axis {
        case .attribute:
            if case .element(let e) = node {
                let name = {
                    if case .attribute(let n) = step.test { return n }
                    return ""
                }()
                if name.isEmpty {
                    for attr in e.getAttributes()?.asList() ?? [Attribute]() {
                        candidates.append(.attribute(name: attr.getKey(), value: attr.getValue(), owner: e))
                    }
                } else if e.hasAttr(name) {
                    candidates.append(.attribute(name: name, value: e.attr(name), owner: e))
                }
            }
        default:
            if case .attribute(_, _, let owner) = node {
                if step.axis == .parent || step.axis == .ancestor {
                    candidates = [.element(owner)]
                } else {
                    candidates = []
                }
            } else if case .text = node {
                candidates = []
            } else if case .element(let e) = node {
                candidates = select(e, axis: step.axis, test: step.test)
            }
        }

        // 2) 谓词过滤（位置类谓词需要先按位置应用，再过滤其它）
        var result = candidates
        var positionPredicates: [XPredicate] = []
        var normalPredicates: [XPredicate] = []

        for p in step.predicates {
            switch p {
            case .index, .last, .lastOffset, .positionGT, .positionLT, .positionEQ:
                positionPredicates.append(p)
            default:
                normalPredicates.append(p)
            }
        }

        for p in positionPredicates {
            result = applyPosition(p, to: result)
        }
        for p in normalPredicates {
            result = result.filter { nodeMatches($0, predicate: p) }
        }
        return result
    }

    private static func applyPosition(_ p: XPredicate, to nodes: [XNode]) -> [XNode] {
        switch p {
        case .index(let i):
            let idx = i - 1
            guard idx >= 0, idx < nodes.count else { return [] }
            return [nodes[idx]]
        case .last:
            return nodes.isEmpty ? [] : [nodes[nodes.count - 1]]
        case .lastOffset(let off):
            let idx = nodes.count - 1 - off
            guard idx >= 0, idx < nodes.count else { return [] }
            return [nodes[idx]]
        case .positionGT(let n):
            return nodes.enumerated().filter { $0.offset + 1 > n }.map { $0.element }
        case .positionLT(let n):
            return nodes.enumerated().filter { $0.offset + 1 < n }.map { $0.element }
        case .positionEQ(let n):
            return nodes.enumerated().filter { $0.offset + 1 == n }.map { $0.element }
        default:
            return nodes
        }
    }

    private static func select(_ e: Element, axis: XAxis, test: XTest) -> [XNode] {
        var elements: [Element] = []

        switch axis {
        case .child:
            elements = e.children().toArray()
        case .descendant:
            elements = e.getAllElements().toArray().filter { $0 !== e }
        case .descendantOrSelf:
            elements = e.getAllElements().toArray()
        case .selfAxis:
            elements = [e]
        case .parent:
            if let p = e.parent() { elements = [p] }
        case .ancestor:
            var cur = e.parent()
            while let c = cur { elements.append(c); cur = c.parent() }
        case .followingSibling:
            var n = e.nextElementSibling()
            while let x = n { elements.append(x); n = x.nextElementSibling() }
        case .precedingSibling:
            var n = e.previousElementSibling()
            while let x = n { elements.append(x); n = x.previousElementSibling() }
        case .attribute:
            break
        }

        switch test {
        case .name(let n):
            let lower = n.lowercased()
            return elements
                .filter { $0.tagName().lowercased() == lower }
                .map { XNode.element($0) }

        case .anyElement:
            return elements.map { XNode.element($0) }

        case .textNode:
            var texts: [XNode] = []
            // text() 取的是「当前节点的直接文本子节点」，但 //text() 惯例上取所有后代文本
            let sources: [Element] = (axis == .descendant) ? e.getAllElements().toArray() : [e]
            for el in sources {
                for child in el.getChildNodes() {
                    if let tn = child as? TextNode {
                        let s = tn.getWholeText()
                        if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            texts.append(.text(s))
                        }
                    } else if let dn = child as? DataNode {
                        let s = dn.getWholeData()
                        if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            texts.append(.text(s))
                        }
                    }
                }
            }
            return texts

        case .anyNode:
            var out: [XNode] = []
            for el in elements {
                out.append(.element(el))
            }
            if axis == .descendant {
                for el in e.getAllElements().toArray() {
                    for child in el.getChildNodes() where child is TextNode {
                        if let tn = child as? TextNode {
                            let s = tn.getWholeText()
                            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                out.append(.text(s))
                            }
                        }
                    }
                }
            }
            return out

        case .attribute(let name):
            return elements.compactMap { el -> XNode? in
                guard let has = try? el.hasAttr(name), has else { return nil }
                let value = (try? el.attr(name)) ?? ""
                return .attribute(name: name, value: value, owner: el)
            }
        }
    }

    // MARK: 谓词求值

    /// 兼容不同 SwiftSoup 版本：attr/hasAttr 在部分版本上是 throws
    @inline(__always)
    private static func attrValue(_ e: Element, _ key: String) -> String {
        (try? e.attr(key)) ?? ""
    }

    @inline(__always)
    private static func hasAttrValue(_ e: Element, _ key: String) -> Bool {
        guard let v = try? e.hasAttr(key) else { return false }
        return v
    }

    private static func nodeMatches(_ node: XNode, predicate: XPredicate) -> Bool {
        let el = node.elementValue
        let text = node.stringValue

        switch predicate {
        case .attrExists(let a):
            guard let el else { return false }
            return hasAttrValue(el, a)
        case .attrEquals(let a, let v):
            guard let el, hasAttrValue(el, a) else { return false }
            return attrValue(el, a) == v
        case .attrNotEquals(let a, let v):
            guard let el else { return false }
            return !hasAttrValue(el, a) || attrValue(el, a) != v
        case .containsAttr(let a, let v):
            guard let el, hasAttrValue(el, a) else { return false }
            return attrValue(el, a).contains(v)
        case .startsWithAttr(let a, let v):
            guard let el, hasAttrValue(el, a) else { return false }
            return attrValue(el, a).hasPrefix(v)
        case .endsWithAttr(let a, let v):
            guard let el, hasAttrValue(el, a) else { return false }
            return attrValue(el, a).hasSuffix(v)
        case .textEquals(let v):
            return text.trimmingCharacters(in: .whitespacesAndNewlines) == v
        case .textNotEquals(let v):
            return text.trimmingCharacters(in: .whitespacesAndNewlines) != v
        case .containsText(let v):
            return text.contains(v)
        case .startsWithText(let v):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(v)
        case .endsWithText(let v):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(v)
        case .matchesText(let re):
            return text.range(of: re, options: .regularExpression) != nil
        case .matchesAttr(let a, let re):
            guard let el, hasAttrValue(el, a) else { return false }
            return attrValue(el, a).range(of: re, options: .regularExpression) != nil
        case .stringLengthGT(let n):
            return text.count > n
        case .stringLengthLT(let n):
            return text.count < n
        case .not(let inner):
            return !nodeMatches(node, predicate: inner)
        case .and(let a, let b):
            return nodeMatches(node, predicate: a) && nodeMatches(node, predicate: b)
        case .or(let a, let b):
            return nodeMatches(node, predicate: a) || nodeMatches(node, predicate: b)
        case .hasChild(let steps):
            guard let el else { return false }
            let res = evaluate(steps, context: [.element(el)])
            return !res.isEmpty
        default:
            return true
        }
    }
}

// MARK: - SwiftSoup Elements 便利

extension Elements {
    func toArray() -> [Element] {
        var out: [Element] = []
        out.reserveCapacity(size())
        for i in 0..<size() { out.append(get(i)) }
        return out
    }
}
