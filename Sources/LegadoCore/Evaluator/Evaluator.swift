import Foundation

/// **JS 执行器协议** —— Phase 3 接 JSC，本轮先定接口。
///
/// ⭐ 设计要点：**接口面必须窄到能在 Node 里 mock 出等价物** ——
/// 这样门禁主体仍能在沙盒跑（jsdom），只有极小一块需要真机验。
public protocol JSExecutor {
    /// 执行站方 JS，返回值（转换后的 JSON 形态）
    func run(_ code: String, context: JSContext) throws -> JSONValue
}

/// JS 执行的上下文（**同步**）
public struct JSContext {
    /// 当前基准（决定 `result` 的语义，§S-RES）
    public var base: RuleBase
    public var baseUrl: String
    /// 当前页原文
    public var raw: String
    /// 书籍对象（站方 JS 调 `book.getVariable(...)` 的载体）
    public var book: HostObject?
    /// 书源对象
    public var source: HostObject?
    /// 章节对象
    public var chapter: HostObject?
    /// 源级变量
    public var vars: [String: String]
    /// 搜索词
    public var key: String
    /// 页码
    public var page: Int
    /// 当前页 DOM（站方 JS 里 `document.querySelectorAll` 要指向它）
    public var document: DOMNode?

    public init(base: RuleBase, baseUrl: String = "", raw: String = "",
                book: HostObject? = nil, source: HostObject? = nil, chapter: HostObject? = nil,
                vars: [String: String] = [:], key: String = "", page: Int = 1, document: DOMNode? = nil) {
        self.base = base; self.baseUrl = baseUrl; self.raw = raw
        self.book = book; self.source = source; self.chapter = chapter
        self.vars = vars; self.key = key; self.page = page; self.document = document
    }
}

/// **求值器** —— 规则 + 基准 + 上下文 ⇒ 值。
///
/// 规格：`docs/legado-semantics.md`。
///
/// ⭐ **全同步**（引擎内部全同步，见 docs/architecture.md）⇒ 不需要两遍跑。
public struct Evaluator {

    /// JS 后端（Phase 3 接 JSC；本轮为 nil ⇒ JS 规则返回 .void + 诊断）
    public var js: JSExecutor?

    public init(js: JSExecutor? = nil) { self.js = js }

    // MARK: - 入口

    /// **单条规则**求值（不含 `||` / `&&` / `,` 兜底链的拆分——但 AST 里已经拆了）
    ///
    /// 流程（照轻阅 `evalOne` 的顺序）：
    /// ① `@put:` / `@get:` 内嵌处理（会改 `vars`）
    /// ② **模板插值**（⚠️ **JS 模式不插值**，§S-TPL-04）
    /// ③ 解析成 AST
    /// ④ 按 AST 求值
    public func evalOne(_ rule: String, base: RuleBase, ctx ctxIn: EvalContext) -> RuleValue {
        var ctx = ctxIn
        var r = rule

        // ① @put / @get
        r = VarStore.apply(r, ctx: &ctx)

        // ② 插值 —— ⚠️ JS 模式**不插值**（build202 定的）
        let rawRule = r
        let mode = RuleClassifier.classify(r, isJSON: ctx.isJSON)
        if mode != .js {
            r = TemplateEngine.render(r, ctx: ctx)
        }

        // ②' ⭐ **原规则就是一个 {{占位符}} ⇒ 结果就是这个值**（不再往下走选择器）
        //     规格 §S-TPL-02。轻阅口径：判「原规则」而不是插值后的规则。
        if r != rawRule, RuleParser.isWholeTemplate(rawRule) {
            let whole = r.trimmingCharacters(in: .whitespaces)
            return whole.isEmpty ? .void : .string(whole)
        }

        // ②'' ⭐ **规则本身就是一个字面 URL ⇒ 原样返回**
        //     规格（轻阅 build214 加的）：`https://x/read/@get:{xid}/{{$.num}}`
        //     ⇒ 插值后是纯 URL ⇒ 当值返回，不能当选择器去查。
        let literal = r.trimmingCharacters(in: .whitespaces)
        if literal.hasPrefix("http://") || literal.hasPrefix("https://"),
           !literal.contains(where: { $0.isWhitespace }) {
            return .string(literal)
        }

        // ③ 解析
        let ast = RuleParser().parse(r, isJSON: ctx.isJSON)

        // ④ 求值
        return evaluate(ast, base: base, ctx: ctx)
    }

    /// **列表求值**（含 `||` / `&&` / `,` 兜底链）
    ///
    /// 轻阅的 `getElements` 返回 `[{values:[...], rule:'...'}]`；
    /// 本实现直接返回**拍平的 `[RuleValue]`**。
    public func getElements(_ rule: String, base: RuleBase, ctx: EvalContext) -> [RuleValue] {
        let v = evalOne(rule, base: base, ctx: ctx)
        if v == .void { return [] }
        return v.items
    }

    // MARK: - AST 求值

