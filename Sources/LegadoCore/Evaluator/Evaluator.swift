import Foundation

/// **JS 执行器协议** —— Phase 3 接 JSC，本轮先定接口。
///
/// ⭐ 设计要点：**接口面必须窄到能在 Node 里 mock 出等价物** ——
/// 这样门禁主体仍能在沙盒跑（jsdom），只有极小一块需要真机验。
public protocol JSExecutor {
    /// 执行站方 JS，返回值（转换后的 JSON 形态）
    func run(_ code: String, context: JSRunContext) throws -> JSONValue

    /// ⭐⭐ **引擎侧接管 `java.*`**（可选）—— 宿主**不用实现**引擎能做的那些。
    ///
    /// **契约**（125 源真实用量，按处数排序）：
    /// | API | 处数 | 归属 |
    /// |---|---|---|
    /// | `java.md5Encode` | **233** | ⭐ 引擎（纯计算）|
    /// | `java.getString` / `get` / `put` | 63/34/23 | 引擎（源级变量）|
    /// | `java.timeFormat` | 16 | 引擎（纯格式化）|
    /// | `java.ajax` | 27 | ⭐ 引擎（同步发请求）|
    /// | `java.base64Decode` / `base64Encode` / `hexDecodeToString` | 7/5/3 | ⭐ 引擎（纯计算）|
    /// | `java.toast` / `log` / `getCookie` / `startBrowser` … | — | **宿主** |
    ///
    /// ⭐⭐ **因为引擎内部全同步** ⇒ `java.ajax` 可以**同步发请求**并直接返回正文
    /// ⇒ **不需要「两遍跑」机制**（那是 WKWebView 异步桥的补丁）⭐
    ///
    /// - Parameters:
    ///   - method: API 名（如 `ajax` / `md5Encode` / `getString`）
    ///   - args: 参数
    ///   - base: **当前基准**（`java.getString('$.x')` 要对基准做 JSONPath ⇒ 需要它）
    /// - Returns: **返回 nil = 「我不接管」** ⇒ 执行器落回宿主实现
    ///   （⇒ 引擎只抢它真正实现的那几个，其余仍归宿主）
    func setEngineAPI(_ handler: JSEngineAPIHandler?)

    /// ⭐⭐⭐ **把当前全局标为【基线】**（之后不再清理它们）
    ///
    /// ⚠️ **什么时候必须调**：**站方 `loginUrl`（或 jsLib）跑完之后**
    ///   —— 它定义的 `function get_type()` / `function login()` **要长期留在全局** ⭐
    ///   ⇒ 而「每次求值前清掉相对基线新增的全局」会把它们**删掉** ⇒ 站方 JS 后续调用就炸
    /// ⇒ ⇒ 加载完站方脚本 ⇒ 调一次本方法 ⇒ 新基线 ⇒ 之后照常清理 ⭐
    func markGlobalsAsBaseline()

    /// ⭐⭐⭐ **全局求值**（**间接 eval**）—— 只给「站方 jsLib」用
    ///
    /// ⚠️⚠️ **jsLib 的 `var` / `function` 必须留在全局** ⇒ 站方规则才调得到
    ///   （老引擎就是**间接 eval** 加载 jsLib 的 ⇒ 它的全局污染是既定行为）⭐
    /// ⚠️ **而普通的规则求值不能这样** ⇒ 站方代码里的 `let device_type` 会进全局
    ///   ⇒ 同一段代码跑第二次 ⇒ `Can't create duplicate variable` ⇒ **炸** ⭐
    ///   （真机实证：🍅大灰狼聚合的 `exploreUrl`）
    /// ⇒ **两个入口，两个语义**：jsLib 走全局，规则走 eval 局部
    ///
    /// - Note: 默认实现**不保证全局**（只有生产实现该覆盖）⇒ 测试替身够用。
    func runGlobal(_ code: String, context: JSRunContext) throws -> JSONValue

    /// ⭐⭐⭐ **作废 JS 上下文**（下次求值重建一个干净的）
    ///
    /// ⚠️ **站方书源 jsLib 跑完必须调**（它定义的全局 `var host` / `function getArguments`
    /// 会留在 context 里 ⇒ 污染后续规则/其他源）⭐
    /// ⇒ 宿主在「加载书源 jsLib」前后调一次即可。
    func invalidate()
}

/// ⭐ **引擎侧 `java.*` 的实现签名**
public typealias JSEngineAPIHandler = (String, [JSONValue], RuleBase) -> JSONValue?

extension JSExecutor {
    /// 默认实现 = **不接管**（宿主自己实现全部 `java.*`）
    public func setEngineAPI(_ handler: JSEngineAPIHandler?) {}
    /// ⚠️ 默认实现**不保证全局**（只有生产实现该覆盖 ⇒ 测试替身够用）
    public func runGlobal(_ code: String, context: JSRunContext) throws -> JSONValue {
        try run(code, context: context)
    }
    /// 默认实现 = **无可作废的上下文**（无状态执行器）
    public func invalidate() {}
    /// 默认实现 = **无可保留的全局**（无状态执行器）
    public func markGlobalsAsBaseline() {}
}

