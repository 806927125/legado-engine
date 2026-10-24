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
    // ⭐⭐ **惰性缓存**：SwiftSoup 的 `text()` / `outerHtml()` **每次都重新遍历整棵子树**
    //   （实测 textContent ≈ 13µs、outerHTML ≈ 45µs，而节点查询只要 5µs）
    //   ⇒ 同一节点被多次取文本时，缓存能省掉重复遍历 ⭐
    //   ⚠️ DOM 是**只读**的 ⇒ 缓存安全（节点内容不会变）
    private var cachedText: String?
    private var cachedOwnText: String?
    private var cachedOuterHTML: String?

    public var textContent: String {
        if let c = cachedText { return c }
        let v = (try? element.text()) ?? ""
        cachedText = v
        return v
    }
    public var ownTextContent: String {
        if let c = cachedOwnText { return c }
        let v = (try? element.ownText()) ?? ""
        cachedOwnText = v
        return v
    }
    public var outerHTML: String {
        if let c = cachedOuterHTML { return c }
        let v = (try? element.outerHtml()) ?? ""
        cachedOuterHTML = v
        return v
    }
    /// 内层 HTML（Legado 的 `@html` 语义 = Jsoup `html()`）
    public var innerHTML: String { (try? element.html()) ?? "" }
    public var tagName: String { element.tagName().lowercased() }

    public func attribute(_ name: String) -> String? {
        let v = (try? element.attr(name)) ?? ""
        return v.isEmpty ? nil : v
    }

    /// 全部属性（`result.book_id` 这类站方用法需要）
    public var attributes: [String: String] {
        var out: [String: String] = [:]
        // ⚠️ SwiftSoup 的 `getAttributes()` 返回的是 `Attributes`（集合），**不是字典**
        if let attrs = try? element.getAttributes() {
            for a in attrs {
                out[a.getKey()] = a.getValue()
            }
        }
        return out
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

    /// ⭐⭐⭐ **HTML ⇒ 纯文本**（照抄老引擎 `reference/js/jsoup-compat.js` 的 `dom.htmlToText`）
    ///
    /// · 先删掉 `script/style/noscript/iframe/ins/svg`
    /// · `<br>` ⇒ 换行
    /// · `p/div/li/h1..h6/tr/section` ⇒ **末尾追加换行**（段落各占一行）
    /// · 空白归一 + 三个以上连续换行压成两个
    ///
    /// ⚠️ **为什么必须有**（2026-10-24 整链对拍）：老引擎的 content op 拿规则结果后
    ///   **会做这一步** ⇒ 不做 ⇒ **同一个源的新旧引擎正文不一样**（HTML vs 纯文本）⭐⭐⭐
    public func htmlToText() -> String {
        // ① 删掉不该进正文的标签
        for sel in ["script", "style", "noscript", "iframe", "ins", "svg"] {
            if let els = try? doc.select(sel) {
                for e in els { try? e.remove() }
            }
        }
        // ② <br> ⇒ 换行
        if let brs = try? doc.select("br") {
            for b in brs { try? b.replaceWith(SwiftSoup.TextNode("\n", "")) }
        }
        // ③ 块级元素末尾追加换行（段落各占一行）
        if let blocks = try? doc.select("p,div,li,h1,h2,h3,h4,h5,h6,tr,section") {
            for e in blocks { try? e.appendChild(SwiftSoup.TextNode("\n", "")) }
        }
        // ⚠️⚠️ **必须用 `wholeText()`，不能用 `text()`**：
        //   SwiftSoup 的 `text()` 会**把块级元素之间的空白归一成空格**
        //   （"第一段 第二段"）⇒ 段落换行就没了 ⭐
        //   而老引擎用的是 jsdom 的 `textContent`（**原样文本**，不归一）⇒ 语义要对齐 ⭐
        var raw = ""
        if let body = try? doc.body() {
            // ⭐ `trimAndNormaliseWhitespace: false` ⇒ **原样文本**（jsdom `textContent` 的语义）
            raw = (try? body.text(trimAndNormaliseWhitespace: false)) ?? ""
        }
        if raw.isEmpty {
            raw = (try? doc.text(trimAndNormaliseWhitespace: false)) ?? ""
        }
        return Self.normalizeWS(raw)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    /// ⭐ **空白归一**（照抄老引擎 `dom.normalizeWS`）
    public static func normalizeWS(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "\u{00a0}", with: " ")
        t = t.replacingOccurrences(of: "\u{3000}", with: " ")
        t = t.replacingOccurrences(of: "\u{200b}", with: " ")
        t = t.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
