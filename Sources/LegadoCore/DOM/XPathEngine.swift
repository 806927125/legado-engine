import Foundation

/// **XPath 子集求值器**（自研）。
///
/// 规格：`docs/legado-semantics.md` §S-DOM-07。
///
/// ⭐ **子集范围是照 125 源的真实用法定的，不是拍脑袋**：
///
/// ```
/// //*[@property="og:image"]/@content          通配 + 属性谓词 + 取属性
/// //ul[contains(@class,'vodlist')]/li          contains() + 子路径
/// //p[@class='mb-1 text-muted']/a/text()      属性谓词（class 多值）+ text()
/// //div[@class='list-group']/div[@class='x']   链式谓词
/// //div[@class='box_info']/table/tbody/tr[1]/td/div/p[1]/a[1]/text()   多级 + 数字索引
/// //h5/a/@href                                取属性
/// //h5/a//text()                               后代 text()
/// ```
///
/// ⇒ 支持的语法：
/// | 语法 | 语义 |
/// |---|---|
/// | `//tag` / `//*` | 所有后代里的元素 |
/// | `/tag` | 直接子元素 |
/// | `tag[@attr='v']` | 属性**完全相等**（⭐ 标准 XPath 语义，不是「包含」） |
/// | `tag[contains(@attr,'v')]` | 属性包含 |
/// | `tag[n]` | 第 n 个（**1-based**，XPath 语义） |
/// | `tag[p1][p2]` | 多个谓词（AND） |
/// | `/text()` | **直接子文本节点**（不是完整文本） |
/// | `/@attr` | 属性值 |
///
/// ⚠️ **两个容易搞错的点**：
/// 1. `@class='a b'` 是**完全相等**（标准 XPath）⇒ HTML 的多值 class **匹配不上**
///    ⇒ 站方要「按 class 包含」得显式写 `contains(@class,'a')`
///    ⇒ 这跟 Legado（jsoup `selectXPath`）和轻阅（`document.evaluate`）**都一致**
/// 2. `text()` 取的是**直接子文本节点**，不是元素的完整文本
///    ⇒ `<a><span>x</span></a>` 的 `text()` 是**空串**
public enum XPathEngine {

    // MARK: - 语法

    /// 一个路径步骤
    public indirect enum Step: Equatable {
        /// 元素名测试（`tag` 或 `*`）
        case name(String)
        /// 直接子元素（`/`）
        case child(String)
        /// 所有后代（`//`）
        case descendant(String)
        /// 谓词
        case predicate(Predicate)
        /// 取直接子文本节点
        case text
        /// 取属性
        case attribute(String)
    }

    /// 谓词
    public enum Predicate: Equatable {
        /// `@attr='v'`（完全相等）
        case attributeEquals(attr: String, value: String)
        /// `contains(@attr,'v')`
        case attributeContains(attr: String, value: String)
        /// 位置谓词 `n`（**1-based**）
        case position(Int)
    }

    /// ⭐ 解析 XPath 表达式 ⇒ 步骤序列。
    ///
    /// **解析失败必须报错**（不许静默返回空）—— 静默空是「静默失效」的源头。
    public static func parse(_ expr: String) -> [Step]? {
        var s = expr.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // 只剥 `xpath:`（跟轻阅 `evalXPath` 的 `replace(/^xpath:/i,'')` 一致）
        // ⚠️ **不剥 `//xpath:`** —— 那是 XPath 1.0 的命名空间语法，jsoup / document.evaluate 都不认
        if s.lowercased().hasPrefix("xpath:") { s = String(s.dropFirst(6)) }

        var steps: [Step] = []
        var i = s.startIndex

        while i < s.endIndex {
            // ① 路径分隔
            var descendant = false
            if s[i...].hasPrefix("//") {
                descendant = true
                i = s.index(i, offsetBy: 2)
            } else if s[i] == "/" {
                i = s.index(after: i)
            }

            // ② 元素名测试
            var name = ""
            while i < s.endIndex, isNameChar(s[i]) { name.append(s[i]); i = s.index(after: i) }
            // 支持 `*`
            if name == "*" && i < s.endIndex, s[i] == "*" { name = "*" }
            if name.isEmpty {
                // 没有名字但有谓词（`//*[@x=1]` 的 `*` 被上面吃掉了）
                guard !descendant || steps.isEmpty == false else { return nil }
                if name.isEmpty { return nil }
            }
            if !name.isEmpty {
                steps.append(descendant ? .descendant(name) : .child(name))
            } else if !descendant {
                return nil
            }

            // ③ 谓词（紧跟在本步后面，可以有多个）
            while i < s.endIndex, s[i] == "[" {
                guard let close = s[i...].firstIndex(of: "]") else { return nil }
                let inner = String(s[s.index(after: i)..<close])
                i = s.index(after: close)
                guard let p = parsePredicate(inner) else { return nil }
                steps.append(.predicate(p))
            }

            // ④ 后缀：`/text()` 或 `/@attr`
            if i < s.endIndex, s[i] == "/" {
                let afterSlash = s.index(after: i)
                if afterSlash < s.endIndex, s[afterSlash] == "@" {
                    var j = s.index(after: afterSlash)
                    var attr = ""
                    while j < s.endIndex, isNameChar(s[j]) || s[j] == ":" || s[j] == "-" {
                        attr.append(s[j]); j = s.index(after: j)
                    }
                    guard !attr.isEmpty else { return nil }
                    steps.append(.attribute(attr))
                    i = j
                    continue
                }
                if afterSlash < s.endIndex, s[afterSlash...].hasPrefix("text()") {
                    steps.append(.text)
                    i = s.index(afterSlash, offsetBy: 6)
                    continue
                }
            }
        }
        return steps.isEmpty ? nil : steps
    }

