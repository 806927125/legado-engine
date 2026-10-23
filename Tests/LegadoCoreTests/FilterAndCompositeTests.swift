import Foundation
import XCTest
@testable import LegadoCore

/// **JSONPath 过滤表达式 + 复合形态**门禁
/// （125 源体检量出来的两类缺口：filter 1 处 / 路径+`<js>`块 4 处）
final class FilterAndCompositeTests: XCTestCase {

    private func evalJSON(_ rule: String, _ json: String) -> String {
        let ev = Evaluator()
        var ctx = EvalContext(base: .json(JSONValue(json: json)), baseUrl: "https://x.example/")
        ctx.isJSON = true
        return ev.evalOne(rule, base: ctx.base, ctx: ctx).value.text
    }

    // MARK: - ① 过滤表达式

    /// ⭐ **真书源那条规则逐字**（QB女生<kd♛ / ruleSearch.bookList）
    func testFilterFromRealBookSource() {
        let json = """
        {"data":{"state":[
          {"dataName":"other_list","items":[{"t":"不该被选中"}]},
          {"dataName":"novel_search_list","items":[{"t":"甲"},{"t":"乙"}]},
          {"dataName":"third","items":[{"t":"不该被选中"}]}
        ]}}
        """
        let out = evalJSON("$.data.state[?(@.dataName == 'novel_search_list')].items[*].t", json)
        XCTAssertTrue(out.contains("甲"), "应命中：\(out)")
        XCTAssertTrue(out.contains("乙"), "应命中：\(out)")
        XCTAssertFalse(out.contains("不该被选中"), "不该被选中：\(out)")
    }

    /// 比较运算符全集
    func testFilterComparisonOperators() {
        let json = """
        {"items":[
          {"n":1,"s":"a"},{"n":2,"s":"b"},{"n":3,"s":"c"}
        ]}
        """
        XCTAssertTrue(evalJSON("$.items[?(@.n > 1)].s", json).contains("b"))
        XCTAssertFalse(evalJSON("$.items[?(@.n > 1)].s", json).contains("a"))
        XCTAssertTrue(evalJSON("$.items[?(@.n >= 2)].s", json).contains("c"))
        XCTAssertTrue(evalJSON("$.items[?(@.s != 'a')].s", json).contains("b"))
        XCTAssertTrue(evalJSON("$.items[?(@.s == 'a' || @.n == 3)].s", json).contains("c"))
        XCTAssertTrue(evalJSON("$.items[?(@.n > 1 && @.n < 3)].s", json).contains("b"))
        XCTAssertTrue(evalJSON("$.items[?(@.n == 1)].s", json).contains("a"))
        // ⚠️ 排除项也要**真能排除**（否则是平凡通过）⇒ 明确断言
        XCTAssertFalse(evalJSON("$.items[?(@.n == 1)].s", json).contains("b"))
    }

    /// ⭐ **严格相等 `===` 要类型也相同**（栖阅 Sextant 明确区分 ⇒ `1 !== '1'`）
    func testStrictEqualityDistinguishesTypes() {
        // ⚠️ 数字 1 和字符串 "1" 的 `text` **都是 "1"** ⇒ 断言要用能区分的值
        let json = #"{"items":[{"v":1,"tag":"num"},{"v":"1","tag":"str"}]}"#
        let nums = evalJSON("$.items[?(@.v === 1)].tag", json)
        XCTAssertTrue(nums.contains("num"), "数字 1 应命中：\(nums)")
        XCTAssertFalse(nums.contains("str"), "字符串 '1' 不该被 `=== 1` 命中：\(nums)")
    }

    /// 正则 `=~`（模式在左或右都行）
    func testFilterRegex() {
        let json = #"{"items":[{"s":"abc"},{"s":"xyz"}]}"#
        XCTAssertTrue(evalJSON("$.items[?(@.s =~ '^a')].s", json).contains("abc"))
    }

    /// 集合 `in`
    func testFilterIn() {
        let json = #"{"items":[{"k":"a"},{"k":"z"}]}"#
        XCTAssertTrue(evalJSON("$.items[?(@.k in ['a','b'])].k", json).contains("a"))
        XCTAssertFalse(evalJSON("$.items[?(@.k in ['a','b'])].k", json).contains("z"))
    }

    // MARK: - ② 「路径 + 尾部 `<js>` 块」复合形态

    /// ⭐ 站方形态：路径求值后，结果作为 `result` 喂给 JS
    func testPathWithTrailingJSBlockParses() {
        let ev = Evaluator()
        var ctx = EvalContext(base: .json(JSONValue(json: "{\"a\":1}")), baseUrl: "https://x.example/")
        ctx.isJSON = true
        let ast = ev.parser.parse("$.a<js>result + 1</js>", isJSON: true)
        // 形态必须是「post(主体, js)」而不是「整串 JSONPath」
        if case .post(let inner, let post) = ast {
            // ⭐⭐ **必须断言 code 的内容** —— 旧实现 code 是**空串**也过（平凡通过）
            // ⇒ 那正是这个 bug 长期没被门禁抓到的原因
            guard case .jsWithTail(let code, let tail) = post else {
                return XCTFail("尾部应是 .jsWithTail 后处理，实际：\(post)")
            }
            XCTAssertEqual(code.trimmingCharacters(in: .whitespaces), "result + 1")
            XCTAssertNil(tail)
            // 主体 = 纯路径（`$.a`），不能把 JS 代码留在主体里
            guard case .jsonPath(let path) = inner else {
                return XCTFail("主体应是 .jsonPath，实际：\(inner)")
            }
            XCTAssertEqual(path, "$.a")
            return
        } else {
            XCTFail("应解析成 .post(主体, .jsWithTail)，实际：\(ast)")
        }
    }

    /// 换行分隔的形态（真书源里也有）
    func testPathWithNewlineJSBlockParses() {
        let ev = Evaluator()
        var ctx = EvalContext(base: .json(JSONValue(json: "{}")), baseUrl: "https://x.example/")
        ctx.isJSON = true
        let ast = ev.parser.parse("$.a\n<js>\nresult\n</js>", isJSON: true)
        if case .post = ast { return }
        XCTFail("换行形态也应解析成 .post，实际：\(ast)")
    }
}
