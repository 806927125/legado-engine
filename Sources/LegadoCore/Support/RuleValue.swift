import Foundation

/// 规则求值的**值系统**。
///
/// 规格：`docs/legado-semantics.md` §S-JSON / §S-RES。
///
/// ⭐ **为什么类型要固定下来**：
/// 轻阅的教训（build160/161/213）—— 「JSON 对象被 flatten 成字符串」「对象原样保留」
/// 「标题被吃掉」这三件事反复出现，根因全是**值的形状没有定义**，转换散落在各个调用点。
/// 这里把形状**收进类型**：
/// - 字段规则（name/author/…）⇒ 出口统一是 `String`
/// - 列表规则（bookList/chapterList）⇒ 出口统一是 `[RuleValue]`
/// - JSON 对象 ⇒ 出口统一是 `.json(JSONValue)`，**不得**被隐式 stringify
public indirect enum RuleValue: Sendable, Equatable {
    case void
    case string(String)
    case list([RuleValue])
    case json(JSONValue)
    /// DOM 节点（由 DOM 层提供；核心层只认它的身份，不认它的实现）
    case node(DOMNodeRef)

    /// **JSON 视图**（喂给 JS / 序列化用）—— 核心层的**唯一**转换口径。
    ///
    /// ⭐⭐ 为什么必须有它：`text` 对 `.json`/`.list` 是**空的或拼起来的**（对象/数组的
    /// `scalarString` 返回 ""）⇒ 拿 `text` 去喂 JS ⇒ 站方拿到的是**字符串**而不是
    /// **结构** ⇒ `result.map(...)` / `result.book_id` 全废。
    ///
    /// ⭐ 这正是「路径 + 尾部 `<js>` 块」复合形态（§S-CMP-06）以前**求值层没做**的真身。
    public var jsonValue: JSONValue {
        switch self {
        case .void:              return .null
        case .string(let s):    return .string(s)
        case .list(let items):  return .array(items.map { $0.jsonValue })
        case .json(let j):      return j
        case .node(let n):
            // 节点 ⇒ 「全部属性 + `_text`」（站方 JS 读节点属性的写法）
            var obj: [String: JSONValue] = [:]
            for (k, v) in n.node.attributes { obj[k] = .string(v) }
            obj["_text"] = .string(n.text)
            return .object(obj)
        }
    }

    /// 出口 1：字段规则 —— 一律转成字符串。
    public var text: String {
        switch self {
        case .void:              return ""
        case .string(let s):    return s
        case .list(let items):  return items.map { $0.text }.joined(separator: "\n")
        case .json(let j):      return j.scalarString
        case .node(let n):      return n.text
        }
    }

    /// 出口 2：列表规则 —— 一律转成数组，**只摊平一层**。
    ///
    /// 规格 §S-JSON-01：「命中数组时返回**数组的元素**（只摊一层）」。
    /// ⚠️ 轻阅的 `jsonListOf()` 就是这么做的；摊两层会把嵌套数组也扯平。
    public var items: [RuleValue] {
        switch self {
        case .void:              return []
        case .string(let s):    return s.isEmpty ? [] : [.string(s)]
        case .list(let items):  return items
        case .json(let j):
            if case .array(let a) = j { return a.map { RuleValue.json($0) } }
            return j.isNull ? [] : [.json(j)]
        case .node:             return [self]
        }
    }

    /// 数字转字符串的**统一**口径（避免 "2.0" 这种坑）。
    public static func numberToString(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 {
            return String(Int(d))
        }
        return String(d)
    }
}