/// JS 执行的上下文（**同步**）
public struct JSRunContext {
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
    /// ⭐⭐ **源级变量的共享存储**（站方 `java.put` 要能写回引擎）
    public var varBox: VarBox?
    /// 搜索词
    public var key: String
    /// 页码
    public var page: Int
    /// 当前页 DOM（站方 JS 里 `document.querySelectorAll` 要指向它）
    public var document: DOMNode?

    public init(base: RuleBase, baseUrl: String = "", raw: String = "",
                book: HostObject? = nil, source: HostObject? = nil, chapter: HostObject? = nil,
                vars: [String: String] = [:], varBox: VarBox? = nil,
                key: String = "", page: Int = 1, document: DOMNode? = nil) {
        self.base = base; self.baseUrl = baseUrl; self.raw = raw
        self.book = book; self.source = source; self.chapter = chapter
        self.vars = vars; self.varBox = varBox
        self.key = key; self.page = page; self.document = document
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
        // ⭐⭐ **默认带 AST 缓存**（以前默认 nil ⇒ **每次都重新解析**！）
        //
        // ⚠️ 实测：缓存命中只要 0.2µs，而**没命中**（真解析）要 36~80 µs
        //   ⇒ 差 200 倍 ⇒ **默认不给缓存 = 每次求值都在重新解析** ⭐
        //
        // ⚠️ **缓存安全吗**：AST 只由**规则字符串 + isJSON** 决定 ⇒ 同键必同 AST
        //   ⇒ 跨书源共用一个 Evaluator 也不会串（键里已含 isJSON）✔
        //   （`RuleCache.clear()` 仍保留，宿主换源时想清就清）
        self.parser = RuleParser(cache: cache ?? RuleCache())
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
        // ⭐ **换行分隔的多条规则** —— 站方的多规则写法是**换行**。
        //   字符串出口取**第一个非空**（Legado 语义）；列表出口见 `getElements`。
        let lines = Self.splitRuleLines(rule)
        guard lines.count > 1 else {
            return evalSingle(rule, base: base, ctx: ctxIn)
        }
        var lastDiag = EngineDiagnostic(rule: rule)
        for line in lines {
            let e = evalSingle(line, base: base, ctx: ctxIn)
            if !e.value.isEmpty { return e }
            lastDiag = e.diagnostic
        }
        lastDiag.failure = .noMatch(reason: "多行规则全部未命中")
        return Evaluation(value: .void, diagnostic: lastDiag)
    }

