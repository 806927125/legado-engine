import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **复合规则：尾部 `@js:` 必须【先于 `||` 切分】提取**（2026-10-27 真机实证）
///
/// ⚠️⚠️⚠️ **真机症状**：详情「bookUrl 为空」/ 目录「URL 为空」（UAA 四合一 / 知秋源）
///   诊断原文：`规则[videoId||id @js: let type = baseUrl.match(…)] 分支=|| 兜底链 失败=noMatch("|| 兜底链全部未命中")`
///
/// ⭐⭐⭐ **站方原规则**（`sources/✿UAA四合一（知秋）✿-轻阅版.json` → `ruleExplore.bookUrl`）：
/// ```
/// videoId||id
/// @js:
/// let type = baseUrl.match(new RegExp(api + '/(\\w+)/'))[1]
/// getApiUrl(`/${type}/info`, { novelId: result })
/// ```
/// ⇒ 语义 = **「(videoId || id) 选出 id ⇒ 交给 JS 拼 URL」**（JS 跑在**整条链之后**）⭐⭐⭐
///
/// ⚠️⚠️⚠️ **以前错在哪（两个独立的坑，缺一不可）**：
///   ① `||` 先切 ⇒ 变成 `["videoId", "id\n@js:…"]` ⇒ 尾部 `@js:` **只挂在最后一段**
///      ⇒ 第一段命中时 **JS 根本不跑** ⇒ URL 是裸 id ⇒ 真机「bookUrl 为空」⭐⭐⭐
///   ② head 带着**尾换行**（`"id\n"`）⇒ JSON 相对路径被**误判成 CSS 选择器**
///      ⇒ 空 ⇒ 「|| 兜底链全部未命中」⭐⭐⭐
///   ③ 更糟：JS 代码里的 `||`（JS 的「或」运算符）会被 `||` 切分**腰斩** ⭐⭐⭐
///
/// ⇒ **正解**：先把尾部后处理摘出来 ⇒ 剩下的 head 再切 `||`/`&&` ⇒ 整条链的值当 `result` 喂给 JS
///   （与老引擎 `analyzeJsInUrl` 同款：`@js:` 贪婪到末尾 / `<js>` 非贪婪）⭐⭐⭐
final class CompositeRulePostOrderTests: XCTestCase {

    // MARK: - AST 级（不依赖 JS 后端 ⇒ Linux 也能跑）

    /// ⭐⭐⭐⭐⭐ **后处理包住的是【整条兜底链】，不是最后一段**
    func testPostWrapsWholeFallbackChain() {
        let parser = RuleParser()
        let ast = parser.parse("videoId||id\n@js:\nString(result)", isJSON: true)
        guard case .post(let inner, let post) = ast else {
            XCTFail("⭐⭐⭐ 复合规则应解析成 `.post`，实际=\(ast)")
            return
        }
        if case .js = post { /* 期望 */ } else {
            XCTFail("⭐⭐⭐ 后处理应是 `.js`，实际=\(post)")
        }
        guard case .fallback(let xs) = inner else {
            XCTFail("⭐⭐⭐⭐⭐ 后处理里面应是【整条兜底链】（`.fallback`），实际=\(inner)")
            return
        }
        XCTAssertEqual(xs.count, 2, "兜底链应是两段（videoId / id）")
    }

    /// ⭐⭐⭐ **head 的尾换行被 trim**（否则 JSON 相对路径被误判成 CSS 选择器）
    func testHeadTrimsTrailingNewline() {
        let parser = RuleParser()
        let ast = parser.parse("id\n@js:\nString(result)", isJSON: true)
        guard case .post(let inner, _) = ast else {
            XCTFail("应解析成 `.post`，实际=\(ast)")
            return
        }
        // ⭐ 断言「head 里没有换行残留」（形态名不钉死 ⇒ 改实现也不会假红）
        let dumped = String(describing: inner)
        XCTAssertFalse(dumped.contains("\\n"),
                       "⭐⭐⭐⭐⭐ head 里不许有换行残留（`id\\n` 会让 JSON 相对路径判成 CSS）⇒ 实际=\(dumped)")
        XCTAssertTrue(dumped.contains("id"), "head 应含 `id` ⇒ 实际=\(dumped)")
    }

