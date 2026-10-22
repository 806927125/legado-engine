import Foundation

/// **JSONPath 求值**（自研）。
///
/// 规格：`docs/legado-semantics.md` §S-JSON-01 / §S-JSON-02 / §S-JSON-06。
///
/// 支持：
/// | 语法 | 含义 |
/// |---|---|
/// | `$` | 根 |
/// | `$.a.b` | 子对象 |
/// | `$['a']['b']` | 子对象（引号形式） |
/// | `$.a[0]` / `$.a[-1]` | 数组下标（负数从末尾算） |
/// | `$.a[*]` / `$.a.*` | 数组/对象的所有子项 |
/// | `$..name` | **递归下降**（任意深度的 `name`） |
///
/// ⚠️ **过滤表达式 `[?(...)]` 本轮不做**（Sextant 风格，Phase 3 单独一层）。
///
/// ⭐ **命中数组时的语义**（§S-JSON-01）：返回**数组的元素**，**只摊一层** ——
/// 这由求值器的出口统一处理，不在 JSONPath 里做。
public enum JSONPath {

    /// 一个路径步骤
    public enum Step: Equatable {
        /// 子对象成员 / 数组下标
        case child(String)
        /// 数组下标（可负）
        case index(Int)
        /// 所有子项
        case wildcard
        /// 递归下降找同名成员
        case recursive(String)
    }

    /// 把路径串解析成步骤序列。
    ///
    /// ⚠️ 解析失败**必须报错**（不许静默返回空）—— 静默空是「静默失效」的源头。
    public static func parse(_ path: String) -> [Step]? {
        var s = path.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("$") { s.removeFirst() }

        var steps: [Step] = []
        var i = s.startIndex

        while i < s.endIndex {
            let c = s[i]
            if c == "." {
                // `..name` = 递归；`.name` = 子成员；`.*` = 通配
                if s.index(after: i) < s.endIndex, s[s.index(after: i)] == "." {
                    var j = s.index(i, offsetBy: 2)
                    // 允许 `..['name']`
                    if j < s.endIndex, s[j] == "[" {
                        guard let (name, next) = readBracketName(s, from: j) else { return nil }
                        steps.append(.recursive(name))
                        i = next
                        continue
                    }
                    var name = ""
                    while j < s.endIndex, isNameChar(s[j]) { name.append(s[j]); j = s.index(after: j) }
                    guard !name.isEmpty else { return nil }
                    steps.append(.recursive(name))
                    i = j
                    continue
                }
                var j = s.index(after: i)
                if j < s.endIndex, s[j] == "*" {
                    steps.append(.wildcard)
                    i = s.index(after: j)
                    continue
                }
                var name = ""
                while j < s.endIndex, isNameChar(s[j]) { name.append(s[j]); j = s.index(after: j) }
                guard !name.isEmpty else { return nil }
                steps.append(.child(name))
                i = j
                continue
            }
            if c == "[" {
                // `['name']` / `[0]` / `[-1]` / `[*]`
                guard let (step, next) = readBracket(s, from: i) else { return nil }
                steps.append(step)
                i = next
                continue
            }
            // 其它字符（路径中间直接跟名字，如 `$abc`）⇒ 当子成员
            var name = ""
            while i < s.endIndex, isNameChar(s[i]) { name.append(s[i]); i = s.index(after: i) }
            guard !name.isEmpty else { return nil }
            steps.append(.child(name))
        }
        return steps
    }

    /// 求值：返回**所有命中**（数组）。
    public static func select(_ root: JSONValue, _ path: String) -> [JSONValue]? {
        guard let steps = parse(path) else { return nil }
        var current: [JSONValue] = [root]
        for step in steps {
            var next: [JSONValue] = []
            for v in current {
                switch step {
                case .child(let name):
                    if let child = v[name] { next.append(child) }
                case .index(let idx):
                    if case .array(let a) = v {
                        let i = idx < 0 ? a.count + idx : idx
                        if i >= 0, i < a.count { next.append(a[i]) }
                    }
                case .wildcard:
                    if case .array(let a) = v { next.append(contentsOf: a) }
                    else if case .object(let o) = v { next.append(contentsOf: o.values) }
                case .recursive(let name):
                    collectRecursive(v, name, &next)
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    /// 递归下降收集所有同名成员（`$..name`）
    private static func collectRecursive(_ v: JSONValue, _ name: String, _ out: inout [JSONValue]) {
        switch v {
        case .object(let o):
            for (k, val) in o {
                if k == name { out.append(val) }
                collectRecursive(val, name, &out)
            }
        case .array(let a):
            for val in a { collectRecursive(val, name, &out) }
        default:
            break
        }
    }

    // MARK: - 内部解析

    private static func readBracket(_ s: String, from start: String.Index) -> (Step, String.Index)? {
        var i = s.index(after: start)   // 跳过 '['
        guard i < s.endIndex else { return nil }
        let c = s[i]

        // `[*]`
        if c == "*" {
            guard let close = s[i...].firstIndex(of: "]") else { return nil }
            return (.wildcard, s.index(after: close))
        }
        // `['name']` / `["name"]`
        if c == "'" || c == "\"" {
            let quote = c
            i = s.index(after: i)
            var name = ""
            while i < s.endIndex, s[i] != quote { name.append(s[i]); i = s.index(after: i) }
            guard i < s.endIndex else { return nil }
            guard let close = s[i...].firstIndex(of: "]") else { return nil }
            return (.child(name), s.index(after: close))
        }
        // `[0]` / `[-1]`
        var num = ""
        while i < s.endIndex, s[i] != "]" { num.append(s[i]); i = s.index(after: i) }
        guard i < s.endIndex, let n = Int(num) else { return nil }
        return (.index(n), s.index(after: i))
    }

    private static func readBracketName(_ s: String, from start: String.Index) -> (String, String.Index)? {
        var i = s.index(after: start)   // 跳过 '['
        guard i < s.endIndex else { return nil }
        let quote = s[i]
        guard quote == "'" || quote == "\"" else { return nil }
        i = s.index(after: i)
        var name = ""
        while i < s.endIndex, s[i] != quote { name.append(s[i]); i = s.index(after: i) }
        guard i < s.endIndex else { return nil }
        guard let close = s[i...].firstIndex(of: "]") else { return nil }
        return (name, s.index(after: close))
    }

    private static func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }
}