    /// ⭐ **整条规则是不是一个 `@get:{k}`** ⇒ 是则返回变量名。
    ///
    /// 形式：`@get:{k}` / `@getString:{k}` / `@getInt:{k}`（**整条**规则）
    private static func pureVarKey(_ rule: String) -> String? {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = t.range(of: #"^@(get|getString|getInt):\{([^}]*)\}$"#, options: .regularExpression)
        else { return nil }
        let body = String(t[m])
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let op = String(body[body.startIndex..<colon])
        let key = String(body[body.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
        guard !key.isEmpty else { return nil }
        return key
    }

    /// **单条规则**求值（不按行拆）
    private func evalSingle(_ rule: String, base: RuleBase, ctx ctxIn: EvalContext) -> Evaluation {
        var ctx = ctxIn
        var r = rule
        var diag = EngineDiagnostic(rule: rule)

        // ① @put / @get
        r = VarStore.apply(r, ctx: &ctx)

        // ①' ⭐ **纯副作用规则**（整条只有 `@put:{k:v}` / `@get:{k}`，**不产出值**）
        //
        // ⚠️ 真书源实测（125 源体检）：`ruleExplore.kind = "@put:{bid:$.bookId}"`
        //    这种规则**只做副作用**（把值存进变量），本来就不产出内容。
        // ⇒ 以前这里 parse 成 `.empty` ⇒ 诊断报「规则解析不出内容」
        //    ⇒ **诊断在说谎**（§S-DIA：真错误 vs 没命中，必须分开）⭐
        //
        // ⇒ 这里明确标成「副作用规则」，**不是错误**，也不当「没命中」。
        if r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diag.branch = "副作用规则（不产出值）"
            return Evaluation(value: .void, diagnostic: diag)
        }

        // ①'' ⭐⭐ **整条规则 = `@get:{k}` ⇒ 结果就是那个值**（§S-EVAL-13）
        //
        // ⚠️⚠️ 以前 `VarStore.apply` 把它替换成变量值后 ⇒ 继续当【选择器】查
        //   ⇒ 规则形如 `@get:{xid}` ⇒ 查 "X-9" ⇒ 命中不了 ⇒ **空**
        // ⇒ 「整条规则 = 取值模式」这条语义（§S-VAL-01：`text` / `href` 同款）
        //   **也要覆盖 `@get:`** ⭐
        // ⚠️ 判**原规则**（跟 §S-TPL-02 一样）⇒ apply 之前就能判定。
        if let key = Self.pureVarKey(rule) {
            let raw = ctx.varBox?.get(key) ?? ctx.vars[key] ?? ""
            let v = raw
            diag.branch = "变量取值模式 @get:{\(key)}"
            if v.isEmpty {
                diag.failure = .noMatch(reason: "变量为空：\(key)")
            }
            return Evaluation(value: .string(v), diagnostic: diag)
        }

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

    /// **列表求值**（含 `||` / `&&` 兜底链 + **换行多规则合并**）
    ///
    /// ⭐ **换行多规则 ⇒ 结果合并**（不是第一个非空）——
    /// 站方的多规则写法是换行，列表出口要把**每一行**的结果都收进来。
    /// ⚠️ 轻阅只返回**第一行**（实测：`getElements("a@text\nb@text")` ⇒ 只有第一行）
    /// ⇒ 这是**轻阅的债**，对拍会把它标成差异。
    public func getElements(_ rule: String, base: RuleBase, ctx: EvalContext) -> Evaluation {
        let lines = Self.splitRuleLines(rule)
        var merged: [RuleValue] = []
        var lastDiag = EngineDiagnostic(rule: rule)
        for line in lines {
            let e = evalSingle(line, base: base, ctx: ctx)
            if e.value.isEmpty { continue }
            merged.append(contentsOf: e.value.items)
            lastDiag = e.diagnostic
        }
        if merged.isEmpty {
            lastDiag.failure = .noMatch(reason: "规则求值为空")
            return Evaluation(value: .void, diagnostic: lastDiag)
        }
        return Evaluation(value: .list(merged), diagnostic: lastDiag)
    }

    /// ⭐ **按换行拆多条规则** —— 整块语法（`{{…}}` / `<js>…</js>` / `@js:`）**不拆**。
    ///
    /// ⚠️ 轻阅的口径叫 `isBlockRule`：整条含块语法就当一整块。
    /// ⭐⭐⭐ **整条规则是不是一个「块规则」**（⇒ 不按行拆）
    ///
    /// ⚠️⚠️ **判据照抄老引擎 `isBlockRule`**（事实标准，2026-10-23 对拍挖出来的）：
    /// ```js
    /// if (t.indexOf('{{') >= 0) return true;            // 模板
    /// if (/^@js:/i.test(t)) return true;                 // @js:
    /// if (/^<[jJ][sS]>/.test(t)) {
    ///   var close = t.toLowerCase().indexOf('</js>');
    ///   if (close < 0) return true;                       // 没闭合的（被截断的）也别切
    ///   var after = t.slice(close + 5);
    ///   if (!after.trim()) return true;                   // 整块就是这条规则
    ///   if (after.indexOf('\n') < 0) return true;         // 同一行的尾巴 ⇒ 复合规则 <js>…</js>$.data
    ///   return false;                                     // 后面还有别的规则行 ⇒ 切
    /// }
    /// ```
    /// ⚠️⚠️ **最后一条最容易搞错**：`</js>` 后面**有换行** ⇒ **要切**
    ///   （红薯小说：`ruleSearch.bookList = "<js>…</js>\n@j"` ⇒ 切 ⇒ 第一行是完整块 ⇒ 命中 ⭐
    ///    ⇒ 不切 ⇒ 尾部 `@j` 被当成选择器 ⇒ 0 命中 ⇒ **列表 0 本**）
    public static func isWholeBlockRule(_ rule: String) -> Bool {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("{{") { return true }
        let lower = t.lowercased()
        if lower.hasPrefix("@js:") { return true }
        guard lower.hasPrefix("<js>") else { return false }
        guard let close = lower.range(of: "</js>") else { return true }   // 没闭合 ⇒ 别切
        // `</js>` 之后的部分
        let afterStart = t.index(t.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: close.upperBound))
        let after = String(t[afterStart...])
        if after.trimmingCharacters(in: .whitespaces).isEmpty { return true }  // 整块
        if !after.contains("\n") { return true }                              // 同行尾巴 = 复合规则
        return false                                                          // 后面还有别的规则行 ⇒ 切
    }

    public static func splitRuleLines(_ rule: String) -> [String] {
        if rule.contains("{{") || rule.contains("@js:") || rule.contains("@get:") || rule.contains("@put:") {
            return [rule]
        }
        // ⭐⭐⭐ **块规则**：整条是 `<js>…</js>`（开头且结尾）⇒ **不按行切**
        //
        // ⚠️⚠️ **但「块后面还跟着东西」⇒ 要切**（老引擎口径，2026-10-23 对拍挖出来的）：
        //   红薯小说：`ruleSearch.bookList = "<js>…</js>\n@j"`
        //   ⇒ 整条**不是**块（结尾是 `@j`）⇒ 按行切 ⇒ 第一行 = 完整块 ⇒ **命中** ⭐
        //   ⇒ 不切的话 ⇒ 尾部 `@j` 被当成选择器 ⇒ 0 命中 ⇒ **列表 0 本**
        if isWholeBlockRule(rule) { return [rule] }
        // ⭐⭐ **快速路径**：规则里**没有换行** ⇒ 不用 split（省 3 次数组/String 分配）
        //   （站方绝大多数规则都是单行 ⇒ 每次求值都白 split 一遍）
        if !rule.contains("\n") && !rule.contains("\r") { return [rule] }
        let lines = rule.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? [rule] : lines
    }

    /// **节点求值** —— 编排层要「一组节点」（列表项 / 章节项），字段层要「一个字符串」。
    ///
    /// ⭐ 走的是**同一条求值路径**（`evaluate(..., rawNodes: true)`）
    /// ⇒ `||` / `&&` / 逗号 / `@@` 等**组合节点天然全支持**。
    ///
    /// ⚠️ 以前编排层另开了一条只认 `.chain` / `.css` 的路径
    /// ⇒ 碰到 `||`（AST = `.fallback`）直接掉进 default ⇒ **整条兜底链返回空**
    /// ⇒ 表现为「分类出得来、目录 0 章」这种「像站方坏了」的故障。
    public func evalNodes(_ rule: String, base: RuleBase, ctx: EvalContext) -> [DOMNodeRef] {
        var out: [DOMNodeRef] = []
        for line in Self.splitRuleLines(rule) {
            let ast = parser.parse(line, isJSON: ctx.isJSON)
            var diag = EngineDiagnostic(rule: line)
            let value = evaluate(ast, base: base, ctx: ctx, diag: &diag, rawNodes: true)
            out.append(contentsOf: value.items.compactMap { item -> DOMNodeRef? in
                if case .node(let n) = item { return n }
                return nil
            })
        }
        return out
    }

    // MARK: - AST 求值

    /// - Parameter rawNodes: `true` ⇒ 链求值**不套取值模式**，返回**节点**（编排层要它）
    ///                       `false` ⇒ 返回已取值的字符串（字段规则用）
    ///
    /// ⭐ **为什么要这个开关**（Phase 3 的教训）：
    /// 编排层要的是「一组节点」（列表项 / 章节项），字段层要的是「一个字符串」。
    /// 以前编排层另开了一条求值路径（`evalNodes`），结果**只认 `.chain` / `.css`**
    /// ⇒ 碰到 `||` 组合节点（`.fallback`）直接掉进 default ⇒ **整条兜底链返回空**
    /// ⇒ 表现为「分类有、目录 0 章」这种「看起来像站方坏了」的故障。
    /// ⇒ 现在**只有一条求值路径**，靠开关区分出口 ⇒ 组合节点天然全支持。
    public func evaluate(_ node: RuleNode, base: RuleBase, ctx: EvalContext,
                          diag: inout EngineDiagnostic, rawNodes: Bool = false) -> RuleValue {
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
                let v = evaluate(x, base: base, ctx: ctx, diag: &sub, rawNodes: rawNodes)
                if !v.isEmpty { diag = sub; return v }
            }
            diag.failure = .noMatch(reason: "|| 兜底链全部未命中")
            diag.branch = "|| 兜底链"
            return .void

        // ② `&&` 串接 —— 依次求值并拼接（§S-FBK-02）
        case .concat(let xs):
            let parts = xs.map { evaluate($0, base: base, ctx: ctx, diag: &diag, rawNodes: rawNodes).text }
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
                let v = evaluate(x, base: base, ctx: ctx, diag: &sub, rawNodes: rawNodes)
                if !v.isEmpty { diag = sub; return v }
            }
            diag.failure = .noMatch(reason: "逗号多规则全部未命中")
            diag.branch = "逗号多规则"
            return .void

        // ④ `@@` 二次解析
        case .reparse(let inner):
            return evaluate(inner, base: base, ctx: ctx, diag: &diag, rawNodes: rawNodes)

        // ⑤ 尾部后处理
        case .post(let inner, let post):
            // ⚠️ rawNodes 模式下**不套后处理** —— 正则/JS 作用于「文本」，
            //    而节点集没有「文本」可替换 ⇒ 强行套会毁掉节点。
            //    ⇒ 透传内层节点，并把这件事记进诊断（不许静默）。
            if rawNodes {
                diag.branch = "尾部后处理（节点模式跳过）"
                return evaluate(inner, base: base, ctx: ctx, diag: &diag, rawNodes: rawNodes)
            }
            let v = evaluate(inner, base: base, ctx: ctx, diag: &diag, rawNodes: rawNodes)
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
                // ⭐⭐⭐ **`result.` 前缀的两种语义都试**（规格 §32）
                //
                //   ① `result.X` 改写成 `$.X`（**根别名**）—— 站方多数写法
                //   ② 命中不了 ⇒ 再按「**顶层 `result` 字段下的 X**」试（`$.result.X`）
                //      （纵横中文的真实接口就是这种：
                //        `{"code":0,"result":{"resultList":[…]}}` + 规则 `result.resultList`）
                //
                // ⚠️ **不能一刀切成一种**（125 源里两种都真实存在）
                // ⚠️ **也不能改写规则本身**（会破坏 132 条对拍）⇒ 只在**求值时**兜底
                if let alt = Self.resultKeyFallback(path),
                   let altHits = JSONPath.select(j, alt), !altHits.isEmpty {
                    diag.branch = "JSONPath（result. 兜底）"
                    if altHits.count == 1 { return .json(altHits[0]) }
                    return .list(altHits.map { RuleValue.json($0) })
                }
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
                                  base: base, ctx: ctx, diag: &diag, rawNodes: rawNodes)