    /// ⭐⭐⭐ **JS 代码里的 `||` 不许被腰斩**（尾部形态的 JS 也要整块保留）
    func testPipeInsideTrailingJsIsNotSplit() {
        let parser = RuleParser()
        let ast = parser.parse("id\n@js:\nvar t = result ? 'a' : 'b'; t || 'x'", isJSON: true)
        guard case .post(let inner, let post) = ast else {
            XCTFail("应解析成 `.post`，实际=\(ast)")
            return
        }
        guard case .js(let code) = post else {
            XCTFail("后处理应是 `.js`，实际=\(post)")
            return
        }
        XCTAssertTrue(code.contains("||"), "JS 代码里的 `||` 要原样保留：\(code)")
        if case .fallback = inner {
            XCTFail("⭐⭐⭐ JS 里的 `||` 被当兜底链拆开了")
        }
    }

    // MARK: - 活体（要 JS 后端 ⇒ 没 node 就显式 SKIP）

    private func makeEvaluator() throws -> Evaluator {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 显式 SKIP（不等于通过）")
        return Evaluator(js: try NodeJSExecutor())
    }

    private func jsonCtx() -> EvalContext {
        let base = RuleBase.json(JSONValue.from(["id": 12345, "videoId": 999] as [String: Any]))
        return EvalContext(base: base,
                          baseUrl: "https://www.uaa1234.com/novel/search?keyword=x&page=1",
                          isJSON: true)
    }

    /// ⭐⭐⭐⭐⭐ **站方形态：兜底链 + 尾部 `@js:` ⇒ URL 拼得出来**
    func testStationShapeProducesURLWithID() throws {
        let ev = try makeEvaluator()
        // ⭐ 条目里**只有 id**（没有 videoId）⇒ 兜底链落到第二段 ⇒ `result` = 12345
        let base = RuleBase.json(JSONValue.from(["id": 12345] as [String: Any]))
        let ctx = EvalContext(base: base,
                              baseUrl: "https://www.uaa1234.com/novel/search?keyword=x&page=1",
                              isJSON: true)
        // ⭐ 用**自足的 api**（不依赖 jsLib 的全局）⇒ 这条门禁只验「复合规则」的语义
        // ⭐ 形状照抄站方：`let type = …[1]` ⏎ `buildUrl(type, result)`（末行是**调用** ⇒ 靠 ASI 分句）
        let rule = """
        videoId||id
        @js:
        function buildUrl(t, id) { return 'https://www.uaa1234.com/' + t + '/info?novelId=' + id }
        let type = baseUrl.match(new RegExp('https://www.uaa1234.com/(\\\\w+)/'))[1]
        buildUrl(type, result)
        """
        let e = ev.evalOne(rule, base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.text, "https://www.uaa1234.com/novel/info?novelId=12345",
                       "⭐⭐⭐⭐⭐ 兜底链的值要喂给尾部 JS（站方语义）")
    }

    /// ⭐⭐⭐ **head 带换行时，JSON 相对路径照样命中**
    func testHeadWithNewlineStillHitsJSONPath() throws {
        let ev = try makeEvaluator()
        let ctx = jsonCtx()
        let e = ev.evalOne("id\n@js:\nString(result)", base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.text, "12345", "⭐⭐⭐ head 的尾换行不许把 JSON 相对路径判成 CSS")
    }

    /// ⭐⭐ **兜底链第一段命中时，尾部 JS 也要跑**（以前不跑 ⇒ URL 是裸 id）
    func testPostAlsoRunsWhenFirstFallbackHits() throws {
        let ev = try makeEvaluator()
        let ctx = jsonCtx()
        let e = ev.evalOne("videoId||id\n@js:\n'got:' + result", base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.text, "got:999",
                       "⭐⭐⭐ 第一段命中时尾部 JS 也要跑（`result` = 兜底链的值）")
    }
}
