import Foundation

/// **后置伪类** —— SwiftSoup 不支持的那些，得查完再过滤。
///
/// 规格：`docs/legado-semantics.md` §S-SEL-01（`text.` = 文本**完全相等**）。
///
/// ⭐ 为什么是「后置」而不是「翻译成 CSS」：
/// `:textEquals(X)` 要比的是**元素的完整文本**（含所有后代），
/// 而 CSS 选择器层面表达不了 ⇒ 只能先按 CSS 查出候选，再逐个精确比对。
public enum PseudoFilter: Sendable, Equatable {
    /// 文本**完全相等**（Legado 的 `text.` 前缀 / `:textEquals`）
    /// ⭐ 这是 Legado 特有语义，SwiftSoup 没有 ⇒ 必须自己实现
    case textEquals(String)
    /// 自身文本包含
    case containsOwn(String)
    /// 完整文本包含
    case contains(String)
    /// 自身文本匹配正则
    case matchesOwn(String)
    /// 完整文本匹配正则
    case matches(String)
    /// 含文本的后代
    case hasText(String)

    /// 判断节点是否通过这个过滤
    public func matches(_ node: DOMNode) -> Bool {
        switch self {
        case .textEquals(let s):
            return node.textContent == s
        case .containsOwn(let s):
            return node.ownTextContent.contains(s)
        case .contains(let s):
            return node.textContent.contains(s)
        case .matchesOwn(let s):
            return regexMatch(s, node.ownTextContent)
        case .matches(let s):
            return regexMatch(s, node.textContent)
        case .hasText(let s):
            return node.textContent.contains(s)
        }
    }

    /// 渲染回伪类字符串（用于跟参考实现做**中间表示**层面的对拍）
    public var cssText: String {
        switch self {
        case .textEquals(let s):   return ":textEquals(\(s))"
        case .containsOwn(let s):  return ":containsOwn(\(s))"
        case .contains(let s):     return ":contains(\(s))"
        case .matchesOwn(let s):   return ":matchesOwn(\(s))"
        case .matches(let s):      return ":matches(\(s))"
        case .hasText(let s):      return ":hasText(\(s))"
        }
    }

    private func regexMatch(_ pattern: String, _ text: String) -> Bool {
        // ⭐⭐ **走正则缓存**（别每次重新编译！）
        guard let re = RegexCache.shared.regex(pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }
}

/// ⭐⭐⭐ **正则缓存**（pattern → 编译好的 `NSRegularExpression`）
///
/// ⚠️⚠️⚠️ **`NSRegularExpression(pattern:)` 每次调用都会【重新编译】**
///   ⇒ 编译一次要 **~0.15 ms**（而实际匹配只要几微秒）
///   ⇒ 实测：「一次相对求值」0.25 ms，而「实际工作」（查一次选择器）只要 0.005 ms
///   ⇒ **95% 的时间花在重新编译正则上** ⇒ 缓存后省 50 倍 ⭐
///
/// ⚠️ `NSRegularExpression` 是**不可变**的 ⇒ 多线程共用一个实例是安全的 ✔
public final class RegexCache: @unchecked Sendable {
    public static let shared = RegexCache()

    private let lock = NSLock()
    private var store: [String: NSRegularExpression] = [:]
    /// 容量上限（站方规则的伪类种类有限 ⇒ 几百条足够）
    private let capacity: Int

    public init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    public func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        if let re = store[pattern] { return re }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        if store.count >= capacity { store.removeAll() }   // 简单限容
        store[pattern] = re
        return re
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }
    public func clear() { lock.lock(); defer { lock.unlock() }; store.removeAll() }
}

/// 一个「CSS + 后置过滤」的组合。
public struct SelectorSpec: Sendable, Equatable {
    /// 去掉伪类后的 CSS（交给 CSS 引擎）
    public let css: String
    /// 需要在查询后逐个过滤的条件
    public let filters: [PseudoFilter]

    public init(css: String, filters: [PseudoFilter] = []) {
        self.css = css
        self.filters = filters
    }

    /// ⭐ 归一化形式：CSS + 后置过滤渲染回伪类。
    ///
    /// 用途：**中间表示层面的对拍** —— 参考实现（轻阅）把伪类留在 CSS 串里再摘出来，
    /// 本实现直接摘出来 ⇒ 行为等价但字符串不同 ⇒ 用 `cssLike` 归一化后比对。
    public var cssLike: String {
        (css + filters.map { $0.cssText }.joined()).trimmingCharacters(in: .whitespaces)
    }

    /// 对候选节点集应用后置过滤
    public func apply(_ nodes: [DOMNode]) -> [DOMNode] {
        guard !filters.isEmpty else { return nodes }
        return nodes.filter { n in filters.allSatisfy { $0.matches(n) } }
    }
}
