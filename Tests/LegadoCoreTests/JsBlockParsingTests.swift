import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **`<js>` 块的解析门禁** —— 沙盒可跑（解析器是跨平台的）
///
/// ⚠️⚠️⚠️ **2026-10-24 真机栽的（而且栽了整整两轮都没抓到）**：
///   症状：🍅大灰狼的 `ruleExplore.bookUrl`（一段 `<js>…</js>`）算出来**是空的**
///   ⇒ 详情 `bookUrl 为空` / 目录 `目录 URL 为空` / 正文没章节 ⇒ **整条链断**
///
///   真根因 = **解析器把整段站方 JS 扔了，只剩 `</js>`**：
///   ```swift
///   for p in ["</js>", "</JS>"] where t.hasSuffix(p) { t = String(t.dropFirst(t.count - p.count)) }
///   //                                                                                   ^^^^^^^^^^^^^
///   //                                                     这是【删前缀、留尾巴】⇒ 留下来了正是 `</js>` ⭐⭐⭐
///   ```
///   ⇒ 喂给 JS 的代码 = `</js>` ⇒ `SyntaxError: Unexpected token '<'`
///   ⇒ **站方的 JS 从来没跑过** ⇒ 分类是兜底的「未分组」、bookUrl 恒空 ⭐
///
/// ⇒ 这条门禁把三件事钉死：
///   ① **纯块**：`<js>代码</js>` ⇒ 代码是**那段代码**（不是 `</js>`）
///   ② **复合块**：`<js>代码</js>$.data` ⇒ 代码 + **尾巴都要在**（大灰狼的 chapterList 就是它）
///   ③ **真书源**：🍅大灰狼的**真规则** ⇒ 解析出来的代码必须**逐字包含站方的 JS**
final class JsBlockParsingTests: XCTestCase {

    // MARK: - ① 纯块

    func testPlainBlockKeepsItsCode() throws {
        let ast = RuleParser(cache: nil).parse("<js>result;</js>", isJSON: true)
        guard case .jsWithTail(let code, let tail) = ast else {
            return XCTFail("⭐ 纯 `<js>` 块应解析成 jsWithTail，实际=\(ast)")
        }
        XCTAssertEqual(code, "result;", "⭐⭐ 块里的代码必须原样留下")
        XCTAssertNil(tail, "⭐ 纯块没有尾巴")
    }

    func testMultiLineBlockKeepsWholeCode() throws {
        let raw = "<js>\nlet a = 1;\n`data:;base64,${a}`\n</js>"
        let ast = RuleParser(cache: nil).parse(raw, isJSON: true)
        guard case .jsWithTail(let code, _) = ast else {
            return XCTFail("⭐ 应解析成 jsWithTail，实际=\(ast)")
        }
        XCTAssertTrue(code.contains("let a = 1;"), "⭐⭐ 代码必须在：\(code)")
        XCTAssertTrue(code.contains("`data:;base64,${a}`"), "⭐⭐ 模板字符串必须在：\(code)")
        XCTAssertFalse(code.contains("<js>"), "⭐ 开头标签要剥掉")
        XCTAssertFalse(code.contains("</js>"), "⭐ 结尾标签要剥掉")
    }

    // MARK: - ② 复合块（`<js>代码</js>$.data`）

    func testCompositeBlockKeepsCodeAndTail() throws {
        let ast = RuleParser(cache: nil).parse("<js>result;</js>$.data", isJSON: true)
        guard case .jsWithTail(let code, let tail) = ast else {
            return XCTFail("⭐ 复合块应解析成 jsWithTail(code, tail)，实际=\(ast)")
        }
        XCTAssertEqual(code, "result;", "⭐⭐ 代码要在")
        XCTAssertEqual(tail, "$.data", "⭐⭐⭐ 尾部也要在（大灰狼的 chapterList 就是它）")
    }

    func testCompositeBlockMultiLine() throws {
        let raw = "<js>\nJSON.parse(result)\n</js>\n$.data"
        let ast = RuleParser(cache: nil).parse(raw, isJSON: true)
        guard case .jsWithTail(let code, let tail) = ast else {
            return XCTFail("⭐ 应解析成 jsWithTail，实际=\(ast)")
        }
        XCTAssertTrue(code.contains("JSON.parse(result)"), "⭐⭐ 代码要在：\(code)")
        XCTAssertEqual(tail, "$.data", "⭐⭐ 尾部要在")
    }

    // MARK: - ③⭐⭐⭐ 真书源（🍅大灰狼的 bookUrl 规则）

    func testRealStationBookUrlRuleParsesToItsCode() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/station")
        let data = try Data(contentsOf: dir.appendingPathComponent("dahulang-rules.json"))
        let rules = try JSONDecoder().decode([String: [String: String]].self, from: data)
        let bookUrl = try XCTUnwrap(rules["ruleExplore"]?["bookUrl"], "⭐ 规则 fixture 里要有 bookUrl")

        let ast = RuleParser(cache: nil).parse(bookUrl, isJSON: true)
        guard case .jsWithTail(let code, let tail) = ast else {
            return XCTFail("⭐⭐ 大灰狼的 bookUrl 应解析成 jsWithTail，实际=\(ast)")
        }
        XCTAssertNil(tail, "⭐ 纯块没有尾巴")
        // ⭐⭐⭐ **站方的 JS 必须逐字在里面**（以前只剩 `</js>` ⇒ 全部丢掉）
        XCTAssertTrue(code.contains("let book_id = result.book_id;"),
                      "⭐⭐⭐ 站方 JS 的第一行必须在：\(code)")
        XCTAssertTrue(code.contains("java.base64Encode(JSON.stringify(qtdetail))"),
                      "⭐⭐⭐ 站方 JS 的 base64 那行必须在：\(code)")
        XCTAssertTrue(code.contains("data:;base64,"),
                      "⭐⭐⭐ 站方 JS 的模板字符串必须在：\(code)")
        XCTAssertFalse(code.contains("<js>"), "⭐ 开头标签要剥掉")
        XCTAssertFalse(code.contains("</js>"), "⭐ 结尾标签要剥掉")
    }

    // MARK: - ④ 大灰狼的 chapterList（复合规则）也要能拆出尾巴

    func testRealStationChapterListKeepsTail() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/station")
        let data = try Data(contentsOf: dir.appendingPathComponent("dahulang-rules.json"))
        let rules = try JSONDecoder().decode([String: [String: String]].self, from: data)
        let chapterList = try XCTUnwrap(rules["ruleToc"]?["chapterList"], "⭐ 规则 fixture 里要有 chapterList")
        let ast = RuleParser(cache: nil).parse(chapterList, isJSON: true)
        guard case .jsWithTail(let code, let tail) = ast else {
            return XCTFail("⭐⭐ 大灰狼的 chapterList 应解析成 jsWithTail，实际=\(ast)")
        }
        XCTAssertTrue(code.contains("java.hexDecodeToString"), "⭐⭐ 代码要在：\(code)")
        XCTAssertNotNil(tail, "⭐⭐⭐ 复合规则的尾巴不能丢（大灰狼的 chapterList 是 `<js>…</js>$.data`）")
    }
}
