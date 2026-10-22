import Foundation
import SwiftSoup

/// **SwiftSoup 后端** —— 生产用 DOM 实现。
///
/// ⭐ 选 SwiftSoup 的理由：
/// - HTML5 容错（未闭合标签、`<p>` 自动闭合、表格 foster parenting）—— **自研是无底洞**
/// - 选择器语义**和 Jsoup 一致**（实测：自身包含、并列 class、`:contains`、`:nth-child` 都对）
/// - 纯 Swift ⇒ 同一个二进制能在 Linux 沙盒真编真跑
///
/// ⚠️ SwiftSoup **没有** `:textEquals`（Legado 特有语义）⇒ 自己用后置过滤补（见 `PseudoFilter`）。
public final class SwiftSoupNode: DOMNode {
    private let element: SwiftSoup.Element
    private let identifier: String
    private var counter: UInt64 = 0

    init(_ element: SwiftSoup.Element, id: String? = nil) {
        self.element = element
        if let id { self.identifier = id }
        else {
            SwiftSoupNode.counter &+= 1
            self.identifier = "ss-\(SwiftSoupNode.counter)"
        }
    }

    private static var counter: UInt64 = 0

    public var domID: String { identifier }
    public var textContent: String { (try? element.text()) ?? "" }
    public var ownTextContent: String { (try? element.ownText()) ?? "" }
    public var outerHTML: String { (try? element.outerHtml()) ?? "" }
    /// 内层 HTML（Legado 的 `@html` 语义 = Jsoup `html()`）
    public var innerHTML: String { (try? element.html()) ?? "" }
    public var tagName: String { element.tagName().lowercased() }

    public func attribute(_ name: String) -> String? {
        let v = (try? element.attr(name)) ?? ""
        return v.isEmpty ? nil : v
    }

    public func queryAll(_ css: String) -> [DOMNode] {
        guard let els = try? element.select(css) else { return [] }
        return els.map { SwiftSoupNode($0) as DOMNode }
    }

    /// 所有后代（不含自身）
    public func descendants() -> [DOMNode] {
        guard let els = try? element.getAllElements() else { return [] }
        return els.map { SwiftSoupNode($0) as DOMNode }
    }

    /// 直接子元素
    public func children() -> [DOMNode] {
        let els = element.children()
        return els.map { SwiftSoupNode($0) as DOMNode }
    }

    /// 直接子文本节点（XPath `text()` 语义）
    public func directText() -> String {
        element.textNodes().map { $0.text() }.joined()
    }

    /// ⭐ SwiftSoup 没有 `Element.is(_:)` ⇒ 用 `select`（**含自身**）+ 身份比较
    public func matchesCSS(_ css: String) -> Bool {
        guard let found = try? element.select(css) else { return false }
        return found.contains { $0 === element }
    }
}

/// SwiftSoup 文档 —— 页面级基准。
public final class SwiftSoupDocument: DOMDocument {
    private let doc: SwiftSoup.Document
    public let baseURL: String

    public init(html: String, baseURL: String = "") throws {
        self.doc = try SwiftSoup.parse(html, baseURL)
        self.baseURL = baseURL
    }

    public var document: DOMNode { SwiftSoupNode(doc) }

    /// 相对地址绝对化（Jsoup `absolutize` 语义）
    public func absolutize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if path.hasPrefix("http://") || path.hasPrefix("https://")
            || path.hasPrefix("//") || path.hasPrefix("file://") { return path }
        guard let base = URL(string: baseURL), !baseURL.isEmpty else { return path }
        if path.hasPrefix("/") {
            // 取到「scheme://host」部分
            var s = baseURL
            if let range = s.range(of: "://") {
                s = String(s[s.startIndex...range.upperBound])
                if let slash = s.firstIndex(of: "/") {
                    s = String(s[s.startIndex..<slash])
                }
            } else {
                s = ""
            }
            return s + path
        }
        if let resolved = URL(string: path, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }
        return path
    }
}
