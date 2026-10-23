import Foundation
import LegadoCore

/// ⭐⭐ **DOM 缓存** —— **同一个页面只解析一次**。
///
/// ⭐ **为什么需要**（实测）：`SwiftSoupDocument` 解析一个 15KB 页面要 **~20 ms**
///   ⇒ 而「详情页 + 目录页」常常是**同一个 URL**（站方 `tocUrl` 为空 ⇒ 目录回落到详情页）
///   ⇒ 以前**同一个 HTML 解析两次** ⇒ 白白多花 20ms。
///
/// ⭐ **为什么安全**：
/// - `DOMNode` 是**只读**的（SwiftSoupNode 是 class）⇒ 复用无副作用
/// - 缓存挂在 **`SourceEngine` 实例**上 ⇒ **每源一个** ⇒ 天然隔离
///
/// ⚠️ **换书源时要 `clear()`**（宿主复用同一个 engine 实例切源时）。
public final class DOMCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: DOMNode] = [:]
    private var order: [String] = []
    /// 容量上限（LRU ⇒ 超出就丢最旧的）
    public let capacity: Int

    public init(capacity: Int = 32) { self.capacity = max(1, capacity) }

    public func node(for key: String) -> DOMNode? {
        lock.lock(); defer { lock.unlock() }
        guard let n = store[key] else { return nil }
        // 提到队尾（LRU）
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
        return n
    }

    public func put(_ node: DOMNode, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if store[key] == nil { order.append(key) }
        store[key] = node
        while order.count > capacity {
            let old = order.removeFirst()
            store.removeValue(forKey: old)
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll(); order.removeAll()
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }
}
