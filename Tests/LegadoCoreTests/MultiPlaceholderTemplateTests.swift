import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **多占位符模板规则必须能出值**（2026-10-25 真机 build253 实证）
///
/// **症状**（真机日志）：
/// ```
/// 规则[{{$.category}}\n{{$.score}}\n{{$.status}}\n{{$.source}}\n{{$.tags}}]
///   分支=默认规则链 失败=baseTypeMismatch(expected: "DOM", actual: "JSON")
/// 规则[{{$.last_chapter_title}} • {{$.last_update_time}}]
///   分支=默认规则链 失败=baseTypeMismatch(expected: "DOM", actual: "JSON")
/// ```
/// ⇒ 详情页的「分组 / 类型 / 更新」三格全取不到值（App 显示「未分组 / 文本 / 未加载」）⭐⭐⭐
///
/// **根因**：
/// · `TemplateEngine.render` **支持**多占位符（渲染出来是对的）⭐
/// · 但 `RuleParser.isWholeTemplate` **只认「整条一个 `{{…}}`」** ⇒ 多占位符 ⇒ false ⭐
/// · ⇒ 渲染完**继续当选择器去查** ⇒ 走「默认规则链」⇒ 期望 DOM 实际 JSON ⇒ **失败** ⭐⭐⭐
///
/// **Legado 语义**：`{{…}}` 模板规则渲染后**就是值** ⇒ 不该再往下走选择器 ⭐⭐⭐
final class MultiPlaceholderTemplateTests: XCTestCase {

    /// ⭐⭐⭐ 假基准：JSON 形态（模拟真机的 JSON 基准）
    private func jsonBase() -> RuleBase {
        let json = """
        {"category":"玄幻","score":9.1,"status":"连载中","source":"番茄","tags":"都市,爽文",
         "last_chapter_title":"第2489章 独家新番外上线","last_update_time":"2024-09-14",
         "last_chapter_update_time":"2024-09-15","book_name":"恰似寒光遇骄阳"}
        """
        // ⚠️⚠️ **`JSONValue.from` 收 `Any?`** ⇒ 直接传 String 会得到 `.string(json)`
        //   ⇒ **不是对象** ⇒ JSONPath 取不到任何值 ⇒ 模板渲染成空 ⭐⭐⭐
        //   ⇒ 必须先 `JSONSerialization` 解析成字典 ⭐
        let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        return .json(JSONValue.from(obj))
    }

    private func eval(_ rule: String) -> Evaluation {
        let base = jsonBase()
        let ctx = EvalContext(base: base, baseUrl: "https://v5.langge.uk",
                              raw: "", isJSON: true)
        return Evaluator().evalOne(rule, base: base, ctx: ctx)
    }

    /// ⭐⭐⭐⭐⭐ **多占位符（用空格隔开）⇒ 必须出值**
    func testMultiPlaceholderWithSpaces() {
        let e = eval("{{$.source}} {{$.last_chapter_title}} {{$.last_chapter_update_time}}")
        XCTAssertNil(e.diagnostic.failure, "多占位符模板不该失败：\(String(describing: e.diagnostic.failure))")
        XCTAssertTrue(e.value.text.contains("番茄"), "应含 source，实际=\(e.value.text)")
        XCTAssertTrue(e.value.text.contains("第2489章"), "应含 last_chapter_title，实际=\(e.value.text)")
    }

    /// ⭐⭐⭐⭐⭐ **多占位符（用 `•` 隔开）⇒ 必须出值**
    func testMultiPlaceholderWithBullet() {
        let e = eval("{{$.last_chapter_title}} • {{$.last_update_time}}")
        XCTAssertNil(e.diagnostic.failure, "多占位符模板不该失败：\(String(describing: e.diagnostic.failure))")
        XCTAssertTrue(e.value.text.contains("第2489章"), "实际=\(e.value.text)")
        XCTAssertTrue(e.value.text.contains("2024-09-14"), "实际=\(e.value.text)")
    }

    /// ⭐⭐⭐⭐⭐ **多占位符（用换行隔开）⇒ 必须出值**
    func testMultiPlaceholderWithNewlines() {
        let e = eval("{{$.category}}\n{{$.score}}\n{{$.status}}\n{{$.source}}\n{{$.tags}}")
        XCTAssertNil(e.diagnostic.failure, "多占位符模板不该失败：\(String(describing: e.diagnostic.failure))")
        XCTAssertTrue(e.value.text.contains("玄幻"), "实际=\(e.value.text)")
        XCTAssertTrue(e.value.text.contains("番茄"), "实际=\(e.value.text)")
    }

    /// ⭐⭐⭐ **单占位符（对照组）⇒ 仍然正常**（别把现在能用的搞坏）
    func testSinglePlaceholderStillWorks() {
        let e = eval("{{$.book_name}}")
        XCTAssertNil(e.diagnostic.failure)
        XCTAssertTrue(e.value.text.contains("恰似寒光遇骄阳"), "实际=\(e.value.text)")
    }

    /// ⭐⭐⭐ **前缀 + 模板**（`第{{$.n}}章` 这种）⇒ 也是当值返回
    func testPrefixPlusTemplate() {
        let e = eval("第{{$.last_chapter_title}}")
        XCTAssertNil(e.diagnostic.failure, "前缀+模板不该失败：\(String(describing: e.diagnostic.failure))")
        XCTAssertTrue(e.value.text.hasPrefix("第"), "实际=\(e.value.text)")
    }

    /// ⭐⭐⭐⭐⭐ **不能再走「默认规则链」**（那是把渲染结果当选择器查 ⇒ 必失败）
    func testMustNotFallIntoDefaultChain() {
        let e = eval("{{$.source}} {{$.last_chapter_title}}")
        XCTAssertNotEqual(e.diagnostic.branch, "默认规则链",
                          "模板渲染后不该再当选择器查（⇒ baseTypeMismatch）")
    }
}
