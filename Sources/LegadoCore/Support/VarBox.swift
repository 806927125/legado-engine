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

    public func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
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
