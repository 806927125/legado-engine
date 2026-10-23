import Foundation

/// **模板插值** —— `{{表达式}}` 替换。
///
/// 规格：`docs/legado-semantics.md` §S-TPL-01 ~ §S-TPL-05。
///
/// 支持：
/// | 写法 | 含义 |
/// |---|---|
/// | `{{baseUrl}}` | 当前页 URL |
/// | `{{key}}` / `{{page}}` | 搜索词 / 页码 |
/// | `{{$.a.b}}` | 对**当前基准**做 JSONPath |
/// | `{{java.xxx(...)}}` | 站方 JS（Phase 3） |
/// | `{{未知名}}` | 求值失败 ⇒ **替换成空串**（轻阅口径） |
///
/// ⚠️ **JS 模式（`@js:` / `<js>`）不做插值**（§S-TPL-04）——
/// 站方 JS 里 `{{...}}` 是 **JS 对象展开语法**，插值会把整个语法搞坏 ⭐
public enum TemplateEngine {

    /// 整串渲染
    public static func render(_ text: String, ctx: EvalContext) -> String {
        guard text.contains("{{") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            out += rest[rest.startIndex..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                out += "{{" + afterOpen
                return out
            }
            let expr = String(afterOpen[afterOpen.startIndex..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            out += evaluate(expr, ctx: ctx)
            rest = afterOpen[close.upperBound...]
        }
        out += rest
        return out
    }

    /// 单个表达式的值
    public static func evaluate(_ expr: String, ctx: EvalContext) -> String {
        if expr.isEmpty { return "" }
        // 已知变量
        switch expr {
        case "baseUrl": return ctx.baseUrl
        case "key":     return ctx.key
        case "page":   return String(ctx.page)
        case "raw":    return ctx.raw
        default: break
        }
        // 源级变量
        if let v = ctx.vars[expr] { return v }
        // JSONPath：`$.a.b` / `$..x`
        if expr.hasPrefix("$") {
            return jsonPathValue(expr, ctx: ctx)
        }
        // ⭐⭐ **算术表达式**：`{{page-1}}` / `{{page+1}}` / `{{(page-1)*30}}`
        //   （125 源里 **12 个**用 `{{page-1}}`、**1 个**用 `{{page+1}}`）
        //
        // ⚠️⚠️ **以前这些求值失败 ⇒ 返回空串** ⇒ 站方 URL 拼成 `…page=`
        // ⇒ **发现页翻页挂掉**（13 个源受影响）
        if let v = Arithmetic.evaluate(expr, vars: ["page": Double(ctx.page)]) {
            return v
        }
        // 其余：求值失败 ⇒ 空串（轻阅口径）
        return ""
    }

    private static func jsonPathValue(_ path: String, ctx: EvalContext) -> String {
        let root: JSONValue
        switch ctx.base {
        case .json(let j): root = j
        case .page(let raw): root = JSONValue.from(raw)
        case .element(let n), .node(let n): root = JSONValue.object(["_text": .string(n.text)])
        }
        guard let hits = JSONPath.select(root, path), !hits.isEmpty else { return "" }
        return hits.map { $0.scalarString }.joined(separator: ",")
    }
}

/// **`@put:` / `@get:` 内嵌处理**。
///
/// 规格：`docs/legado-semantics.md` §S-PUT-01 ~ §S-PUT-03。
///
/// - `@put:{k:v}` ⇒ 存变量（`v` 支持 `$.a` / 裸路径 / `a||b` 兜底）
/// - `@get:{k}` ⇒ 替换成变量值
/// - 两种都**可以内嵌**在规则或 URL 里（不要求整条规则就是这个形式）⭐
public enum VarStore {

    /// 处理规则里的 `@put:` / `@get:`，并把变更写回 `ctx.vars`
    public static func apply(_ rule: String, ctx: inout EvalContext) -> String {
        var s = rule

        // ① 内嵌 `@put:{k:v}` —— 先执行（它不产生内容）
        s = replace(s, pattern: #"@put:\{([^}]*)\}"#) { body in
            let t = body.trimmingCharacters(in: .whitespaces)
            var k = t, v = ""
            if let i = t.firstIndex(of: ":") {
                k = String(t[t.startIndex..<i]).trimmingCharacters(in: .whitespaces)
                v = String(t[t.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            }
            let value = v.isEmpty ? currentResultText(ctx) : evalVarExpr(v, ctx: ctx)
            // ⭐⭐ 有 varBox ⇒ 写**共享存储**（后续规则 / 站方 JS 读得到）
            if let box = ctx.varBox { box.set(k, value) } else { ctx.vars[k] = value }
            return ""
        }

        // ② `@get:{k}` —— 替换成变量值
        s = replace2(s, pattern: #"@(get|getString|getInt):\{([^}]*)\}"#) { op0, key0 in
            let op = op0.lowercased()
            let key = key0.trimmingCharacters(in: .whitespaces)
            // ⭐⭐ 优先读共享存储（varBox）⇒ 与站方 `java.put` 写的是同一份
            let v = ctx.varBox?.get(key) ?? ctx.vars[key]
            guard let v else { return "" }
            if op == "getint" { return String(Int(v) ?? 0) }
            return v
        }
        return s
    }

    /// `@put` 的值怎么求值：`$.a` / 裸路径 / `a||b`
    public static func evalVarExpr(_ expr: String, ctx: EvalContext) -> String {
        let e = expr.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return "" }
        let root: JSONValue
        switch ctx.base {
        case .json(let j): root = j
        case .page(let raw): root = JSONValue.from(raw)
        case .element(let n), .node(let n): root = JSONValue.object(["_text": .string(n.text)])
        }
        for part in e.components(separatedBy: "||") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            var v = ""
            if p.hasPrefix("$") || p.hasPrefix("result") {
                let path = p.hasPrefix("result") ? "$" + String(p.dropFirst("result".count)) : p
                if let hits = JSONPath.select(root, path), let first = hits.first {
                    v = first.scalarString
                }
            } else {
                // 裸路径：`a.b.c`
                v = lookupPath(p, root)
            }
            if !v.isEmpty { return v }
        }
        return ""
    }

