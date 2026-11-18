import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **Sextant 兜底门禁**（2026-11-18 · 搬栖阅/柴阅同款 JSONPath 引擎）
///
/// 背景：栖阅 / 柴阅的引擎用 **KittyMac/Sextant**（MIT）⇒ 它们的 JSONPath 与
/// `[?(@.a=='b')]` 过滤表达式是**完整版**；而本引擎手写的 `JSONFilter` 是**子集**
/// ⇒ 站方写了子集外的表达式 ⇒ **整条路径作废** ⇒ 字段全空（症状离根因极远）。
///
/// 修法：**手写优先（行为不变）⇒ 解析不了 / 带过滤表达式却算空 ⇒ 用 Sextant 兜底**。
///
/// ⚠️ 本门禁要同时钉住两件相反的事：
///   ① 兜底**不能**改变「手写能解析的路径」的结果（否则就是回归）
///   ② 兜底**必须**在「手写解析不了」时把值救回来（否则这层白加）
final class SextantFallbackTests: XCTestCase {

    /// ⭐ 真实语料形态：站方的 JSON 接口 + 过滤表达式
    private let doc: JSONValue = JSONValue(json: """
    {"code":0,"data":{"state":[{"dataName":"novel_search_list","items":[{"n":"书一","w":10},{"n":"书二","w":20}]},
                             {"dataName":"other_list","items":[{"n":"别的"}]}]}}
    """)

    // MARK: - ① 手写能解析的路径 ⇒ 结果**不许**被兜底改写

    func testPlainPathUnchanged() {
        let hits = JSONPath.select(doc, "$.data.state[0].items[0].n")
        XCTAssertEqual(hits?.count, 1)
        XCTAssertEqual(hits?.first?.scalarString, "书一")
    }

    func testPlainPathMissStaysEmpty() {
        // ⭐ 纯路径没命中 ⇒ **必须仍然是空**（兜底只对「带过滤表达式」的路径生效）
        let hits = JSONPath.select(doc, "$.data.state[9].items")
        XCTAssertTrue(hits?.isEmpty ?? true, "没命中的纯路径不许被兜底改出值")
    }

    // MARK: - ② 手写解析不了的过滤表达式 ⇒ Sextant 兜底救回来

    func testSextantFallbackRecoversFilterExpression() {
        // ⭐⭐⭐ 这条是栖阅书源的真实写法（`[?(@.dataName=='…')]` 里带单引号 + 深层路径）
        //   ⇒ 手写子集解析不了 ⇒ 之前 = 空 ⇒ 现在要被救回来 ⭐
        // ⚠️ 先断言「手写确实解析不了」⇒ 否则这条测的不是兜底（而是手写路径）⇒ 门禁会变成平凡通过 ⭐⭐⭐
        XCTAssertNil(JSONPath.parse("$.data.state[?(@.dataName=='novel_search_list')].items[*].n"),
                     "这条路径手写应该解析不了（若能解析 ⇒ 这条测的不是兜底）")
        let hits = JSONPath.select(doc, "$.data.state[?(@.dataName=='novel_search_list')].items[*].n")
        XCTAssertEqual(hits?.count, 2, "Sextant 兜底应命中 2 项，实际 \(hits?.count ?? -1)")
        XCTAssertEqual(hits?.first?.scalarString, "书一")
        XCTAssertEqual(hits?.last?.scalarString, "书二")
    }

    func testSextantFallbackOnUnsupportedExpression() {
        // ⭐ 手写子集里没有的运算符（`=~` 正则 + `in` 集合）
        let hits = JSONPath.select(doc, "$.data.state[?(@.dataName =~ /novel.*/)].items[0].n")
        XCTAssertEqual(hits?.count, 1)
        XCTAssertEqual(hits?.first?.scalarString, "书一")
    }

    // MARK: - ③ Sextant 本体可用（兜底不是摆设）

    func testSextantDirectQuery() {
        let hits = SextantFallback.select(doc, "$.data.state[*].dataName")
        XCTAssertEqual(hits?.count, 2)
        XCTAssertEqual(hits?.last?.scalarString, "other_list")
    }

    func testSextantValidatePath() {
        XCTAssertNil(SextantFallback.validate("$.a.b"), "合法路径不该报错")
        XCTAssertNotNil(SextantFallback.validate("$.a[["), "非法路径要报错")
    }

    // MARK: - ④ 兜底**不是**万能：Sextant 也不认的路径 ⇒ 仍然是 nil（不编值）

    func testUnknownPathStillNil() {
        XCTAssertNil(JSONPath.select(doc, "$$$.not.a.path"),
                     "两边都不认的路径不许编出值")
    }
}
