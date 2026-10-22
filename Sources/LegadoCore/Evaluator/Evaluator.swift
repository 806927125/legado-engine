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

/// **求值器** —— 规则 + 基准 + 上下文 ⇒ **值 + 诊断**。
///
/// 规格：`docs/legado-semantics.md` §S-EVAL / §S-DIA。
///
/// ⭐ **全同步**（引擎内部全同步，见 docs/architecture.md）⇒ 不需要两遍跑。
///
/// ⭐ **「不许静默失败」是本文件的硬约束**：
/// 每一条返回空的路径**都必须**在诊断里写明原因；
/// 「真错误」（XPath 没实现 / 响应类型不对 / JS 后端缺失）还要能跟「规则没命中」区分开。
public struct Evaluator {

    /// JS 后端（Phase 3 接 JSC；本轮为 nil ⇒ JS 规则报「后端未接」而不是静默空）
    public var js: JSExecutor?

    /// 规则解析器（带 AST 缓存，§S-EVAL-11）
    public var parser: RuleParser

    public init(js: JSExecutor? = nil, cache: RuleCache? = nil) {
        self.js = js
        self.parser = RuleParser(cache: cache)
    }

    // MARK: - 入口

    /// **单条规则**求值
    ///
    /// 流程（照轻阅 `evalOne` 的顺序）：
    /// ① `@put:` / `@get:` 内嵌处理（会改 `vars`）
    /// ② **模板插值**（⚠️ **JS 模式不插值**，§S-TPL-04）
    /// ③ 解析成 AST
    /// ④ 按 AST 求值
    public func evalOne(_ rule: String, base: RuleBase, ctx ctxIn: EvalContext) -> Evaluation {
        var ctx = ctxIn
        var r = rule
        var diag = EngineDiagnostic(rule: rule)

        // ① @put / @get
        r = VarStore.apply(r, ctx: &ctx)

        // ② 插值 —— ⚠️ JS 模式**不插值**（build202 定的）
        let rawRule = r
        let mode = RuleClassifier.classify(r, isJSON: ctx.isJSON)
        diag.mode = mode.rawValue
        if mode != .js {
            r = TemplateEngine.render(r, ctx: ctx)
        }

        // ②' ⭐ **原规则就是一个 {{占位符}} ⇒ 结果就是这个值**（不再往下走选择器）
        //     规格 §S-TPL-02。轻阅口径：判「原规则」而不是插值后的规则。
        if r != rawRule, RuleParser.isWholeTemplate(rawRule) {
            let whole = r.trimmingCharacters(in: .whitespaces)
            if whole.isEmpty {
                diag.failure = .noMatch(reason: "模板插值后为空")
                diag.scope = "整条 {{}} 模板"
                return Evaluation(value: .void, diagnostic: diag)
            }
            diag.branch = "整条 {{}} 模板"
            return Evaluation(value: .string(whole), diagnostic: diag)
        }

        // ②'' ⭐ **规则本身就是一个字面 URL ⇒ 原样返回**
        //     规格（轻阅 build214 加的）：`https://x/read/@get:{xid}/{{$.num}}`
        //     ⇒ 插值后是纯 URL ⇒ 当值返回，不能当选择器去查。
        let literal = r.trimmingCharacters(in: .whitespaces)
        if literal.hasPrefix("http://") || literal.hasPrefix("https://"),
           !literal.contains(where: { $0.isWhitespace }) {
            diag.branch = "字面 URL"
            return Evaluation(value: .string(literal), diagnostic: diag)
        }

        // ③ 解析（**走 AST 缓存**）
        let ast = parser.parse(r, isJSON: ctx.isJSON)

        // ④ 求值
        let value = evaluate(ast, base: base, ctx: ctx, diag: &diag)
        if diag.failure == nil, value.isEmpty {
            diag.failure = .noMatch(reason: "规则求值为空")
        }
        return Evaluation(value: value, diagnostic: diag)
    }