    public func evaluate(_ node: RuleNode, base: RuleBase, ctx: EvalContext) -> RuleValue {
        switch node {
        case .empty:
            return .void

        case .literal(let s):
            return .string(s)

        case .template(let s):
            return .string(TemplateEngine.render(s, ctx: ctx))

        // ① `||` 择一 —— 第一个非空胜出（§S-FBK-01）
        case .fallback(let xs):
            for x in xs {
                let v = evaluate(x, base: base, ctx: ctx)
                if !v.isEmpty { return v }
            }
            return .void

        // ② `&&` 串接 —— 依次求值并拼接（§S-FBK-02）
        case .concat(let xs):
            let parts = xs.map { evaluate($0, base: base, ctx: ctx).text }
            let joined = parts.joined()
            return joined.isEmpty ? .void : .string(joined)

        // ③ 逗号分隔 —— 第一个非空胜出（§S-FBK-03）
        case .alternatives(let xs):
            for x in xs {
                let v = evaluate(x, base: base, ctx: ctx)
                if !v.isEmpty { return v }
            }
            return .void

        // ④ `@@` 二次解析
        case .reparse(let inner):
            return evaluate(inner, base: base, ctx: ctx)

        // ⑤ 尾部后处理
        case .post(let inner, let post):
            let v = evaluate(inner, base: base, ctx: ctx)
            return applyPost(v, post, base: base, ctx: ctx)

        // ⑥ 正则（对基准的文本）
        case .regex(let pattern, let replacements):
            let text = baseText(base)
            return applyRegex(text, pattern: pattern, replacements: replacements, baseURL: ctx.baseUrl)

        // ⑦ JSONPath
        case .jsonPath(let path):
            guard let j = baseJSON(base) else { return .void }
            guard let hits = JSONPath.select(j, path) else { return .void }
            if hits.isEmpty { return .void }
            if hits.count == 1 { return .json(hits[0]) }
            return .list(hits.map { RuleValue.json($0) })

        // ⑧ XPath —— Phase 2b 后半（子集未做 ⇒ 明确失败，不静默空）
        case .xpath:
            return .void

        // ⑨ CSS / 默认规则链
        case .css(let sel):
            return selectDOM(sel, base: base, ctx: ctx)

        case .chain(let head, let headIndex, let steps):
            return selectDOMChain(head: head, headIndex: headIndex, steps: steps, base: base, ctx: ctx)

        // ⑩ JS
        case .js(let code):
            return runJS(code, base: base, ctx: ctx)

        case .jsWithTail(let code, let tail):
            let v = runJS(code, base: base, ctx: ctx)
            guard let tail, !tail.isEmpty else { return v }
            return applyTail(v, tail, base: base, ctx: ctx)
        }
    }

    // MARK: - DOM

    /// CSS 选择器（`@css:` 显式形态）
    private func selectDOM(_ sel: String, base: RuleBase, ctx: EvalContext) -> RuleValue {
        guard let node = baseNode(base, ctx: ctx) else { return .void }
        let found = node.queryAll(sel)
        guard !found.isEmpty else { return .void }
        return .list(found.map { RuleValue.node(DOMNodeRef($0)) })
    }

    /// 默认规则语法链
    private func selectDOMChain(head: String, headIndex: Int?, steps: [ChainStep],
                                base: RuleBase, ctx: EvalContext) -> RuleValue {
        guard let node = baseNode(base, ctx: ctx) else { return .void }
        let resolved = LegadoSelector.resolve(root: node, head: head, headIndex: headIndex, steps: steps)
        guard !resolved.nodes.isEmpty else { return .void }
        // 取值模式：属性后缀 ⇒ 取值；没有 ⇒ 完整文本
        let values = resolved.nodes.map { n -> RuleValue in
            if let mode = resolved.mode {
                return .string(ValueExtractor.value(n, mode: mode, baseURL: ctx.baseUrl))
            }
            return .string(n.textContent)
        }
        return .list(values)
    }

    // MARK: - 后处理

    private func applyPost(_ value: RuleValue, _ post: RuleNode.PostProcess, base: RuleBase, ctx: EvalContext) -> RuleValue {
        switch post {
        case .regex(let spec):
            let (pattern, replacements) = parseRegexSpec(spec)
            return applyRegex(value.text, pattern: pattern, replacements: replacements, baseURL: ctx.baseUrl)
        case .js(let code):
            // 尾部 `@js:`：以主体结果为 `result`
            var sub = ctx
            sub.base = .page(value.text)
            return runJS(code, base: .page(value.text), ctx: sub)
        }
    }

    /// `##pattern##rep1##rep2##` 的拆分（复用 RuleParser 的口径）
    private func parseRegexSpec(_ spec: String) -> (String, [String]) {
        let parts = spec.components(separatedBy: "##")
        var ops: [String] = []
        if parts.count > 1 {
            for idx in 1..<parts.count {
                if parts[idx].isEmpty && idx == parts.count - 1 { continue }
                ops.append(parts[idx])
            }
        }
        return (ops.first ?? "", ops.count > 1 ? Array(ops.dropFirst()) : [])
    }

