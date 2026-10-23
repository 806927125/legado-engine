import Foundation
import LegadoCore

/// ⭐ **iOS/macOS 的键值存储**（`UserDefaults`）—— 宿主服务契约 §S-HOST-03 的参考实现。
///
/// ⚠️ 核心层不许碰 `UserDefaults`（纯 Foundation 约束）⇒ 实现放在**宿主层 target**。
///
/// ⭐ **建议用「带书源前缀的 UserDefaults suite」**，不同书源的变量互不串台：
/// ```swift
/// let defaults = UserDefaults(suiteName: "group.com.example.reader")
/// let storage = UserDefaultsStorage(defaults: defaults, prefix: "src.\(sourceUrl).")
/// ```
public final class UserDefaultsStorage: KeyValueStorage, @unchecked Sendable {

    private let defaults: UserDefaults
    /// 键前缀（**强烈建议按书源隔离** ⇒ 不同源的书源变量不串）
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "") {
        self.defaults = defaults
        self.prefix = prefix
    }

    private func realKey(_ key: String) -> String { prefix + key }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: realKey(key))
    }

    public func setString(_ value: String?, forKey key: String) {
        let k = realKey(key)
        if let value {
            defaults.set(value, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
    }

    public func removeValue(forKey key: String) {
        defaults.removeObject(forKey: realKey(key))
    }

    public func allKeys() -> [String] {
        let d = defaults.dictionaryRepresentation()
        return d.keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }
}
