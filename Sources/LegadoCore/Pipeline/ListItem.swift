import Foundation

/// ⭐⭐⭐ **列表项** —— 编排层的「一项」。
///
/// ⚠️ **为什么要这个类型**（2026-10-23 换引擎时暴露的缺口）：
/// 以前的编排层只认「DOM 节点」当列表项 ⇒ **JSON 接口源一个都出不来**
/// （JSONPath 命中的是 JSON 值，不是 DOM 节点 ⇒ `evalNodes` 返回空 ⇒ 列表 0 本）⭐
///
/// ⇒ 现在列表项有两种形态：
/// - `.node(DOMNodeRef)` —— HTML 源（选择器命中）
/// - `.json(JSONValue)`  —— JSON 源（JSONPath / JS 命中）
///
/// ⭐ **基准由它决定**（§S-RES）：
/// - `.node` ⇒ `result` = 那个节点
/// - `.json` ⇒ `result` = **那个对象的 JSON 视图**（站方 `result.book_id` 能取到）⭐
public enum ListItem: Sendable {
    case node(DOMNodeRef)
    case json(JSONValue)

    /// **字段规则求值时的基准**
    public var base: RuleBase {
        switch self {
        case .node(let n): return .element(n)
        case .json(let j): return .json(j)
        }
    }

    /// ⭐⭐⭐ **列表项的【原始字段】**（JSON 源 ⇒ 该对象的**所有键**）
    ///
    /// ⚠️ **为什么必须保留**（轻阅 build215 真机栽在这）：
    ///   站方 jsLib 生成 `data:;base64,<载荷>` 时要读 **book_id / bid / item_id** 之类，
    ///   而宿主原先只把 name/author/… 九个字段送过去 ⇒ **book_id 压根没传过去**
    ///   ⇒ 站方只生成 `{"tab":"小说","url":""}` ⇒ 详情/目录请求全是 book_id=undefined
    ///   ⇒ 服务器回「illegal base64 data at input byte 9」⇒ **整本书崩** ⭐
    public var rawFields: [String: String] {
        switch self {
        case .node:
            return [:]
        case .json(let j):
            return j.stringMap
        }
    }

    /// **是不是空的**（JSON 的 null / 空对象 ⇒ 视为空）
    public var isEmpty: Bool {
        switch self {
        case .node(let n): return n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .json(let j): return j.isNull
        }
    }
}

extension JSONValue {
    /// ⭐ **对象的所有键 ⇒ 字符串字典**（原始字段用）
    ///
    /// ⚠️ 值统一转成字符串（`String(describing:)`）⇒ 与轻阅老引擎的 `raw` 口径一致
    /// （老引擎：`b[rk] = item[rk]` ⇒ 宿主再 `String(describing:)`）
    public var stringMap: [String: String] {
        guard case .object(let o) = self else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in o {
            switch v {
            case .string(let s): out[k] = s
            case .null: continue
            default: out[k] = v.scalarString
            }
        }
        return out
    }
}
