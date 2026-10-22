import Foundation

/// DOM 节点抽象 —— **核心层只认这个协议，不认具体实现**。
///
/// ⭐ 为什么要有协议：
/// 1. 核心层保持**纯 Foundation** ⇒ Linux 沙盒能 `swiftc` 真编真跑 ⇒ 3 秒反馈
/// 2. 具体实现可换：SwiftSoup（生产）/ 自研（可控）/ 测试替身
/// 3. **对拍**时可以拿「SwiftSoup 实现」跟「轻阅的 JS DOM 实现」比
///
/// 语义对齐 Jsoup（`jsoup-compat.js`）：
/// - `queryAll` **包含元素自身**（Jsoup 的 `select()` 语义）⭐ 轻阅注释里明确写过
public protocol DOMNode: AnyObject {
    /// 稳定标识（调试/去重用）
    var domID: String { get }
    /// 完整文本（Jsoup `text()`）
    var textContent: String { get }
    /// 自身文本（Jsoup `ownText()`）
    var ownTextContent: String { get }
    /// 外层 HTML（Jsoup `outerHtml()`）
    var outerHTML: String { get }
    /// 标签名（小写）
    var tagName: String { get }
    /// 属性值（未解实体）
    func attribute(_ name: String) -> String?
    /// 在本节点内按 CSS 选（**含自身**）
    func queryAll(_ css: String) -> [DOMNode]
    /// 本节点是否匹配 CSS
    func matchesCSS(_ css: String) -> Bool
    /// **所有后代**（不含自身）—— 后置伪类过滤时需要「全文档范围」的候选集
    func descendants() -> [DOMNode]
}

/// 节点引用 —— 可跨线程传递的薄包装。
///
/// ⚠️ DOM 节点本身**不是线程安全的**，所以这里用 `@unchecked Sendable`。
/// 引擎是**单线程同步**跑的（见 docs/architecture.md），不构成实际风险。
public final class DOMNodeRef: @unchecked Sendable, Equatable {
    public let node: DOMNode
    public init(_ node: DOMNode) { self.node = node }

    public var id: String { node.domID }
    public var text: String { node.textContent }
    public var ownText: String { node.ownTextContent }
    public var html: String { node.outerHTML }

    /// 相等性按**节点身份**（不是内容）—— 链式求值要去重
    public static func == (lhs: DOMNodeRef, rhs: DOMNodeRef) -> Bool {
        lhs.node.domID == rhs.node.domID
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(node.domID) }
}

/// DOM 文档 —— 求值的**页面级**基准。
public protocol DOMDocument: AnyObject {
    var document: DOMNode { get }
    /// 基准 URL（用于相对地址绝对化）
    var baseURL: String { get }
}