    private static func lookupPath(_ path: String, _ root: JSONValue) -> String {
        var cur: JSONValue? = root
        for seg in path.split(separator: ".") {
            guard let c = cur, let next = c[String(seg)] else { return "" }
            cur = next
        }
        return cur?.scalarString ?? ""
    }

    private static func currentResultText(_ ctx: EvalContext) -> String {
        switch ctx.base {
        case .page(let raw):      return raw
        case .element(let n), .node(let n): return n.text
        case .json(let j):        return j.scalarString
        }
    }

    /// 极简正则替换（`@put:` / `@get:` 里可能含正则元字符 ⇒ 用 NSRegularExpression）
    /// 正则替换（**单**捕获组）
    private static func replace(_ s: String, pattern: String,
                                _ body: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        var out = ""
        var last = 0
        for m in re.matches(in: s, options: [], range: range) {
            out += (s as NSString).substring(with: NSRange(location: last, length: m.range.location - last))
            out += body((s as NSString).substring(with: m.range(at: 1)))
            last = m.range.location + m.range.length
        }
        out += (s as NSString).substring(from: last)
        return out
    }

    /// 正则替换（**双**捕获组）
    private static func replace2(_ s: String, pattern: String,
                                 _ body: (String, String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        var out = ""
        var last = 0
        for m in re.matches(in: s, options: [], range: range) {
            out += (s as NSString).substring(with: NSRange(location: last, length: m.range.location - last))
            let g1 = (s as NSString).substring(with: m.range(at: 1))
            let g2 = (s as NSString).substring(with: m.range(at: 2))
            out += body(g1, g2)
            last = m.range.location + m.range.length
        }
        out += (s as NSString).substring(from: last)
        return out
    }
}

/// ⭐⭐ **模板里的算术求值** —— 支持 `+ - * /`、括号、数字、`page` 这类变量。
///
/// ⚠️⚠️ **以前 `{{page-1}}` 求值失败 ⇒ 返回空串**
/// ⇒ 站方 URL 拼成 `…page=` ⇒ **发现页翻页挂掉**（13 个源受影响）
///
/// 语法（够用就好，不做通用表达式）：
/// ```
/// expr   := term (('+' | '-') term)*
/// term   := factor (('*' | '/') factor)*
/// factor := 数字 | 变量 | '(' expr ')' | '-' factor
/// ```
public enum Arithmetic {
    /// 求值 ⇒ 字符串；**失败返回 nil**（调用方决定兜底）
    public static func evaluate(_ expr: String, vars: [String: Double]) -> String? {
        var p = Parser(chars: Array(expr), vars: vars)
        guard let v = p.parseExpr(), p.atEnd else { return nil }
        return format(v)
    }

    /// 整数不带小数点（`3` 而不是 `3.0`）
    public static func format(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }

    private struct Parser {
        let chars: [Character]
        let vars: [String: Double]
        var i = 0

        init(chars: [Character], vars: [String: Double]) { self.chars = chars; self.vars = vars }

        var atEnd: Bool { i >= chars.count }

        mutating func skipSpaces() {
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        }

        mutating func parseExpr() -> Double? {
            guard var left = parseTerm() else { return nil }
            while true {
                skipSpaces()
                guard i < chars.count, chars[i] == "+" || chars[i] == "-" else { return left }
                let op = chars[i]; i += 1
                guard let right = parseTerm() else { return nil }
                left = (op == "+") ? (left + right) : (left - right)
            }
        }

        mutating func parseTerm() -> Double? {
            guard var left = parseFactor() else { return nil }
            while true {
                skipSpaces()
                guard i < chars.count, chars[i] == "*" || chars[i] == "/" else { return left }
                let op = chars[i]; i += 1
                guard let right = parseFactor() else { return nil }
                if op == "*" {
                    left *= right
                } else {
                    guard right != 0 else { return nil }   // 除零 ⇒ 失败
                    left /= right
                }
            }
        }

        mutating func parseFactor() -> Double? {
            skipSpaces()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c == "-" {
                i += 1
                guard let v = parseFactor() else { return nil }
                return -v
            }
            if c == "(" {
                i += 1
                guard let v = parseExpr() else { return nil }
                skipSpaces()
                guard i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                return v
            }
            if c.isNumber || c == "." {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." {
                    s.append(chars[i]); i += 1
                }
                return Double(s)
            }
            if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    s.append(chars[i]); i += 1
                }
                return vars[s]
            }
            return nil
        }
    }
}
