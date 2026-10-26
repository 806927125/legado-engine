import Foundation

/// ⭐⭐ **源级变量的共享存储**（跨规则、跨 JS 调用可写）。
///
/// ⚠️ **为什么需要它**：`EvalContext.vars` 是 `[String: String]`（**值类型**）
/// ⇒ 在 struct 里改它**传不出去** ⇒ 站方 JS 的 `java.put(...)` 写的变量
/// 后续规则**读不到** ⇒ 「变量」名存实亡。
/// ⇒ 这里用一个 **class**（引用语义）⇒ 写入能穿透到所有持有者 ⭐
///
/// ⚠️ 引擎**全同步** ⇒ 但 JS 里可能多次往返 ⇒ 仍加锁（廉价）。
public final class VarBox: @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(_ initial: [String: String] = [:]) { self.storage = initial }

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    /// ⭐⭐⭐ **单个值的上限**（2026-10-26 jetsam 4.2GB 实证）
    ///
    /// ⚠️⚠️⚠️ **为什么必须有**：站方会把大块数据缓存进源变量
    ///   （聚合源把几百个分类的载荷 base64 塞进一个变量）⇒ 值涨到 **GB 级**
    ///   ⇒ 而宿主每次 op 都要把它**序列化回传**（字典 + Data + String ⇒ **好几份拷贝**）
    ///   ⇒ ⇒ **一个 GB 级变量能撑到几个 GB** ⇒ jetsam 秒杀（现象 = 闪退 + 没有 .ips）⭐⭐⭐
    ///   ⇒ 而且 JSC 的 **VM 会抓着跑过脚本的 context** ⇒ `invalidate()` 放不掉 ⇒ **「清会话后内存不降」** ⭐⭐⭐
    /// ⇒ ⇒ **宿主必须给变量值封顶**（站方缓存丢了只是多抓一次 ⇒ 不会崩）⭐
    public static let maxValueBytes = 2 * 1024 * 1024

    public func set(_ key: String, _ value: String) {
        // ⭐ 超大值 ⇒ **截断**（保留前缀，够站方判断「有缓存」；但不再无限涨）⭐
        let stored: String
        if value.utf8.count > Self.maxValueBytes {
            stored = String(value.prefix(Self.maxValueBytes / 4))
        } else {
            stored = value
        }
        lock.lock(); defer { lock.unlock() }
        storage[key] = stored
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    /// 全部（给宿主用：展示书源变量）
    public var all: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
