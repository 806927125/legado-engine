import Foundation

/// **JSONPath 过滤表达式**（栖阅 Sextant 风格）—— `[?(…)]`。
///
/// ⭐ **为什么要做**：栖阅用 Sextant（MIT 开源包）做过滤 ⇒ 栖阅书源能写
/// `$.data.state[?(@.dataName == 'novel_search_list')].items[*]`，
/// 而 **Legado 安卓端根本没有这层** ⇒ 这是**两端行为差异的根源**。
/// ⇒ 自研引擎补上这层 ⇒ 直接比安卓端强。
///
/// **支持的子集**（照 125 源真实用法 + Sextant 源码级语法表）：
/// - 比较：`==` `!=` `===` `!==` `<` `<=` `>` `>=`
/// - 正则：`=~`（模式在左或右都行）
/// - 集合：`in` `nin` `subsetof` `anyof` `noneof`
/// - 逻辑：`&&` `||` `!`
/// - 存在：`exists`
/// - 路径：`@.a.b`（当前元素）/ `$`（根）/ `@['x']`
/// - 字面量：`true` `false` `null` / 数字 / 单双引号字符串 / `/正则/i`
///
/// ⚠️ **单词运算符大小写不敏感**（Sextant 源码用 `uppercase()` 比对）。
public indirect enum JSONFilter: Equatable {

    /// 比较（`op` 是 `==` / `<` / `=~` / `in` …）
    case compare(op: String, lhs: Operand, rhs: Operand)
    /// 存在性（`exists`）
    case exists(Operand)
    /// 与（`&&`）
    case and([JSONFilter])
    /// 或（`||`）
    case or([JSONFilter])
    /// 非（`!`）
    case not(JSONFilter)

    /// 过滤求值 —— 保留满足条件的元素。
    public static func apply(_ expr: JSONFilter, to items: [JSONValue], root: JSONValue) -> [JSONValue] {
        items.filter { evaluate(expr, item: $0, root: root) }
    }

    /// 单个元素的判定
    public static func evaluate(_ f: JSONFilter, item: JSONValue, root: JSONValue) -> Bool {
        switch f {
        case .and(let xs):
            return xs.allSatisfy { evaluate($0, item: item, root: root) }
        case .or(let xs):
            return xs.contains { evaluate($0, item: item, root: root) }
        case .not(let x):
            return !evaluate(x, item: item, root: root)
        case .exists(let op):
            return !resolve(op, item: item, root: root).isNull
        case .compare(let op, let lhs, let rhs):
            return compare(op: op, lhs: resolve(lhs, item: item, root: root),
                           rhs: resolve(rhs, item: item, root: root))
        }
    }

    // MARK: - 取值

    private static func resolve(_ op: Operand, item: JSONValue, root: JSONValue) -> JSONValue {
        switch op {
        case .literal(let v): return v
        case .current(let path): return walk(item, path)
        case .root(let path):    return walk(root, path)
        }
    }

    private static func walk(_ v: JSONValue, _ path: [String]) -> JSONValue {
        var cur = v
        for p in path {
            if case .object(let o) = cur, let n = o[p] { cur = n }
            else { return .null }
        }
        return cur
    }

    // MARK: - 比较

    private static func compare(op: String, lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch op {
        case "==", "===":
            if op == "===" { return strictEqual(lhs, rhs) }
            return looseEqual(lhs, rhs)
        case "!=", "!==":
            if op == "!==" { return !strictEqual(lhs, rhs) }
            return !looseEqual(lhs, rhs)
        case "<", "<=", ">", ">=":
            guard let a = numeric(lhs), let b = numeric(rhs) else { return false }
            switch op {
            case "<":  return a < b
            case "<=": return a <= b
            case ">":  return a > b
            default:   return a >= b
            }
        case "=~":
            // ⭐ 正则：**模式在左或右都行**（Sextant 源码两个分支都判 `typeName == .pattern`）
            // ⚠️ 语义是「**值 =~ 模式**」⇒ 拿**值**去被**模式**匹配
            //    （反过来做会把「值」当模式 ⇒ 永远不匹配）
            if case .string(let p) = rhs, regexMatch(p, lhs) { return true }
            if case .string(let p) = lhs, regexMatch(p, rhs) { return true }
            return false
        case "in":
            guard case .array(let arr) = rhs else { return false }
            return arr.contains { looseEqual($0, lhs) }
        case "nin":
            guard case .array(let arr) = rhs else { return false }
            return !arr.contains { looseEqual($0, lhs) }
        case "subsetof":
            guard case .array(let a) = lhs, case .array(let b) = rhs else { return false }
            return a.allSatisfy { x in b.contains { looseEqual($0, x) } }
        case "anyof":
            guard case .array(let a) = lhs, case .array(let b) = rhs else { return false }
            return a.contains { x in b.contains { looseEqual($0, x) } }
        case "noneof":
            guard case .array(let a) = lhs, case .array(let b) = rhs else { return false }
            return !a.contains { x in b.contains { looseEqual($0, x) } }
        default:
            return false
        }
    }

    /// **宽松相等**（`==`）：数字之间跨类型比（`1 == 1.0`）
    private static func looseEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = numeric(a), let y = numeric(b) { return x == y }
        if case .bool(let x) = a, case .bool(let y) = b { return x == y }
        if case .string(let x) = a, case .string(let y) = b { return x == y }
        if case .null = a, case .null = b { return true }
        return a == b
    }

    /// **严格相等**（`===`）：**类型也必须相同**（栖阅 Sextant 明确区分 ⇒ `1 !== '1'`）
    private static func strictEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)):   return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    private static func numeric(_ v: JSONValue) -> Double? {
        switch v {
        case .int(let i):    return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    private static func regexMatch(_ pattern: String, _ value: JSONValue) -> Bool {
        let s: String
        switch value {
        case .string(let x): s = x
        case .int(let i):    s = String(i)
        case .double(let d): s = RuleValue.numberToString(d)
        default: return false
        }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.firstMatch(in: s, options: [], range: range) != nil
    }
}

/// 过滤表达式的**操作数**
public indirect enum Operand: Equatable {
    /// `@.a.b` ⇒ 当前元素上的路径
    case current([String])
    /// `$` / `$.a` ⇒ 根上的路径
    case root([String])
    /// 字面量
    case literal(JSONValue)
}

// MARK: - 解析

/// **过滤表达式解析器** —— 递归下降。
public enum JSONFilterParser {

    /// 解析 `[?(…)]` 里的表达式部分（**不含**外层方括号）。
    public static func parse(_ s: String) -> JSONFilter? {
        var p = Cursor(s)
        guard let f = parseOr(&p) else { return nil }
        p.skipSpaces()
        return p.atEnd ? f : nil
    }

    private struct Cursor {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }
        var atEnd: Bool { i >= chars.count }
        func peek(_ o: Int = 0) -> Character? { i + o < chars.count ? chars[i + o] : nil }
        mutating func skipSpaces() { while let c = peek(), c == " " || c == "\t" { i += 1 } }
    }

    // 优先级：|| < && < 比较/一元
    private static func parseOr(_ p: inout Cursor) -> JSONFilter? {
        guard let first = parseAnd(&p) else { return nil }
        var left = first
        while true {
            p.skipSpaces()
            guard let c = p.peek(), c == "|" , p.peek(1) == "|" else { break }
            p.i += 2
            guard let right = parseAnd(&p) else { return nil }
            if case .or(var xs) = left { xs.append(right); left = .or(xs) }
            else { left = .or([left, right]) }
        }
        return left
    }

    private static func parseAnd(_ p: inout Cursor) -> JSONFilter? {
        guard let first = parseUnary(&p) else { return nil }
        var left = first
        while true {
            p.skipSpaces()
            guard let c = p.peek(), c == "&", p.peek(1) == "&" else { break }
            p.i += 2
            guard let right = parseUnary(&p) else { return nil }
            if case .and(var xs) = left { xs.append(right); left = .and(xs) }
            else { left = .and([left, right]) }
        }
        return left
    }

    private static func parseUnary(_ p: inout Cursor) -> JSONFilter? {
        p.skipSpaces()
        if p.peek() == "!" && p.peek(1) != "=" {
            p.i += 1
            guard let x = parseUnary(&p) else { return nil }
            return .not(x)
        }
        // `exists` 前缀
        if let word = peekWord(&p), word.lowercased() == "exists" {
            p.i += word.count
            guard let operand = parseOperand(&p) else { return nil }
            return .exists(operand)
        }
        guard let lhs = parseOperand(&p) else { return nil }
        p.skipSpaces()
        guard let op = peekOperator(&p) else { return nil }
        guard let rhs = parseOperand(&p) else { return nil }
        return .compare(op: op, lhs: lhs, rhs: rhs)
    }

    /// 读一个运算符（含单词运算符）
    private static func peekOperator(_ p: inout Cursor) -> String? {
        p.skipSpaces()
        guard let c = p.peek() else { return nil }
        // 符号运算符（⚠️ `peek(1)` 可能是 nil ⇒ 不能拼成 `"== "`）
        // ⚠️⚠️⚠️ **`===` / `!==` 是【三字符】** ⇒ 两字符匹配抓不到
        //    （`==` 会先命中 ⇒ 剩下 `= 1` ⇒ 右操作数解析失败 ⇒ 整条表达式作废）
        var three = String(c)
        if let c1 = p.peek(1), let c2 = p.peek(2) { three = String([c, c1, c2]) }
        if ["===", "!=="].contains(three) {
            p.i += 3
            return three
        }
        var two = String(c)
        if let c1 = p.peek(1) { two = String([c, c1]) }
        if ["==", "!=", "<=", ">=", "=~"].contains(two) {
            p.i += two.count
            return two
        }
        if c == "<" || c == ">" {
            p.i += 1
            return String(c)
        }
        // 单词运算符（大小写不敏感）
        if let word = peekWord(&p) {
            let lower = word.lowercased()
            if ["in", "nin", "subsetof", "anyof", "noneof"].contains(lower) {
                p.i += word.count
                return lower
            }
        }
        return nil
    }

    /// 读一个单词（标识符）
    private static func peekWord(_ p: inout Cursor) -> String? {
        p.skipSpaces()
        var j = p.i
        while j < p.chars.count, p.chars[j].isLetter || p.chars[j].isNumber { j += 1 }
        guard j > p.i else { return nil }
        return String(p.chars[p.i..<j])
    }

    private static func parseOperand(_ p: inout Cursor) -> Operand? {
        p.skipSpaces()
        guard let c = p.peek() else { return nil }

        // 路径
        if c == "@" || c == "$" {
            let isCurrent = c == "@"
            p.i += 1
            var path: [String] = []
            while p.peek() == "." {
                p.i += 1
                var name = ""
                while let ch = p.peek(), ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                    name.append(ch); p.i += 1
                }
                if name.isEmpty { return nil }
                path.append(name)
            }
            // `@['x']` 形式
            while p.peek() == "[" {
                p.i += 1
                p.skipSpaces()
                guard let q = p.peek(), q == "'" || q == "\"" else { return nil }
                p.i += 1
                var name = ""
                while let ch = p.peek(), ch != q { name.append(ch); p.i += 1 }
                guard p.peek() == q else { return nil }
                p.i += 1
                guard p.peek() == "]" else { return nil }
                p.i += 1
                path.append(name)
            }
            return isCurrent ? .current(path) : .root(path)
        }

        // 字符串
        if c == "'" || c == "\"" {
            p.i += 1
            var s = ""
            while let ch = p.peek(), ch != c { s.append(ch); p.i += 1 }
            guard p.peek() == c else { return nil }
            p.i += 1
            return .literal(.string(s))
        }

        // 正则字面量 `/…/i`
        if c == "/" {
            p.i += 1
            var s = ""
            while let ch = p.peek(), ch != "/" { s.append(ch); p.i += 1 }
            guard p.peek() == "/" else { return nil }
            p.i += 1
            var flags = ""
            while let ch = p.peek(), ch == "i" || ch == "m" || ch == "s" {
                flags.append(ch); p.i += 1
            }
            return .literal(.string(flags.isEmpty ? s : "(?\(flags))\(s)"))
        }

        // ⭐ 数组字面量 `['a','b']`（`in` / `subsetof` / `anyof` 的右操作数）
        if c == "[" {
            p.i += 1
            var items: [JSONValue] = []
            p.skipSpaces()
            if p.peek() == "]" { p.i += 1; return .literal(.array(items)) }
            while true {
                guard let el = parseOperand(&p) else { return nil }
                if case .literal(let v) = el { items.append(v) } else { return nil }
                p.skipSpaces()
                if p.peek() == "," { p.i += 1; continue }
                if p.peek() == "]" { p.i += 1; break }
                return nil
            }
            return .literal(.array(items))
        }

        // 数字 / 布尔 / null
        if c.isNumber || c == "-" {
            var s = ""
            if p.peek() == "-" { s.append("-"); p.i += 1 }
            while let ch = p.peek(), ch.isNumber || ch == "." { s.append(ch); p.i += 1 }
            guard let d = Double(s) else { return nil }
            if d == d.rounded(), abs(d) < 9e15, let i = Int(exactly: d) { return .literal(.int(i)) }
            return .literal(.double(d))
        }
        if let word = peekWord(&p) {
            switch word.lowercased() {
            case "true":  p.i += word.count; return .literal(.bool(true))
            case "false": p.i += word.count; return .literal(.bool(false))
            case "null":  p.i += word.count; return .literal(.null)
            default: return nil
            }
        }
        return nil
    }
}