    private func applyRegex(_ text: String, pattern: String, replacements: [String], baseURL: String) -> RuleValue {
        guard !pattern.isEmpty else { return .void }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return .void }
        let ns = text as NSString
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var out: [String] = []
        for m in re.matches(in: text, options: [], range: range) {
            // ⚠️ 零宽匹配要跳过并推进，否则会死循环
            if m.range.length == 0 { continue }
            let matched = ns.substring(with: m.range)
            if replacements.isEmpty {
                // ⭐ 纯提取：**取第 1 个捕获组**，没有则取整段（轻阅 `applyRegex` 语义）
                if m.numberOfRanges > 1 {
                    let g1 = m.range(at: 1)
                    out.append(g1.location != NSNotFound ? ns.substring(with: g1) : matched)
                } else {
                    out.append(matched)
                }
            } else {
                // 有替换 ⇒ 对整段做替换（$1..$n 用**原 text** 的捕获组）
                out.append(applyReplacements(matched, m, replacements, in: ns))
            }
            if out.count > 20000 { break }
        }
        guard !out.isEmpty else { return .void }
        return .list(out.map { RuleValue.string($0) })
    }

    /// 替换串里的 `$1`..`$n` ⇒ 捕获组
    ///
    /// ⚠️ **捕获组的 range 是相对【原 text】的**，不是相对 matched ⇒ 必须用原 text 截取。
    private func applyReplacements(_ matched: String, _ m: NSTextCheckingResult,
                                   _ replacements: [String], in ns: NSString) -> String {
        var s = matched
        for rep in replacements {
            var out = ""
            let chars = Array(rep)
            var i = 0
            while i < chars.count {
                if chars[i] == "$", i + 1 < chars.count, chars[i + 1].isNumber {
                    var j = i + 1
                    var numStr = ""
                    while j < chars.count, chars[j].isNumber { numStr.append(chars[j]); j += 1 }
                    if let n = Int(numStr), n <= m.numberOfRanges - 1 {
                        let r = m.range(at: n)
                        if r.location != NSNotFound {
                            out += ns.substring(with: r)
                        }
                    }
                    i = j
                    continue
                }
                out.append(chars[i])
                i += 1
            }
            s = out
        }
        return s
    }

    /// 复合规则的尾部选择器（`<js>代码</js>$.data`）
    private func applyTail(_ value: RuleValue, _ tail: String, base: RuleBase, ctx: EvalContext) -> RuleValue {
        let sel = tail.trimmingCharacters(in: .whitespaces)
        guard !sel.isEmpty else { return value }
        // JSONPath 尾部（最常见）
        if sel.hasPrefix("$") {
            let json: JSONValue
            switch value {
            case .json(let j): json = j
            case .string(let s): json = JSONValue.from(s)
            default: return value
            }
            guard let hits = JSONPath.select(json, sel), !hits.isEmpty else { return .void }
            // ⚠️ 命中数组 ⇒ **摊平一层**（§S-JSON-01）
            if hits.count == 1, case .array(let a) = hits[0] {
                return .list(a.map { RuleValue.json($0) })
            }
            if hits.count == 1 { return .json(hits[0]) }
            return .list(hits.map { RuleValue.json($0) })
        }
        // CSS 尾部：把结果当 HTML 解析再选
        guard case .string(let html) = value else { return value }
        guard let doc = try? SwiftSoupDocument(html: html, baseURL: ctx.baseUrl) else { return .void }
        let nodes = doc.document.queryAll(sel)
        guard !nodes.isEmpty else { return .void }
        return .list(nodes.map { RuleValue.node(DOMNodeRef($0)) })
    }

    // MARK: - JS

    private func runJS(_ code: String, base: RuleBase, ctx: EvalContext) -> RuleValue {
        guard let js else { return .void }
        let jctx = JSContext(base: base, baseUrl: ctx.baseUrl, raw: ctx.raw,
                             book: ctx.book, source: ctx.source, chapter: ctx.chapter,
                             vars: ctx.vars, key: ctx.key, page: ctx.page, document: ctx.document)
        guard let out = try? js.run(code, context: jctx) else { return .void }
        return RuleValue.json(out)
    }

    // MARK: - 基准取用

    private func baseText(_ base: RuleBase) -> String {
        switch base {
        case .page(let raw):      return raw
        case .element(let n), .node(let n): return n.text
        case .json(let j):        return j.scalarString
        }
    }

    private func baseNode(_ base: RuleBase, ctx: EvalContext) -> DOMNode? {
        switch base {
        case .page:               return ctx.document
        case .element(let n), .node(let n): return n.node
        case .json:               return nil
        }
    }

    private func baseJSON(_ base: RuleBase) -> JSONValue? {
        switch base {
        case .json(let j):        return j
        case .page(let raw):      return JSONValue.from(raw)
        case .element, .node:     return nil
        }
    }
}

extension RuleValue {
    /// 是否「空」（兜底链判空用）
    public var isEmpty: Bool {
        switch self {
        case .void:              return true
        case .string(let s):     return s.isEmpty
        case .list(let items):   return items.isEmpty
        case .json(let j):
            // ⚠️ JSON 的**空字符串**也要算空（`||` 兜底链的判空依据）
            switch j {
            case .null:      return true
            case .string(let s): return s.isEmpty
            default:         return false
            }
        case .node:              return false
        }
    }
}
