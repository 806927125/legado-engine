import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **模板算术门禁**（`{{page-1}}` / `{{page+1}}` / `{{(page-1)*30}}`）
///
/// **125 源实测**：`exploreUrl` 里 **12 个源**用 `{{page-1}}`、**1 个**用 `{{page+1}}`
/// ⇒ 以前求值失败 ⇒ 返回**空串** ⇒ URL 拼成 `…page=` ⇒ **发现页翻页挂掉**。
///
/// ⚠️ 这份门禁**自己构造输入** ⇒ 坏实现必然红。
final class TemplateArithmeticTests: XCTestCase {

    private func render(_ text: String, page: Int) -> String {
        var ctx = EvalContext(base: .page(""), baseUrl: "https://x.example/")
        ctx.page = page
        return TemplateEngine.render(text, ctx: ctx)
    }

    // MARK: - ① 基本加减

    func testPageMinusOne() {
        XCTAssertEqual(render("{{page-1}}", page: 1), "0")
        XCTAssertEqual(render("{{page-1}}", page: 2), "1")
        XCTAssertEqual(render("{{page-1}}", page: 5), "4")
    }

    func testPagePlusOne() {
        XCTAssertEqual(render("{{page+1}}", page: 1), "2")
        XCTAssertEqual(render("{{page+1}}", page: 7), "8")
    }

    // MARK: - ② 括号与乘法

    /// ⭐ 站方还写 `{{(page-1)*30}}` 这种（offset × 每页条数）
    func testParenthesisedArithmetic() {
        XCTAssertEqual(render("{{(page-1)*30}}", page: 1), "0")
        XCTAssertEqual(render("{{(page-1)*30}}", page: 2), "30")
        XCTAssertEqual(render("{{(page-1)*30}}", page: 4), "90")
    }

    // MARK: - ③ 纯变量不受影响（防回归）

    func testPlainPageStillWorks() {
        XCTAssertEqual(render("{{page}}", page: 3), "3")
        XCTAssertEqual(render("{{key}}", page: 1), "")   // key 没设 ⇒ 空
    }

    // MARK: - ④ 整条 URL 渲染

    /// ⭐ **真形态**：站方 `exploreUrl = "https://x/list?start={{(page-1)*30}}&p={{page}}"`
    func testWholeURLRender() {
        XCTAssertEqual(
            render("https://x.example/list?start={{(page-1)*30}}&p={{page}}", page: 3),
            "https://x.example/list?start=60&p=3")
    }

    // MARK: - ⑤ 非算术仍返回空串（不乱猜）

    /// ⚠️ 认不出来的表达式 ⇒ **空串**（不能瞎算出一个数来）
    func testNonArithmeticStillEmpty() {
        XCTAssertEqual(render("{{nonsense}}", page: 1), "")
        XCTAssertEqual(render("{{page-}}", page: 1), "")
        XCTAssertEqual(render("{{1/0}}", page: 1), "")   // 除零 ⇒ 失败
    }

    // MARK: - ⑥ 算术求值器本身

    func testArithmeticEvaluator() {
        XCTAssertEqual(Arithmetic.evaluate("1+2", vars: [:]), "3")
        XCTAssertEqual(Arithmetic.evaluate("2*3+4", vars: [:]), "10")
        XCTAssertEqual(Arithmetic.evaluate("2+3*4", vars: [:]), "14")      // 优先级
        XCTAssertEqual(Arithmetic.evaluate("(2+3)*4", vars: [:]), "20")
        XCTAssertEqual(Arithmetic.evaluate("page-1", vars: ["page": 3]), "2")
        XCTAssertEqual(Arithmetic.evaluate("page-1", vars: [:]), nil)       // 变量不存在 ⇒ 失败
        XCTAssertEqual(Arithmetic.evaluate("1/0", vars: [:]), nil)         // 除零 ⇒ 失败
        XCTAssertEqual(Arithmetic.evaluate("1+", vars: [:]), nil)          // 不完整 ⇒ 失败
        XCTAssertEqual(Arithmetic.evaluate("2+3x", vars: [:]), nil)        // 尾部有多余 ⇒ 失败
    }
}
