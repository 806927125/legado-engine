import Foundation

/// **规则 AST 缓存**。
///
/// 规格：`docs/legado-semantics.md` §S-EVAL-11。
///
/// ⭐ **为什么要缓存**：
/// - 每次 `evalOne` 都要把规则串解析成 AST —— 解析是**纯 CPU 的字符串扫描**
/// - 同一个书源的同一条规则会被**反复求值**（列表里每个条目都跑一遍字段规则）
/// - 125 源里一个 `bookList` 可能匹配几百项 ⇒ 同一批字段规则要跑几百遍
/// ⇒ 解析一次、复用 N 次，是**纯赚**的优化。
///
/// ⚠️ **两条纪律**：
/// 1. **只缓存「整条规则」的 AST**，**递归切分出来的子段不进缓存**
///    ⇒ 否则缓存里全是碎片，命中率低而且 key 爆炸
/// 2. **缓存不能改变行为** ⇒ 命中缓存的 AST 必须与现算的**逐字相同**
///    ⇒ 有门禁专门断言这一点（`testCachedASTMatchesFreshAST`）
public final class RuleCache: @unchecked Sendable {

    /// 缓存键：**规则原文 + 响应是不是 JSON**（两者都影响模式判定，§S-CLS-08）
    public struct Key: Hashable, Sendable {
        public let rule: String
        public let isJSON: Bool
        public init(rule: String, isJSON: Bool) {
            self.rule = rule
            self.isJSON = isJSON
        }
    }

    /// 上限 —— 防止规则种类过多时内存爆掉。
    /// ⚠️ 书源的几百条规则 × 几个源 ⇒ 512 条足够覆盖「一个会话里的所有活跃规则」
    public static let defaultCapacity = 512

    private var storage: [Key: RuleNode] = [:]
    private var order: [Key] = []
    private let lock = NSLock()
    private let capacity: Int

    private var _hits = 0
    private var _misses = 0

    public init(capacity: Int = RuleCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// 取（或建）缓存项。
    ///
    /// - Parameter build: 未命中时的构造闭包（**只会被调用一次**）
    /// ⭐ **只查命中**（**不创建闭包**）—— 命中路径零堆分配。
    ///
    /// ⚠️ 以前 `node(for:build:)` 的调用点**每次都创建逃逸闭包**（堆分配）
    ///   ⇒ 缓存命中也要付一次闭包分配的钱 ⇒ 命中路径 35µs 里有相当一部分在这
    public func cached(for key: Key) -> RuleNode? {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = storage[key] else { return nil }
        _hits += 1
        return hit
    }

    public func node(for key: Key, build: () -> RuleNode) -> RuleNode {
        lock.lock()
        defer { lock.unlock() }

        if let hit = storage[key] {
            _hits += 1
            return hit
        }
        _misses += 1
        let value = build()
        storage[key] = value
        order.append(key)
        // ⚠️ 超上限 ⇒ 淘汰**最老**的（简单 FIFO，够用且可预测）
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
        return value
    }

    /// 统计（命中率）—— 门禁和诊断都用它。
    public var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(hits: _hits, misses: _misses, count: storage.count)
    }

    public struct Stats: Sendable, Equatable {
        /// ⭐ 空统计（没有缓存时用）
        public static let empty = Stats(hits: 0, misses: 0, count: 0)
        public let hits: Int
        public let misses: Int
        public let count: Int
        /// 命中率（0~1）；没有任何请求时算 0
        public var hitRate: Double {
            let total = hits + misses
            return total == 0 ? 0 : Double(hits) / Double(total)
        }
    }

    /// 清空（换书源时该清 —— 不同源的规则可能同名但含义不同）
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        order.removeAll()
        _hits = 0
        _misses = 0
    }
}