        // ⑩ JS
        case .js(let code):
            return runJS(code, base: base, ctx: ctx, diag: &diag)

        case .jsWithTail(let code, let tail):
            let v = runJS(code, base: base, ctx: ctx, diag: &diag)
            guard let tail, !tail.isEmpty else { return v }
            return applyTail(v, tail, base: base, ctx: ctx, diag: &diag)

        // ⑪ ⭐ **整条规则 = 取值模式** ⇒ 取当前节点的这个值
        //     （站方写法：`"chapterName": "text"` / `"chapterUrl": "href"`）
        case .value(let mode):
            guard let node = baseNode(base, ctx: ctx) else {
                diag.failure = .baseTypeMismatch(expected: "DOM", actual: baseTypeName(base))
                diag.branch = "取值模式"
                return .void
            }
            guard let vm = ValueMode.fromAttributeName(mode) else {
                diag.failure = .unsupportedSyntax("未知取值模式：\(mode)")
                diag.branch = "取值模式"
                return .void
            }
            diag.branch = "取值模式 \(mode)"
            if rawNodes { return .list([RuleValue.node(DOMNodeRef(node))]) }
            return .string(ValueExtractor.value(node, mode: vm, baseURL: ctx.baseUrl))
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
                                diag: inout EngineDiagnostic, rawNodes: Bool = false) -> RuleValue {
        guard let node = baseNode(base, ctx: ctx) else {
            // ⭐⭐⭐ **JSON 基准 + 裸路径** ⇒ 当成「相对 JSON 路径」取（Legado 语义）
            //
            // ⚠️ **为什么必须补这条**（换引擎时暴露的缺口）：
            //   站方 JSON 源的字段规则是**裸字段名**（`name: "bookName"` / `author: "authorName"`）
            //   ⇒ 老引擎（轻阅）在 JSON 基准上 `baseToNode` 返回 null ⇒ **直接返回空**
            //   ⇒ **JSON 接口源一个都出不来**（列表 0 本 / 字段全空）⭐
            //   ⇒ Legado 的语义是「**相对当前 JSON 对象**取字段」⇒ 这里补齐
            //
            // ⚠️ 判据要严：**只认裸路径**（不含 CSS 标记）⇒ 别把 `.content@p@text` 当 JSON 路径
            if steps.isEmpty, headIndex == nil, Self.looksLikeJSONPath(head),
               let j = Self.jsonBaseValue(base, ctx: ctx),
               let hits = JSONPath.select(j, head), !hits.isEmpty {
                diag.branch = "JSON 相对路径"
                if rawNodes { return .list([]) }   // ⭐ JSON 项没有 DOM 节点
                // ⭐ 与 JSONPath 分支同口径：**单个命中 ⇒ 单值**（空字符串也算空 ⇒ 兜底链能继续往下走）
                if hits.count == 1 { return .json(hits[0]) }
                return .list(hits.map { RuleValue.json($0) })
            }
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
        // ⭐ rawNodes ⇒ 返回**节点**（编排层要在条目内再跑字段规则）
        if rawNodes {
            return .list(resolved.nodes.map { RuleValue.node(DOMNodeRef($0)) })
        }
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
            // ⚠️⭐ **尾部正则的语义 = 替换/删除**，不是「纯提取」
            //   `##正则`      ⇒ **删除**匹配部分（站方净化广告的常见写法）
            //   `##正则##替换` ⇒ 替换
            //   （「纯提取」是**整条规则**为 `##正则##` 时的语义，两处别混）
            // ⚠️ 以前这里把 spec 当成「pattern##reps」去拆 ⇒ 「无替换」时 pattern 变空
            //   ⇒ 整条规则返回空 ⇒ 站方 `content = "tag.p@html##我爱读者校园网"` 直接踩中 ⭐
            let (pattern, replacements) = RuleParser.parseRegexRule(spec)
            return applyRegexReplace(value.text, pattern: pattern, replacements: replacements,
                                     baseURL: ctx.baseUrl, diag: &diag)
        case .js(let code):
            // ⭐⭐ **尾部 `<js>` 块 / `@js:` 后缀：以主体结果为 `result`**
            //
            // ⚠️⚠️ 以前这里写的是 `sub.base = .page(value.text)` ⇒ **一律压成字符串**
            // ⇒ 主体是 **JSON 数组/对象** 时，`value.text` 是 **空串**
            //    （`JSONValue.scalarString` 对对象/数组返回 ""）
            // ⇒ JS 里的 `result` = `""` ⇒ 站方 `result.map(...)` / `result.book_id` 全废
            //    ⇒ 这就是「路径 + 尾部 `<js>` 块」复合形态**求值层没做**的真身 ⭐
            //
            // ⇒ 修：**按主体的真实类型**造基准（§S-RES-01 的分层语义）
            //    - 字符串  ⇒ `.page(s)`      ⇒ JS 里 `result` 是字符串
            //    - 数组    ⇒ `.json(array)` ⇒ JS 里 `result` 是**数组**（能 .map）
            //    - 对象    ⇒ `.json(obj)`   ⇒ JS 里 `result` 是**对象**（能取键）
            //    - 节点    ⇒ `.node(n)`     ⇒ JS 里 `result` 是「属性 + _text」
            var sub = ctx
            let jsBase = Self.jsBase(for: value)
            sub.base = jsBase
            return runJS(code, base: jsBase, ctx: sub, diag: &diag)
        case .jsWithTail(let code, let tail):
            // ⭐⭐ **「路径 + `<js>` 块」复合形态**（§S-CMP-06）
            //   `$.data.chapterList[0].volumeList<js>java.put(…);result</js>`
            //   `$.uptime<js>java.getString('$.last_chapter_name')+' '+…</js>`
            // ⇒ 主体求值 ⇒ 结果作为 `result`（**保持原类型**）⇒ 跑 JS ⇒ 再走尾部
            var sub = ctx
            let jsBase = Self.jsBase(for: value)
            sub.base = jsBase
            let v = runJS(code, base: jsBase, ctx: sub, diag: &diag)
            guard let tail, !tail.isEmpty else { return v }
            return applyTail(v, tail, base: jsBase, ctx: sub, diag: &diag)
        }
    }

    /// ⭐⭐⭐ **文本 ⇒ JSON 对象**（复合规则尾巴用）
    ///
    /// ⚠️ 站方的 `init` / `chapterList` 常是 `<js>…</js>$.data` 这种形态：
    ///   JS 跑完得到的是**页原文（JSON 文本）** ⇒ 尾巴（JSONPath）要在**解析后的对象**上取。
    /// ⇒ 长得像 JSON 就**真解析**；不像就按普通字符串处理（老行为）⭐
    static func jsonObject(fromText text: String) -> JSONValue {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("[") else { return .string(text) }
        let parsed = JSONValue(json: t)
        // ⚠️ 解析失败 ⇒ JSONValue(json:) 给 .null ⇒ 回落成字符串（别把内容弄丢）
        return parsed.isNull ? .string(text) : parsed
    }

    /// ⭐⭐⭐ **JSON 值里包着一个「长得像 JSON 的字符串」⇒ 真解析**
    ///
    /// ⚠️⚠️ **为什么需要这一层**（2026-10-24 真机 + Linux 复现）：
    ///   JSC 的完成值是字符串 ⇒ `toJSON` 给 `.string(text)` ⇒ `runJS` 包成
    ///   **`.json(.string(text))`** ⇒ 复合规则的尾巴拿到的是 **`.json` 分支**（不是 `.string`！）
    ///   ⇒ 只在 `.string` 分支解析 = **修复打在了 JSC 走不到的地方** ⇒ 仍然 0 命中 ⭐⭐⭐
    ///
    /// - 非字符串（已是对象/数组）⇒ 原样返回
    /// - 字符串但不像 JSON ⇒ 原样返回（老行为不变）⭐
    static func jsonObjectIfJSONText(_ value: JSONValue) -> JSONValue {
        if case .string(let s) = value { return jsonObject(fromText: s) }
        return value
    }

    /// ⭐⭐⭐ **值里的文本载荷**（`.string` 或 `.json(.string)`）
    ///
    /// ⚠️ JSC 路径下站方 JS 的完成值是字符串 ⇒ `toJSON` 给 `.string(text)`
    /// ⇒ `runJS` 再包成 **`.json(.string(text))`**
    /// ⇒ **只认 `.string` 的地方，在 JSC 路径上全都会走空** ⭐⭐⭐
    ///   （复合规则的 CSS 尾巴就是其中一处）
    static func textPayload(_ value: RuleValue) -> String? {
        switch value {
        case .string(let s):            return s
        case .json(let j):
            if case .string(let s) = j { return s }
            return nil
        default:                        return nil
        }
    }

    /// **JS 基准构造**（尾部 JS 后处理用）—— 主体结果的类型**要原样传下去**。
    private static func jsBase(for value: RuleValue) -> RuleBase {
        switch value {
        case .json:            return .json(value.jsonValue)
        case .list:            return .json(value.jsonValue)
        case .string(let s):   return .page(s)
        case .node(let n):     return .node(n)
        case .void:            return .page("")
        }
    }

    /// **替换 / 删除**（尾部正则语义）—— 与 `applyRegex` 的「纯提取」是两回事。
    ///
    /// - `replacements` 为空 ⇒ 删除匹配部分
    /// - 有多段 ⇒ 第 N 个匹配用第 N 个替换串（用完沿用最后一个）
    private func applyRegexReplace(_ text: String, pattern: String, replacements: [String],
                                   baseURL: String, diag: inout EngineDiagnostic) -> RuleValue {
        guard !pattern.isEmpty else {
            diag.failure = .unsupportedSyntax("尾部正则为空")
            diag.branch = "尾部正则"
            return .void
        }
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            diag.failure = .unsupportedSyntax("正则语法错误：\(pattern)")
            diag.branch = "尾部正则"
            return .void
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [NSTextCheckingResult] = []
        re.enumerateMatches(in: text, options: [], range: range) { m, _, _ in
            if let m { matches.append(m) }
        }
        // ⭐ **倒序替换** —— 正序会把后面的匹配位置推偏
        let ns = NSMutableString(string: text)
        let src = text as NSString
        for (i, m) in matches.enumerated().reversed() {
            let tmpl: String
            if replacements.isEmpty {
                tmpl = ""
            } else if i < replacements.count {
                tmpl = replacements[i]
            } else {
                tmpl = replacements[replacements.count - 1]
            }
            // ⭐⭐ **替换串里的 `$1`..`$n` 要展开成【实际捕获组文本】**
            //    （站方大量这么写：`##clickChargeBook\('(.*?)',(.*?)\)##novel.m?gid=$1&nid=$2`）
            //    ⚠️ 以前直接 `replaceCharacters(in:with:)` ⇒ **不展开** ⇒ URL 里留着字面量 `$1`
            var out = ""
            var p = tmpl.startIndex
            while p < tmpl.endIndex {
                if tmpl[p] == "$" {
                    let q = tmpl.index(after: p)
                    if q < tmpl.endIndex, tmpl[q] == "$" { out += "$"; p = tmpl.index(after: q); continue }
                    var k = q, digits = ""
                    while k < tmpl.endIndex, tmpl[k].isNumber { digits.append(tmpl[k]); k = tmpl.index(after: k) }
                    if !digits.isEmpty, let n = Int(digits), n < m.numberOfRanges {
                        let r = m.range(at: n)
                        out += (r.location == NSNotFound) ? "" : src.substring(with: r)
                        p = k
                        continue
                    }
                }
                out.append(tmpl[p])
                p = tmpl.index(after: p)
            }
            ns.replaceCharacters(in: m.range, with: out)
        }
        diag.branch = "尾部正则"
        return .string(ns as String)
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
            case .json(let j):
                // ⭐⭐⭐ **必须【真解析】**（2026-10-24 真机：大灰狼的 init 规则）
                //   ⚠️⚠️ **这里才是 JSC 实际走的分支**！
                //   `JSCExecutor.toJSON`：JS 完成值是字符串 ⇒ `.string(text)`
                //   ⇒ `runJS` 再包成 **`RuleValue.json(.string(text))`**
                //   ⇒ 以前 `case .json(let j): json = j` ⇒ **没解析**
                //   ⇒ JSONPath 在字符串上查 ⇒ **永远 0 命中**
                //   ⇒ init 输出不是对象 ⇒ 详情字段 / tocUrl 载荷里的 book_id、sources **全丢**
                //   ⇒ 症状：大灰狼「详情空白 + 目录 0 章 + 正文空」⭐⭐⭐
                //
                // ⚠️ 只在「字符串长得像 JSON」时才解析（`{` / `[` 开头且真能解析）
                //    ⇒ 普通文本仍是普通字符串（老行为不变）⭐
                json = Self.jsonObjectIfJSONText(j)
            case .string(let s):
                // ⭐⭐⭐ **必须【真解析】**（2026-10-24 真机：大灰狼的 init 规则）
                //   站方 `init` 是 `<js>…</js>$.data` ⇒ JS 的完成值 = **页原文（JSON 文本）**
                //   ⇒ 尾巴 `$.data` 要在**对象**上取
                //   ⚠️ 以前用 `JSONValue.from(s)` ⇒ **只是「当成普通字符串」**（不解析！）
                //   ⇒ JSONPath 在字符串上查 ⇒ **永远 0 命中**
                //   ⇒ init 输出不是对象 ⇒ 详情字段 / tocUrl 载荷里的 book_id、sources **全丢**
                //   ⇒ 症状：大灰狼「详情空白 + 目录 0 章 + 正文空」⭐⭐⭐
                json = Self.jsonObject(fromText: s)
            default:
                diag.failure = .baseTypeMismatch(expected: "JSON", actual: "其它")
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
        // ⚠️⚠️ **必须同时认 `.json(.string)`**（JSC 路径下站方 JS 的完成值是字符串
        //   ⇒ `runJS` 包成 `.json(.string(html))` ⇒ 只认 `.string` 会把它判成类型不符 ⭐
        guard let html = Self.textPayload(value) else {
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
        let jctx = JSRunContext(base: base, baseUrl: ctx.baseUrl, raw: ctx.raw,
                             book: ctx.book, source: ctx.source, chapter: ctx.chapter,
                             vars: ctx.vars, varBox: ctx.varBox, key: ctx.key, page: ctx.page, document: ctx.document)
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

    /// ⭐⭐⭐ **JSON 基准的值**（`.json` 基准 / JSON 页面的 `.page` 基准）
    ///
    /// ⚠️ **JSON 页面的基准是 `.page(原文)`** ⇒ 要现解析成 JSON 才能当 JSON 用
    static func jsonBaseValue(_ base: RuleBase, ctx: EvalContext) -> JSONValue? {
        switch base {
        case .json(let j): return j
        case .page(let raw):
            // ⚠️ 只有响应**确实是 JSON**（ctx.isJSON）时才当 JSON 基准
            guard ctx.isJSON else { return nil }
            // ⭐⭐⭐ **必须真的解析**（`JSONValue.from(String)` 只会得到一个字符串！）
            return JSONValue(json: raw)
        case .element, .node: return nil
        }
    }

    /// ⭐⭐⭐ **`$.X` ⇒ `$.result.X`**（`result.` 前缀的**第二种解释**）
    ///
    /// ⚠️ 已经是 `$.result.` 开头的**不再兜底**（否则会套娃）
    static func resultKeyFallback(_ path: String) -> String? {
        guard path.hasPrefix("$.") else { return nil }
        let rest = String(path.dropFirst(2))
        guard !rest.hasPrefix("result.") else { return nil }
        return "$.result." + rest
    }

    /// ⭐⭐⭐ **这条规则是不是「裸 JSON 路径」**（`bookName` / `a.b` / `a[0]` / `a.b[1].c`）
    ///
    /// ⚠️ **必须排除 CSS 标记** ⇒ 否则 `.content@p@text` 这种会被当 JSON 路径
    ///   （`JSONPath.parse(".content")` 会解析成 `.child("content")` ⇒ 误命中）
    static func looksLikeJSONPath(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        // ⭐ 开头不能是 CSS 标记
        if let c = t.first, ".*#@>:, [".contains(c) { return false }
        // ⭐ 中间不能有 CSS 标记（`@text` / `>` / `:` / `#` / 空格 / 逗号）
        for c in t {
            if "@>#, \t".contains(c) { return false }
            if c == ":" { return false }
        }
        return true
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
        case .json(let j):
            // ⭐⭐⭐ **基准是「JSON 字符串」⇒ 先解析再用**（老引擎口径）
            //   站方常见：复合规则 `<js>…</js>` 的 JS 返回**一段 JSON 文本**
            //   ⇒ 后续字段规则 `@json:$.catename` 要在这段文本上查 ⇒ **必须先解析** ⭐
            //   （不解析 ⇒ 基准是个字符串 ⇒ JSONPath 永远 0 命中 ⇒ 列表 0 本）
            if case .string(let text) = j,
               let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                return JSONValue.from(obj)
            }
            return j
        case .page(let raw):
            // ⭐ 只有响应**确实是 JSON**（ctx.isJSON）时才当 JSON 基准
            //    否则 ⇒ 返回 nil ⇒ 触发「基准类型不符」的真错误诊断
            //    （以前这里直接 JSONValue.from(HTML) ⇒ 静默「没命中」⭐）
            guard ctx.isJSON else { return nil }
            // ⭐⭐⭐ **必须真的解析成 JSON**！
            //   `JSONValue.from(raw)` 对 String 走的是「当普通字符串」分支
            //   ⇒ 基准变成 `.string(整页JSON)` ⇒ JSONPath 在字符串上查 ⇒ **永远 0 命中**
            //   ⇒ 症状：「所有 JSON 接口源都出不来 / 字段全空」⭐
            //   （`JSONValue(json:)` 才是「从 JSON 文本构造」）
            return JSONValue(json: raw)
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