    private static func parsePredicate(_ raw: String) -> Predicate? {
        let inner = raw.trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return nil }
        // 位置谓词 `1` / `2`
        if let n = Int(inner) { return .position(n) }
        // `@attr='v'` / `@attr="v"`
        if inner.hasPrefix("@") {
            guard let eq = firstEquals(in: inner) else { return nil }
            let attr = String(inner[inner.index(after: inner.startIndex)..<eq]).trimmingCharacters(in: .whitespaces)
            let value = unquote(String(inner[inner.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            guard !attr.isEmpty else { return nil }
            return .attributeEquals(attr: attr, value: value)
        }
        // `contains(@attr,'v')`
        let lower = inner.lowercased()
        if lower.hasPrefix("contains(") && inner.hasSuffix(")") {
            let body = String(inner.dropFirst(9).dropLast())
            guard let comma = body.firstIndex(of: ",") else { return nil }
            let attr = String(body[body.startIndex..<comma]).trimmingCharacters(in: .whitespaces)
            let value = unquote(String(body[body.index(after: comma)...]).trimmingCharacters(in: .whitespaces))
            guard attr.hasPrefix("@") else { return nil }
            return .attributeContains(attr: String(attr.dropFirst()), value: value)
        }
        return nil
    }

    private static func firstEquals(in s: String) -> String.Index? {
        var quote: Character? = nil
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "=" {
                return i
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2 {
            let f = t.first!, l = t.last!
            if (f == "'" && l == "'") || (f == "\"" && l == "\"") {
                return String(t.dropFirst().dropLast())
            }
        }
        return t
    }

    private static func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == ":" || c == "*"
    }

    // MARK: - 求值

    /// 求值 ⇒ 结果列表（元素节点 / 字符串，取决于路径末尾）。
    public static func select(_ root: DOMNode, _ expr: String) -> [RuleValue]? {
        guard let steps = parse(expr) else { return nil }
        var current: [DOMNode] = [root]

        for step in steps {
            switch step {
            case .descendant(let name):
                var next: [DOMNode] = []
                for n in current {
                    for d in allDescendants(n) where matchesName(d, name) { next.append(d) }
                }
                current = next

            case .child(let name):
                var next: [DOMNode] = []
                for n in current {
                    for c in n.children() where matchesName(c, name) { next.append(c) }
                }
                current = next

            case .name(let name):
                // 绝对路径的第一步：`/html` ⇒ 从根的子元素里找
                var next: [DOMNode] = []
                for n in current {
                    if matchesName(n, name) { next.append(n) }
                }
                current = next

            case .predicate(let p):
                current = applyPredicate(p, to: current)

            case .text:
                // text() ⇒ 直接子文本节点（不是完整文本）
                current = current.map { node in
                    DOMTextNode(text: node.directText(), owner: node)
                }

            case .attribute(let attr):
                current = current.map { node in
                    DOMTextNode(text: node.attribute(attr) ?? "", owner: node)
                }
            }
        }
        return current.map { RuleValue.node(DOMNodeRef($0)) }
    }

    private static func applyPredicate(_ p: Predicate, to nodes: [DOMNode]) -> [DOMNode] {
        switch p {
        case .position(let n):
            let idx = n - 1          // ⭐ XPath 是 **1-based**
            guard idx >= 0, idx < nodes.count else { return [] }
            return [nodes[idx]]
        case .attributeEquals(let attr, let value):
            return nodes.filter { ($0.attribute(attr) ?? "") == value }
        case .attributeContains(let attr, let value):
            return nodes.filter { ($0.attribute(attr) ?? "").contains(value) }
        }
    }

    private static func matchesName(_ node: DOMNode, _ name: String) -> Bool {
        if name == "*" { return true }
        return node.tagName.lowercased() == name.lowercased()
    }

    private static func allDescendants(_ node: DOMNode) -> [DOMNode] {
        // ⭐⭐⭐⭐⭐ **文档顺序**（XPath 1.0 的语义：结果集按文档顺序）
        //
        // ⚠️⚠️⚠️ **原来的实现是【倒序】**（栈 + `popLast()` ⇒ 兄弟节点反着来）
        //   ⇒ `//li` 拿到的是「三、二、一」⇒ **跟标准 XPath（`document.evaluate`）不一致** ⭐⭐⭐
        //   ⇒ 老引擎（jsdom 的 `document.evaluate`）是**正序** ⇒ **这是新引擎的回归** ⭐⭐⭐
        //   ⇒ 后果：站方规则里「取第一条 / 取全部」的顺序全反 ⇒ 目录章节倒序 ⭐⭐⭐
        var out: [DOMNode] = []
        func walk(_ n: DOMNode) {
            for c in n.children() {
                out.append(c)
                walk(c)
            }
        }
        walk(node)
        return out
    }
}

/// XPath `text()` / `@attr` 的结果 —— **不是元素，是个字符串**。
final class DOMTextNode: DOMNode {
    let domID: String
    let textContent: String
    let ownTextContent: String
    let outerHTML: String
    let tagName: String
    /// 来自哪个元素（便于诊断）
    let owner: DOMNode

    init(text: String, owner: DOMNode) {
        self.textContent = text
        self.ownTextContent = text
        self.outerHTML = text
        self.tagName = "#text"
        self.owner = owner
        self.domID = "text-" + owner.domID + "-" + String(text.hashValue)
    }

    func attribute(_ name: String) -> String? { nil }
    func queryAll(_ css: String) -> [DOMNode] { [] }
    func matchesCSS(_ css: String) -> Bool { false }
    func descendants() -> [DOMNode] { [] }
    func children() -> [DOMNode] { [] }
    func directText() -> String { textContent }
}
