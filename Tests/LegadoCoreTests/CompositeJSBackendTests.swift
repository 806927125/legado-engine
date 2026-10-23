import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **复合形态「路径 + 尾部 `<js>` 块」的求值门禁**（§S-CMP-06）
///
/// 站方真实写法（125 源里 4 处）：
/// ```
/// $.data.chapterList[0].volumeList<js>java.put(...);result</js>
/// $.uptime<js>java.getString('$.last_chapter_name')+' '+…</js>
/// $.chapterArticle\n<js>doc=org.jsoup.Jsoup.parse(result)…</js>
/// ```
///
/// ⚠️⚠️ **门禁要点**：主体结果是 **数组 / 对象** 时，JS 里的 `result` 必须**保持结构**。
/// ⇒ 以前的实现把主体压成 `value.text` ⇒ **对象/数组的 `scalarString` 是空串**
/// ⇒ JS 里 `result` = `""` ⇒ 站方 `result.map(...)` / `result.book_id` 全废
/// ⇒ 这就是「解析层做了、求值层没做」的真身。
///
/// ⭐ 这份门禁**不需要 JSC**（用捕获基准的假执行器）⇒ Linux 沙盒也能跑。
final class CompositeJSBackendTests: XCTestCase {

    /// 捕获基准的假 JS 执行器（只看引擎传了什么下去）
    final class CapturingJS: JSExecutor, @unchecked Sendable {
        var captured: RuleBase?
        func run(_ code: String, context: JSRunContext) throws -> JSONValue {
            captured = context.base
            return .string("<ok>")
        }
    }

    /// 跑一条复合形态规则，返回 JS 执行器看到的基准
    private func capture(_ rule: String, base: RuleBase) throws -> RuleBase {
        let js = CapturingJS()
        let ev = Evaluator(js: js)
        let ctx = EvalContext(base: base, isJSON: true)
        _ = ev.evalOne(rule, base: base, ctx: ctx)
        return try XCTUnwrap(js.captured, "JS 执行器没被调用 ⇒ 规则没走到 JS 分支")
    }

    // MARK: - 主体是【数组】

    /// ⭐⭐ **数组主体 ⇒ `result` 必须是数组**（站方 `result.map(...)` 的前提）
    func testArraySubjectKeepsArrayType() throws {
        let json: JSONValue = .object([
            "data": .object([
                "list": .array([.object(["n": .string("a")]), .object(["n": .string("b")])]),
            ]),
        ])
        let got = try capture("$.data.list<js>result.map(function(x){return x.n}).join(',')</js>",
                             base: .json(json))
        guard case .json(let j) = got else {
            return XCTFail("⭐ 数组主体被压成了非 JSON 基准：\(got) ⇒ JS 里 result 是字符串 ⇒ result.map 炸")
        }
        guard case .array(let arr) = j, arr.count == 2 else {
            return XCTFail("主体数组丢了结构：\(j)")
        }
        // ⚠️ `scalarString` 对**对象**是空串 ⇒ 必须取键
        guard case .object(let o0) = arr[0], case .object(let o1) = arr[1] else {
            return XCTFail("数组元素不是对象：\(arr)")
        }
        XCTAssertEqual(o0["n"]?.scalarString, "a")
        XCTAssertEqual(o1["n"]?.scalarString, "b")
    }

    // MARK: - 主体是【对象】

    /// ⭐⭐ **对象主体 ⇒ `result` 必须是对象**（站方 `result.book_id` 的前提）
    func testObjectSubjectKeepsObjectType() throws {
        let json: JSONValue = .object([
            "book": .object(["book_id": .string("MTgzNTEy"), "tab": .string("小说")]),
        ])
        let got = try capture("$.book<js>result.book_id</js>", base: .json(json))
        guard case .json(let j) = got else {
            return XCTFail("⭐ 对象主体被压成了非 JSON 基准：\(got) ⇒ JS 里 result 是字符串 ⇒ result.book_id 得 undefined")
        }
        guard case .object(let obj) = j else {
            return XCTFail("主体对象丢了结构：\(j)")
        }
        XCTAssertEqual(obj["book_id"]?.scalarString, "MTgzNTEy")
    }

    // MARK: - 主体是【字符串】

    /// 字符串主体 ⇒ `result` 是字符串（**别把字符串也变成 JSON 串**）
    func testStringSubjectStaysString() throws {
        let json: JSONValue = .object(["uptime": .string("2024-01-01")])
        let got = try capture("$.uptime<js>result + '!'</js>", base: .json(json))
        // ⭐ 断言的是「**JS 看到的 result**」（`RuleBase.resultValue`）⇒ 与基准用哪个 case 无关
        let seen = got.resultValue
        XCTAssertEqual(seen.jsonValue.scalarString, "2024-01-01",
                       "⭐ JS 里的 result 应当是那个字符串，实际：\(seen)")
    }

    // MARK: - 主体是【节点列表】

    /// 节点列表 ⇒ 数组，每个元素是「属性 + `_text`」
    func testNodeListSubjectBecomesArrayOfNodes() throws {
        let html = "<div class=\"a\" id=\"x\">文本甲</div><div class=\"a\" id=\"y\">文本乙</div>"
        let doc = try SwiftSoupDocument(html: html, baseURL: "https://x.example/").document
        let ev = Evaluator(js: CapturingJS())
        let ctx = EvalContext(base: .page(html), raw: html, document: doc)
        let e = ev.evalOne("tag.div@id<js>result.map(function(n){return n._text}).join('|')</js>",
                           base: .page(html), ctx: ctx)
        // 节点列表的主体 ⇒ 数组 ⇒ JS 里 result 是数组 ⇒ 站方能 .map
        XCTAssertNotEqual(e.diagnostic.failure?.isHardFailure, true,
                          "节点列表 + 尾部 JS 应当走通，实际诊断：\(String(describing: e.diagnostic.failure))")
    }

    // MARK: - 基准类型不影响【页面级】的既有语义（防回归）

    /// ⚠️ **页面级 `result` 仍然是页原文**（§S-RES-01）—— 别被本次改动带歪
    func testPageLevelResultIsStillRawPage() throws {
        let js = CapturingJS()
        let ev = Evaluator(js: js)
        let html = "<html>页原文</html>"
        let ctx = EvalContext(base: .page(html), raw: html)
        _ = ev.evalOne("<js>result</js>", base: .page(html), ctx: ctx)
        let got = try XCTUnwrap(js.captured)
        XCTAssertEqual(got.resultValue.text, html, "页面级 result 必须是页原文")
    }
}
