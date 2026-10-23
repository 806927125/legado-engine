import Foundation
import CoreFoundation

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
    ///
    /// ⚠️⚠️ **`NSNumber` 的双重身份**（Foundation 的老坑，也是本项目踩过两次的坑）：
    /// `NSNumber(value: 1)` **既能** `as? Int`（=1）**又能** `as? Bool`（=true）。
    /// ⇒ 以前 `case let b as Bool` 排在 Int 前面 ⇒ **所有数字 1 都变成 `true`** ⭐
    /// ⇒ 表现：JSONPath 取到的 `{"n":1}` 变成 `{"n":true}` ⇒ 站方的数字判断全错。
    ///
    /// ⇒ 修法：**用 `CFBooleanGetTypeID()` 精确判别**，且把 NSNumber 单独一条分支处理。
    public static func from(_ any: Any?) -> JSONValue {
        switch any {
        case nil, is NSNull:
            return .null
        case let n as NSNumber:
            // ⭐ 精确判别「是不是布尔」—— 不能靠 `as? Bool`
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            let d = n.doubleValue
            if d == d.rounded(), abs(d) < 9e15, let i = Int(exactly: d) {
                return .int(i)
            }
            return .double(d)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map { JSONValue.from($0) })
        case let o as [String: Any]:
            return .object(o.mapValues { JSONValue.from($0) })
        default:
            return .string(String(describing: any!))
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
