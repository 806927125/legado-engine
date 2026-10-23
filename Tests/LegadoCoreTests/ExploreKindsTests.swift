import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **发现页分类解析门禁**（站方真实形态）
///
/// **站方 `exploreUrl` 的三种形态**（125 源实测 + 活体验证暴露）：
/// ① 静态 JSON 数组 ② 静态纯文本 `标题::URL` ③ **JS**（`@js:` / `<js>…</js>`）
///
/// **分组语义**（栖阅契约 · 轻阅 `normalizeKinds`）：
/// - 字符串项**没有 `::`** ⇒ **组标题**（装饰符号剥掉）⇒ 后面项归它
/// - 字符串项**有 `::`** ⇒ `标题::URL` ⇒ 分类
/// - 对象项 `type == "select"` ⇒ **筛选栏**（不是分类！没有 url ⇒ 点不动）
final class ExploreKindsTests: XCTestCase {

    // MARK: - ① 组标题（栖阅契约）

    /// ⭐⭐ **没有 `::` 的行 = 组标题** ⇒ 后面项归它（不是分类）
    func testGroupTitleIsNotACategory() {
        let raw = """
        ☆排行榜☆
        玄幻::/type/xh
        仙侠::/type/xx
        """
        let r = SourceEngine.splitExploreItems(SourceEngine.exploreItems(from: .string(raw)),
                                                base: "https://x.example")
        XCTAssertEqual(r.kinds.count, 2, "⭐ 组标题不该算成分类")
        XCTAssertEqual(r.kinds[0].title, "玄幻")
        XCTAssertEqual(r.kinds[0].group, "排行榜", "⭐ 装饰符号要剥掉")
        XCTAssertEqual(r.kinds[1].group, "排行榜")
    }

    // MARK: - ② 筛选栏（type:select）

    /// ⭐⭐ **`type:"select"` 是筛选栏，不是分类**（站方大灰狼）
    func testSelectItemBecomesFilterNotCategory() {
        let raw = """
        [{"title":"平台","type":"select","chars":["番茄","七猫"],"action":"show(infoMap['平台'],'find_source')"},
         {"title":"推荐","url":"/list/recommend"}]
        """
        let r = SourceEngine.splitExploreItems(SourceEngine.exploreItems(from: .string(raw)),
                                                base: "https://x.example")
        XCTAssertEqual(r.kinds.count, 1, "⭐ 筛选栏不该混进分类")
        XCTAssertEqual(r.kinds[0].title, "推荐")
        XCTAssertEqual(r.filters.count, 1, "⭐ 筛选栏要单独分流")
        XCTAssertEqual(r.filters[0].title, "平台")
        XCTAssertEqual(r.filters[0].chars, ["番茄", "七猫"])
        XCTAssertEqual(r.filters[0].action, "show(infoMap['平台'],'find_source')")
    }

    // MARK: - ③ `&&` 也是分隔符（轻阅口径）

    /// ⭐ **`&&` 和换行都是分隔符**
    func testAmpersandIsAlsoSeparator() {
        let parts = SourceEngine.splitPlainKinds("玄幻::/a&&仙侠::/b\n武侠::/c")
        XCTAssertEqual(parts, ["玄幻::/a", "仙侠::/b", "武侠::/c"])
    }

    // MARK: - ④ ⭐ 容错 JSON（站方 JSON 里有裸换行）

    /// ⭐⭐ **站方的 `exploreUrl` 里 `@js:` 后常有真换行 ⇒ 不是合法 JSON**
    func testLenientJSONHandlesRawNewlineInsideString() {
        let raw = "[{\"title\":\"推荐\",\"url\":\"@js: time=Date.now();\nt=\\\"x\\\"\"}]"
        // ⚠️ 上面这个是转义过的（合法 JSON）⇒ 再造一个**裸换行**的
        let raw2 = "[{\"title\":\"推荐\",\"url\":\"@js: time=1;\nnext();\"}]"
        XCTAssertNil(try? JSONSerialization.jsonObject(with: Data(raw2.utf8)),
                     "（前提）裸换行 ⇒ 不是合法 JSON")
        let obj = SourceEngine.lenientJSONObject(raw2)
        XCTAssertNotNil(obj, "⭐ 容错解析要能救回来")
        let arr = obj as? [[String: Any]]
        XCTAssertEqual(arr?.first?["title"] as? String, "推荐")
        XCTAssertTrue((arr?.first?["url"] as? String ?? "").contains("\n"),
                      "⭐ 裸换行要保住在字符串里")
    }

    // MARK: - ⑤ 分类项 url 是 `@js:`（要 JS 后端 ⇒ 沙盒只能验「识别出来了」）

    /// ⭐ **分类项的 url 是 `@js:` ⇒ 引擎要能识别出来**（沙盒无 JSC ⇒ 只能验到这层）
    func testJSCategoryURLIsRecognized() {
        let raw = "[{\"title\":\"推荐\",\"url\":\"@js: 'https://x.example/a'\"}]"
        let r = SourceEngine.splitExploreItems(SourceEngine.exploreItems(from: .string(raw)),
                                                base: "https://x.example")
        XCTAssertEqual(r.kinds.count, 1)
        XCTAssertTrue(r.kinds[0].url.hasPrefix("@js:"),
                      "⭐ @js: 分类 URL 要原样保留（后面由 JS 后端求值）")
    }
}
