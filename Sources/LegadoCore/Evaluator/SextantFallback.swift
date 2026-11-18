import Foundation
import Hitch
import Sextant

/// ⭐⭐⭐⭐⭐ **Sextant 兜底**（MIT · vendored）—— 标准 JSONPath + **完整**过滤表达式
///
/// ⭐ 为什么要它：
///   栖阅 / 柴阅的引擎用的就是 **KittyMac/Sextant**（MIT）⇒ 它们的 JSONPath 语义
///   （尤其 `[?(@.a=='b')]` 这类**过滤表达式**）是**完整版**。
///   而本引擎手写的 `JSONFilter` 是**子集**（照 125 源真实用法整理）⇒
///   站方写了子集之外的表达式 ⇒ **整条路径作废** ⇒ 字段全空 ⇒ 症状离根因极远。
///   ⇒ 兜底：**手写实现优先（行为不变）⇒ 解析不了/结果为空时才用 Sextant**。
///
/// ⚠️ **为什么这样兜底是安全的**：
///   · 手写实现**能解析** ⇒ 一律走手写 ⇒ **现有行为零变化** ⭐⭐⭐
///   · 手写实现**解析不了** ⇒ 之前返回 nil（= 空）⇒ 现在最多返回「有值」
///     ⇒ **严格优于之前**（空 → 有值），不存在「把对的改错」的风险 ⭐⭐⭐
///   · 手写实现**能解析但结果为空**（子集里的表达式算不出）⇒ 只有路径里**带过滤表达式**
///     时才用 Sextant 重算 ⇒ 空 → 有值 ⇒ 同上 ⭐⭐⭐
///
/// ⚠️ 许可：Sextant / Hitch / Spanker 全是 MIT ⇒ 见 `Vendor/SextantKit/VENDOR.md`。
public enum SextantFallback {

    /// ⭐⭐⭐ **用 Sextant 求值一条路径**（`nil` = Sextant 也认不了）
    public static func select(_ root: JSONValue, _ path: String) -> [JSONValue]? {
        guard let json = jsonText(root) else { return nil }
        guard let hits = json.query(values: Hitch(path)) else { return nil }
        return hits.compactMap { $0 }.map { JSONValue.from($0) }
    }

    /// ⭐⭐⭐ **路径是否合法**（`nil` = 合法；非 nil = 错误原因）⇒ 给诊断用
    /// （Sextant 的 `String` 扩展有 `query(validate:)` 重载 ⇒ 直接用字符串版即可）
    public static func validate(_ path: String) -> String? {
        path.query(validate: path)
    }

    // MARK: - 内部

    /// JSONValue ⇒ JSON 文本（Sextant 的入口吃 JSON 字符串）
    private static func jsonText(_ value: JSONValue) -> String? {
        let any = value.foundationValue
        guard let data = try? JSONSerialization.data(withJSONObject: any,
                                                     options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
