import Foundation

/// 最小 JSON 值类型（纯 Foundation，无第三方依赖）。
///
/// **为什么自己写而不用 `JSONSerialization`**：
/// 1. `JSONSerialization` 的 `NSNumber` 会把 `true` 和 `1` 混在一起 ⇒ JSONPath 的
///    `===`（严格相等，类型也相同）就没法做 —— 栖阅的 Sextant 明确区分。
/// 2. 规则求值需要**区分整数/浮点**（`1` vs `1.0`），`NSNumber` 也保不住。
/// 3. 沙盒可编译、零依赖。
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// 便捷构造：从任意 Foundation 值转过来（用于把站方 JS 的返回值映射进来）。
    public static func from(_ any: Any?) -> JSONValue {
        switch any {
        case nil, is NSNull:            return .null
        case let b as Bool:            return .bool(b)
        case let i as Int:             return .int(i)
        case let d as Double:          return .double(d)
        case let s as String:          return .string(s)
        case let a as [Any]:           return .array(a.map { JSONValue.from($0) })
        case let o as [String: Any]:   return .object(o.mapValues { JSONValue.from($0) })
        default:                       return .string(String(describing: any!))
        }
    }

    /// 标量取值（JSONPath 取到叶子时的统一出口）。
    public var scalarString: String {
        switch self {
        case .null:      return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i):  return String(i)
        case .double(let d): return RuleValue.numberToString(d)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    public var isNull: Bool { if case .null = self { return true }; return false }

    /// 数组下标访问（`$[0]`）。
    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    /// 成员访问（`$.a.b`）。
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}
