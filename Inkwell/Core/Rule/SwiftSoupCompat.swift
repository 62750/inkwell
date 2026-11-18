import Foundation
import SwiftSoup

// MARK: - SwiftSoup 兼容层
//
// SwiftSoup 不同版本对 attr / hasAttr / classNames / tagName / id / getAllElements
// 的签名不一致：有的版本声明为 throws。
//
// 书源解析里这些访问是「读属性」级别的操作，抛异常没有意义，
// 所以统一在这里吸收掉，调用点一律用下面这些函数，跨版本都能编。
//
// ⚠️ 本文件内部必须直接调用 SwiftSoup 原始 API，不能调用自身，
//    否则会无限递归。批量替换脚本已把本文件排除。

@inline(__always)
func attrOf(_ e: Element, _ key: String) -> String {
    (try? e.attr(key)) ?? ""
}

@inline(__always)
func attrOf(_ e: Element?, _ key: String) -> String {
    guard let e else { return "" }
    return (try? e.attr(key)) ?? ""
}

@inline(__always)
func hasAttrOf(_ e: Element, _ key: String) -> Bool {
    guard let v = try? e.hasAttr(key) else { return false }
    return v
}

@inline(__always)
func hasAttrOf(_ e: Element?, _ key: String) -> Bool {
    guard let e else { return false }
    return (try? e.hasAttr(key)) ?? false
}

@inline(__always)
func classesOf(_ e: Element) -> [String] {
    guard let s = try? e.classNames() else { return [] }
    return Array(s)
}

@inline(__always)
func classesOf(_ e: Element?) -> [String] {
    guard let e else { return [] }
    return classesOf(e)
}

/// 排序后的 class 列表，方便直接拼选择器
@inline(__always)
func sortedClassesOf(_ e: Element) -> [String] {
    classesOf(e).filter { !$0.isEmpty }.sorted()
}

@inline(__always)
func tagOf(_ e: Element) -> String {
    (try? e.tagName()) ?? ""
}

@inline(__always)
func tagOf(_ e: Element?) -> String {
    guard let e else { return "" }
    return (try? e.tagName()) ?? ""
}

@inline(__always)
func idOf(_ e: Element) -> String {
    (try? e.id()) ?? ""
}

@inline(__always)
func idOf(_ e: Element?) -> String {
    guard let e else { return "" }
    return (try? e.id()) ?? ""
}

@inline(__always)
func allElementsOf(_ e: Element) -> [Element] {
    guard let els = try? e.getAllElements() else { return [] }
    return els.toArray()
}

@inline(__always)
func nextSiblingOf(_ e: Element) -> Element? {
    try? e.nextElementSibling()
}

@inline(__always)
func prevSiblingOf(_ e: Element) -> Element? {
    try? e.previousElementSibling()
}

/// 取文本（去首尾空白）
@inline(__always)
func textOf(_ e: Element) -> String {
    ((try? e.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

@inline(__always)
func textOf(_ e: Element?) -> String {
    guard let e else { return "" }
    return ((try? e.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

@inline(__always)
func htmlOf(_ e: Element) -> String {
    (try? e.html()) ?? ""
}

@inline(__always)
func outerHTMLOf(_ e: Element) -> String {
    (try? e.outerHtml()) ?? ""
}

/// 安全 select
@inline(__always)
func selectOf(_ e: Element, _ css: String) -> [Element] {
    guard let els = try? e.select(css) else { return [] }
    return els.toArray()
}
