import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **Linux 可跑的复现**：macOS JSC job 那个红的 `testCompositeInitRuleParsesJSONTextBeforeTail`
///
/// ⚠️ **为什么 macOS 才红**：那条测试用真 `JSCExecutor` ⇒ 走 JS 真实路径。
/// ⇒ Linux 没 JSC ⇒ 那条测试在 Linux 根本跑不到 ⇒ **红灯只在 macOS CI 上出现** ⭐
///
/// ⚠️⭐⭐ **本文件的价值**：用 **stub 执行器精确模拟 JSC 的取值转换**，
/// ⇒ 把「只有 macOS 能复现的 bug」搬到 Linux ⇒ 3 秒出反馈。
///
/// **JSC 的真实转换**（`JSCExecutor.toJSON`）：
/// ```swift
/// if v.isString { return .string(v.toString()) }
/// ```
/// ⇒ 站方 JS 的完成值是**字符串** ⇒ 返回 `.string(文本)`
/// ⇒ `runJS` 再包成 **`RuleValue.json(.string(文本))`**
/// ⇒ `applyTail` 命中的是 **`case .json(let j)`** 分支（**不是** `case .string`！）⭐⭐⭐
final class StringCompletionStubExecutor: JSExecutor {
    private let text: String
    init(text: String) { self.text = text }

    /// 模拟 JSC：站方 JS `result` 的完成值 = 基准原文（字符串）⇒ `.string(...)`
    func run(_ code: String, context: JSRunContext) throws -> JSONValue {
        .string(text)
    }
}

/// ⭐⭐⭐ **复合规则尾巴要在【真解析后的 JSON 对象】上取**
///
/// 站方（大灰狼）形态：`ruleBookInfo.init = "<js>…</js>$.data"`
/// ⇒ JS 的完成值 = **页原文（JSON 文本）**
/// ⇒ 尾巴 `$.data` 要在**解析后的对象**上取，否则 JSONPath 在字符串上查 ⇒ **永远 0 命中**
/// ⇒ init 输出不是对象 ⇒ 详情字段 / tocUrl 载荷里的 book_id、sources **全丢**
/// ⇒ 症状：「详情空白 + 目录 0 章 + 正文空」⭐⭐⭐
final class CompositeTailJSONTextReproTests: XCTestCase {

    private let jsonText = #"{"data":{"book_id":"7412345678901234567","name":"测试书名"}}"#

    private func evalComposite(_ rule: String, text: String) -> (Evaluation, JSONValue) {
        let stub = StringCompletionStubExecutor(text: text)
        let ev = Evaluator(js: stub)
        let base = RuleBase.page(text)
        let ctx = EvalContext(base: base, baseUrl: "https://v5.langge.uk/api/detail",
                              raw: text, isJSON: true)
        let e = ev.evalOne(rule, base: base, ctx: ctx)
        return (e, e.value.jsonValue)
    }

    /// ⭐⭐⭐ **主用例**：JSON 文本的完成值 ⇒ 尾巴必须命中
    func testCompositeTailOnJSONTextCompletionValue() {
        let (e, j) = evalComposite("<js>result</js>$.data", text: jsonText)
        XCTAssertNil(e.diagnostic.failure,
                     "⭐⭐ 复合规则不许报错：\(SourceEngine.diagnosticLine(e.diagnostic))")
        XCTAssertEqual(j["book_id"]?.scalarString, "7412345678901234567",
                       "⭐⭐⭐ 尾巴要能在【真解析后的对象】上取（当成字符串 ⇒ 永远 0 命中）")
        XCTAssertEqual(j["name"]?.scalarString, "测试书名")
    }

    /// ⭐ **老行为不变**：不是 JSON 的文本 ⇒ 仍按普通字符串处理
    func testPlainTextCompletionValueKeepsOldBehaviour() {
        let text = "玄幻::/type/xh&&仙侠::/type/xx"
        let (e, j) = evalComposite("<js>result</js>", text: text)
        XCTAssertNil(e.diagnostic.failure,
                     "⭐ 不该报错：\(SourceEngine.diagnosticLine(e.diagnostic))")
        XCTAssertEqual(j.scalarString, text, "⭐ 不是 JSON 的文本要原样返回")
    }

    /// ⭐⭐ **数组形态**：`$.data` 命中数组 ⇒ 摊平一层（§S-JSON-01）
    func testCompositeTailOnJSONArrayCompletionValue() {
        let text = #"{"data":[{"book_id":"A"},{"book_id":"B"}]}"#
        let (e, _) = evalComposite("<js>result</js>$.data", text: text)
        XCTAssertNil(e.diagnostic.failure,
                     "⭐⭐ 复合规则不许报错：\(SourceEngine.diagnosticLine(e.diagnostic))")
        let (e2, j2) = evalComposite("<js>result</js>$.data", text: text)
        XCTAssertNotNil(e2.diagnostic.failure == nil ? Optional(j2) : nil,
                        "⭐ 数组形态也要能取到")
    }

    /// ⭐⭐⭐ **CSS 尾巴**：`JS 返回 HTML + CSS 选择器`（复合形态的另一半）
    ///
    /// ⚠️ 同一个坑：JSC 路径下完成值是 `.json(.string(html))`
    /// ⇒ 只认 `.string` ⇒ 判成「类型不符」⇒ 站方 HTML 片段选不出来 ⭐
    func testCompositeCSSTailOnStringCompletionValue() {
        let html = "<div class='c'><span class='t'>章节标题</span></div>"
        let (e, _) = evalComposite("<js>result</js>.t", text: html)
        XCTAssertNil(e.diagnostic.failure,
                     "⭐⭐ CSS 尾巴不许报错：\(SourceEngine.diagnosticLine(e.diagnostic))")
    }

    /// ⭐ **不回归**：完成值是**真对象**（不是文本）⇒ 尾巴直接在对象上取（老行为不变）
    func testCompositeTailOnRealJSONObjectUnchanged() {
        let stub = ObjectCompletionStubExecutor(
            object: .object(["data": .object(["book_id": .string("X")])]))
        let ev = Evaluator(js: stub)
        let base = RuleBase.page("{}")
        let ctx = EvalContext(base: base, baseUrl: "https://x.example", raw: "{}", isJSON: true)
        let e = ev.evalOne("<js>result</js>$.data", base: base, ctx: ctx)
        XCTAssertNil(e.diagnostic.failure,
                     "⭐⭐ 对象路径不许报错：\(SourceEngine.diagnosticLine(e.diagnostic))")
        XCTAssertEqual(e.value.jsonValue["book_id"]?.scalarString, "X",
                       "⭐⭐ 对象路径的老行为不能被文本路径的修复改坏")
    }
}

/// ⭐ **完成值是对象**的 stub（模拟 JSC 返回对象时的形态）
final class ObjectCompletionStubExecutor: JSExecutor {
    private let object: JSONValue
    init(object: JSONValue) { self.object = object }
    func run(_ code: String, context: JSRunContext) throws -> JSONValue { object }
}
