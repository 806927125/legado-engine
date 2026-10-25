import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **`@js:` 规则里的 `||` 不许被当成「兜底链」拆开**（2026-10-25 真机实证）
///
/// ⚠️⚠️⚠️ **这是「很多书源都是这样」的通用真凶**：
/// · `@js:` 后面是**站方的 JavaScript 代码** ⇒ 里面的 `||` 是 **JS 的「或」运算符**
/// · 而解析器把规则按 `||` 拆成「兜底链」⇒ **JS 代码被腰斩** ⇒ 规则失败 ⭐⭐⭐
/// · 例：`@js:var t = result.tab || "小说"; …` ⇒ 被拆成两段 ⇒ 两段都不是合法 JS ⭐⭐⭐
///
/// ⭐ **实测影响面**（125 个真源扫描）：
/// · `@js:` 规则共 **111 条** ⇒ 其中含 `||` 的 **51 条** ⇒ **10 个源**直接受影响
///   （番茄小说TS / 吉站漫画 / 卡拉漫画 / 七猫小说 / …）⭐⭐⭐
/// ⇒ 而这些源在真机上的症状就是「发现/目录/正文空」⇒ **看起来像站方坏了** ⭐⭐⭐
///
/// ⭐ 修法：**`@js:` 前缀的规则整体当 JS**（与 `<js>…</js>` 整块同待遇）
final class JsRulePipeOperatorTests: XCTestCase {

    /// ⭐⭐⭐⭐⭐ **`||` 必须在 JS 代码里原样保留**（不被当兜底链拆）
    func testPipeOperatorInsideJsRuleIsNotSplit() {
        let parser = RuleParser()
        let ast = parser.parse("@js:var t = result.tab || \"小说\"; t", isJSON: true)
        // ⭐ 不该是 `.fallback`（兜底链）⇒ 必须是 `.js`
        if case .fallback = ast {
            XCTFail("⭐⭐⭐ `@js:` 里的 `||` 被当兜底链拆开了（JS 代码被腰斩）")
        }
        guard case .js(let code) = ast else {
            XCTFail("⭐⭐⭐ `@js:` 规则应解析成 `.js`，实际=\(ast)")
            return
        }
        XCTAssertTrue(code.contains("||"), "JS 代码里的 `||` 要原样保留：\(code)")
    }

    /// ⭐⭐⭐ **`&&` 同理**（JS 的「与」）
    func testAmpersandInsideJsRuleIsNotSplit() {
        let parser = RuleParser()
        let ast = parser.parse("@js:var x = a && b; x", isJSON: true)
        if case .fallback = ast {
            XCTFail("⭐⭐⭐ `@js:` 里的 `&&` 被当兜底链拆开了")
        }
        if case .concat = ast {
            XCTFail("⭐⭐⭐ `@js:` 里的 `&&` 被当串接拆开了")
        }
    }

    /// ⭐⭐⭐⭐⭐ **端到端：带 `||` 的 JS 规则能正确求值**
    func testJsRuleWithPipeOperatorEvaluates() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 跑不了（显式 SKIP）")
        let js = try NodeJSExecutor()
        let ev = Evaluator(js: js)
        let obj = JSONValue.object(["book_id": .string("MTgzNTEy"), "tab": .string("小说")])
        let base = RuleBase.json(obj)
        let ctx = EvalContext(base: base, baseUrl: "https://x", isJSON: true)
        let e = ev.evalOne("@js:var t = result.tab || \"默认\"; JSON.stringify({tab:t})",
                          base: base, ctx: ctx)
        XCTAssertNil(e.diagnostic.failure,
                     "⭐⭐⭐ 带 `||` 的 `@js:` 规则不该失败：\(SourceEngine.diagnosticLine(e.diagnostic))")
        XCTAssertTrue(e.value.text.contains("小说"),
                      "⭐⭐⭐ `result.tab || \"默认\"` 应取到真值：\(e.value.text)")
    }

    /// ⭐⭐⭐⭐⭐ **`<js>…</js>` 整块本来就有保护**（回归护栏）
    func testBlockRuleStillNotSplit() {
        let parser = RuleParser()
        let ast = parser.parse("<js>var t = a || b; t</js>", isJSON: true)
        if case .fallback = ast {
            XCTFail("`<js>…</js>` 里的 `||` 被拆开了（既有保护被破坏）")
        }
    }

    /// ⭐⭐⭐⭐⭐ **顶层 `return` 要支持**（2026-10-25 真机实证，通用缺口）
    ///
    /// ⚠️ **站方真的写顶层 `return`**（🍅大灰狼的 `ruleBookInfo.tocUrl` 就是）
    ///   ⇒ 只按 Script 求值 ⇒ **语法错** ⇒ 规则失败 ⭐⭐⭐
    func testTopLevelReturnIsSupported() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 跑不了")
        let js = try NodeJSExecutor()
        let ev = Evaluator(js: js)
        let obj = JSONValue.object(["book_id": .string("MTgzNTEy"), "tab": .string("小说")])
        let base = RuleBase.json(obj)
        let ctx = EvalContext(base: base, baseUrl: "https://x", isJSON: true)
        let e = ev.evalOne("@js:var b = result.book_id; return \"id=\" + b;",
                          base: base, ctx: ctx)
        XCTAssertNil(e.diagnostic.failure,
                     "⭐⭐⭐ 顶层 `return` 不该失败：\(SourceEngine.diagnosticLine(e.diagnostic))")
        XCTAssertTrue(e.value.text.contains("MTgzNTEy"),
                      "⭐⭐⭐ 顶层 `return` 的值要拿到：\(e.value.text)")
    }

    /// ⭐⭐⭐⭐⭐ **对象字面量当规则**要能用（老引擎/栖阅同款兜底）
    func testObjectLiteralRuleWorks() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 跑不了")
        let js = try NodeJSExecutor()
        let ev = Evaluator(js: js)
        let base = RuleBase.page("")
        let ctx = EvalContext(base: base, baseUrl: "https://x", isJSON: false)
        let e = ev.evalOne("@js:{a:1, b:\"x\"}", base: base, ctx: ctx)
        XCTAssertNil(e.diagnostic.failure,
                     "⭐⭐⭐ 对象字面量规则不该失败：\(SourceEngine.diagnosticLine(e.diagnostic))")
        // ⭐⭐ **对象要看 `value`，不是 `text`**（`text` 对对象是空串）⭐⭐
        if case .json(let j) = e.value {
            XCTAssertEqual(j["a"]?.scalarString, "1", "对象字面量的 a 要取得到")
        } else {
            XCTFail("对象字面量规则应返回对象，实际=\(e.value)")
        }
    }

    /// ⭐⭐⭐⭐⭐ **非 JS 规则的 `||` 仍要当兜底链**（别把现在能用的搞坏）
    func testNonJsRuleStillUsesFallback() {
        let parser = RuleParser()
        let ast = parser.parse("div.a@text||div.b@text", isJSON: false)
        if case .fallback = ast {
            // ✅ 这是期望的：普通规则的 `||` 仍是兜底链
        } else {
            XCTFail("⭐⭐⭐ 普通规则的 `||` 仍应是兜底链，实际=\(ast)")
        }
    }
}