    /// **列表求值**（含 `||` / `&&` / `,` 兜底链）
    public func getElements(_ rule: String, base: RuleBase, ctx: EvalContext) -> Evaluation {
        let e = evalOne(rule, base: base, ctx: ctx)
        if e.value.isEmpty {
            return Evaluation(value: .void, diagnostic: e.diagnostic)
        }
        return Evaluation(value: .list(e.value.items), diagnostic: e.diagnostic)
    }

    // MARK: - AST 求值

    public func evaluate(_ node: RuleNode, base: RuleBase, ctx: EvalContext,
                          diag: inout EngineDiagnostic) -> RuleValue {
        switch node {
        case .empty:
            diag.failure = .noMatch(reason: "空规则")
            return .void

        case .literal(let s):
            return .string(s)

        case .template(let s):
            return .string(TemplateEngine.render(s, ctx: ctx))

        // ① `||` 择一 —— 第一个非空胜出（§S-FBK-01）
        case .fallback(let xs):
            for x in xs {
                var sub = diag
                let v = evaluate(x, base: base, ctx: ctx, diag: &sub)
                if !v.isEmpty { diag = sub; return v }
            }
            diag.failure = .noMatch(reason: "|| 兜底链全部未命中")
            diag.branch = "|| 兜底链"
            return .void

        // ② `&&` 串接 —— 依次求值并拼接（§S-FBK-02）
        case .concat(let xs):
            let parts = xs.map { evaluate($0, base: base, ctx: ctx, diag: &diag).text }
            let joined = parts.joined()
            if joined.isEmpty {
                diag.failure = .noMatch(reason: "&& 串接结果为空")
                diag.branch = "&& 串接"
                return .void
            }
            diag.branch = "&& 串接"
            return .string(joined)

        // ③ 逗号分隔 —— 第一个非空胜出（§S-FBK-03）
        case .alternatives(let xs):
            for x in xs {
                var sub = diag
                let v = evaluate(x, base: base, ctx: ctx, diag: &sub)
                if !v.isEmpty { diag = sub; return v }
            }
            diag.failure = .noMatch(reason: "逗号多规则全部未命中")
            diag.branch = "逗号多规则"
            return .void

        // ④ `@@` 二次解析
        case .reparse(let inner):
            return evaluate(inner, base: base, ctx: ctx, diag: &diag)

        // ⑤ 尾部后处理
        case .post(let inner, let post):
            let v = evaluate(inner, base: base, ctx: ctx, diag: &diag)
            return applyPost(v, post, base: base, ctx: ctx, diag: &diag)

        // ⑥ 正则（对基准的文本）
        case .regex(let pattern, let replacements):
            let text = baseText(base)
            return applyRegex(text, pattern: pattern, replacements: replacements,
                              baseURL: ctx.baseUrl, diag: &diag)

        // ⑦ JSONPath
        case .jsonPath(let path):
            // ⚠️ **基准类型不对 ⇒ 真错误**（例：响应是 HTML，规则却是 JSONPath）
            //    以前这里是静默 .void ⇒ 宿主以为「没命中」，实际是「响应类型不对」⭐
            guard let j = baseJSON(base, ctx: ctx) else {
                diag.failure = .baseTypeMismatch(expected: "JSON", actual: baseTypeName(base))
                diag.branch = "JSONPath"
                return .void
            }
            guard let hits = JSONPath.select(j, path) else {
                diag.failure = .unsupportedSyntax("JSONPath 语法不支持：\(path)")
                diag.branch = "JSONPath"
                return .void
            }
            if hits.isEmpty {
                diag.failure = .noMatch(reason: "JSONPath 未命中：\(path)")
                diag.branch = "JSONPath"
                return .void
            }
            diag.branch = "JSONPath"
            if hits.count == 1 { return .json(hits[0]) }
            return .list(hits.map { RuleValue.json($0) })

        // ⑧ XPath（自研子集，§S-DOM-07）
        case .xpath(let expr):
            guard let node = baseNode(base, ctx: ctx) else {
                diag.failure = .baseTypeMismatch(expected: "DOM", actual: baseTypeName(base))
                diag.branch = "XPath"
                return .void
            }
            guard let hits = XPathEngine.select(node, expr) else {
                diag.failure = .unsupportedSyntax("XPath 语法不支持：\(expr)")
                diag.branch = "XPath"
                return .void
            }
            guard !hits.isEmpty else {
                diag.failure = .noMatch(reason: "XPath 未命中：\(expr)")
                diag.branch = "XPath"
                return .void
            }
            diag.branch = "XPath"
            return .list(hits)

        // ⑨ CSS / 默认规则链
        case .css(let sel):
            return selectDOM(sel, base: base, ctx: ctx, diag: &diag)

        case .chain(let head, let headIndex, let steps):
            return selectDOMChain(head: head, headIndex: headIndex, steps: steps,
                                  base: base, ctx: ctx, diag: &diag)

        // ⑩ JS
        case .js(let code):
            return runJS(code, base: base, ctx: ctx, diag: &diag)

        case .jsWithTail(let code, let tail):
            let v = runJS(code, base: base, ctx: ctx, diag: &diag)
            guard let tail, !tail.isEmpty else { return v }
            return applyTail(v, tail, base: base, ctx: ctx, diag: &diag)
        }
    }

    // MARK: - DOM

    /// CSS 选择器（`@css:` 显式形态）
    private func selectDOM(_ sel: String, base: RuleBase, ctx: EvalContext,
                           diag: inout EngineDiagnostic) -> RuleValue {
        guard let node = baseNode(base, ctx: ctx) else {
            diag.failure = .baseTypeMismatch(expected: "DOM", actual: baseTypeName(base))
            diag.branch = "CSS"
            return .void
        }
        let found = node.queryAll(sel)
        guard !found.isEmpty else {
            diag.failure = .noMatch(reason: "CSS 未命中：\(sel)")
            diag.branch = "CSS"
            return .void
        }
        diag.branch = "CSS"
        return .list(found.map { RuleValue.node(DOMNodeRef($0)) })
    }

    /// 默认规则语法链
    private func selectDOMChain(head: String, headIndex: Int?, steps: [ChainStep],
                                base: RuleBase, ctx: EvalContext,
                                diag: inout EngineDiagnostic) -> RuleValue {
        guard let node = baseNode(base, ctx: ctx) else {
            diag.failure = .baseTypeMismatch(expected: "DOM", actual: baseTypeName(base))
            diag.branch = "默认规则链"
            return .void
        }
        let resolved = LegadoSelector.resolve(root: node, head: head, headIndex: headIndex, steps: steps)
        guard !resolved.nodes.isEmpty else {
            diag.failure = .noMatch(reason: "默认规则链未命中：\(head)")
            diag.branch = "默认规则链"
            return .void
        }
        diag.branch = "默认规则链"
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

    private func applyPost(_ value: RuleValue, _ post: RuleNode.PostProcess, base: RuleBase,
                           ctx: EvalContext, diag: inout EngineDiagnostic) -> RuleValue {
        switch post {
        case .regex(let spec):
            let (pattern, replacements) = parseRegexSpec(spec)
            return applyRegex(value.text, pattern: pattern, replacements: replacements,
                              baseURL: ctx.baseUrl, diag: &diag)
        case .js(let code):
            // 尾部 `@js:`：以主体结果为 `result`
            var sub = ctx
            sub.base = .page(value.text)
            return runJS(code, base: .page(value.text), ctx: sub, diag: &diag)
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

    private func applyRegex(_ text: String, pattern: String, replacements: [String],
                            baseURL: String, diag: inout EngineDiagnostic) -> RuleValue {
        guard !pattern.isEmpty else {
            diag.failure = .unsupportedSyntax("正则规则为空")
            return .void
        }
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            // ⚠️ 正则语法错 = **真错误**（规则写错了，不是「没匹配」）
            diag.failure = .unsupportedSyntax("正则语法错误：\(pattern)")
            return .void
        }
        let ns = text as NSString
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var out: [String] = []
        for m in re.matches(in: text, options: [], range: range) {
            // ⚠️ 零宽匹配要跳过（否则死循环）
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
        guard !out.isEmpty else {
            diag.failure = .noMatch(reason: "正则未命中：\(pattern)")
            return .void
        }
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
    private func applyTail(_ value: RuleValue, _ tail: String, base: RuleBase, ctx: EvalContext,
                           diag: inout EngineDiagnostic) -> RuleValue {
        let sel = tail.trimmingCharacters(in: .whitespaces)
        guard !sel.isEmpty else { return value }
        // JSONPath 尾部（最常见）
        if sel.hasPrefix("$") {
            let json: JSONValue
            switch value {
            case .json(let j): json = j
            case .string(let s): json = JSONValue.from(s)
            default:
                diag.failure = .baseTypeMismatch(expected: "JSON", actual: "字符串")
                return .void
            }
            guard let hits = JSONPath.select(json, sel) else {
                diag.failure = .unsupportedSyntax("JSONPath 语法不支持：\(sel)")
                return .void
            }
            guard !hits.isEmpty else {
                diag.failure = .noMatch(reason: "复合规则尾部未命中：\(sel)")
                return .void
            }
            // ⚠️ 命中数组 ⇒ **摊平一层**（§S-JSON-01）
            if hits.count == 1, case .array(let a) = hits[0] {
                return .list(a.map { RuleValue.json($0) })
            }
            if hits.count == 1 { return .json(hits[0]) }
            return .list(hits.map { RuleValue.json($0) })
        }
        // CSS 尾部：把结果当 HTML 解析再选
        guard case .string(let html) = value else {
            diag.failure = .baseTypeMismatch(expected: "HTML 字符串", actual: "其它")
            return .void
        }
        guard let doc = try? SwiftSoupDocument(html: html, baseURL: ctx.baseUrl) else {
            diag.failure = .other("复合规则尾部：HTML 解析失败")
            return .void
        }
        let nodes = doc.document.queryAll(sel)
        guard !nodes.isEmpty else {
            diag.failure = .noMatch(reason: "复合规则尾部未命中：\(sel)")
            return .void
        }
        return .list(nodes.map { RuleValue.node(DOMNodeRef($0)) })
    }

    // MARK: - JS

    private func runJS(_ code: String, base: RuleBase, ctx: EvalContext,
                       diag: inout EngineDiagnostic) -> RuleValue {
        guard let js else {
            // ⚠️ **JS 后端没接** = 真错误（不是「没命中」）
            diag.failure = .unsupportedSyntax("JS 后端未接（Phase 3）")
            diag.branch = "JS"
            return .void
        }
        let jctx = JSContext(base: base, baseUrl: ctx.baseUrl, raw: ctx.raw,
                             book: ctx.book, source: ctx.source, chapter: ctx.chapter,
                             vars: ctx.vars, key: ctx.key, page: ctx.page, document: ctx.document)
        do {
            let out = try js.run(code, context: jctx)
            diag.branch = "JS"
            return RuleValue.json(out)
        } catch {
            diag.failure = .jsError(String(describing: error))
            diag.branch = "JS"
            return .void
        }
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

    private func baseJSON(_ base: RuleBase, ctx: EvalContext) -> JSONValue? {
        switch base {
        case .json(let j):        return j
        case .page(let raw):
            // ⭐ 只有响应**确实是 JSON**（ctx.isJSON）时才当 JSON 基准
            //    否则 ⇒ 返回 nil ⇒ 触发「基准类型不符」的真错误诊断
            //    （以前这里直接 JSONValue.from(HTML) ⇒ 静默「没命中」⭐）
            guard ctx.isJSON else { return nil }
            return JSONValue.from(raw)
        case .element, .node:     return nil
        }
    }

    /// 基准的类型名（诊断用）
    private func baseTypeName(_ base: RuleBase) -> String {
        switch base {
        case .page:      return "HTML/文本"
        case .element:   return "DOM 元素"
        case .node:      return "DOM 节点"
        case .json:      return "JSON"
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
            case .null:          return true
            case .string(let s): return s.isEmpty
            default:             return false
            }
        case .node:              return false
        }
    }
}
