import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **详情页的「分组 / 类型 / 更新」三格必须拿到站方真值**
/// （2026-10-25 真机 build253 实证）
///
/// **症状**：App 详情页三格显示「未分组 / 文本 / 未加载」
/// ⇒ 引擎**根本没跑出**站方的 `group` / `lastChapter` ⭐⭐⭐
///
/// **两个根因**：
/// ① **多占位符模板失败**（`{{$.source}} {{$.last_chapter_title}} {{$.last_chapter_update_time}}`）
///    ⇒ 渲染后继续当选择器查 ⇒ `baseTypeMismatch(expected:"DOM", actual:"JSON")` ⇒ **失败** ⭐⭐⭐
///    ⇒ 修法见 `MultiPlaceholderTemplateTests`
/// ② **引擎不认站方的分组 key**（站方给 `category`）⇒ `BookInfo` 压根没这个字段 ⇒ 永远空 ⭐⭐⭐
///    ⇒ 修法：加 `group` / `category` 两个 key + `BookInfo.group`
final class BookDetailMetaFieldsTests: XCTestCase {

    /// ⭐⭐⭐⭐⭐ **站方（🍅大灰狼）真实形状的 ruleBookInfo**（从 JSON 构造 ⇒ 最接近真机）
    private func makeSource(groupKey: String) throws -> BookSource {
        var ruleBookInfo: [String: Any] = [
            // ⭐⭐⭐ **init 规则**（真机日志里站方有 ⇒ 基准从「页原文」变成「JSON 对象」）
            //   ⚠️ 没有 init ⇒ 基准是**页原文** ⇒ `$.xxx` 取不到 ⇒ 字段全空 ⭐⭐⭐
            "init": "$.data",
            "name": "$.book_name",
            "author": "$.author",
            // ⭐ 站方那条**多占位符**的 lastChapter（真机日志里失败的那条）
            "lastChapter": "{{$.source}} {{$.last_chapter_title}} {{$.last_chapter_update_time}}",
            "wordCount": "$.word_number",
        ]
        // ⭐ 站方的分组字段（**多占位符模板**）
        switch groupKey {
        case "category":
            ruleBookInfo["category"] =
                "{{$.category}}\n{{$.score}}\n{{$.status}}\n{{$.source}}\n{{$.tags}}"
        default:
            ruleBookInfo["group"] = "{{$.category}}"
        }
        let raw: [String: Any] = [
            "bookSourceUrl": "https://v5.langge.uk",
            "bookSourceName": "大灰狼融合VIP5.0",
            "ruleBookInfo": ruleBookInfo,
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(BookSource.self, from: data)
    }

    /// ⭐⭐⭐ **详情 JSON 基准**（站方 `/detail` 返回的形状）
    private func detailJSON() -> String {
        """
        {"code":0,"msg":"ok","data":
        {"book_id":"76549393572","source":"番茄","tab":"小说",
         "book_name":"恰似寒光遇骄阳","author":"囡囡有妖",
         "category":"玄幻","score":9.1,"status":"连载中","tags":"都市,爽文",
         "last_chapter_title":"第2489章 独家新番外上线",
         "last_chapter_update_time":"2024-09-14 09:45:27",
         "last_update_time":"2024-09-14 09:45:27",
         "word_number":"2611270"}}
        """
    }

    /// ⭐⭐⭐ **内存传输**（照抄 `BookFieldCoverageTests` 的现成实现）
    final class MemTransport: HTTPTransport, @unchecked Sendable {
        private let body: String
        init(body: String) { self.body = body }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8), finalURL: request.url)
        }
    }

    private func bookInfo(_ src: BookSource) throws -> BookInfo {
        let transport = MemTransport(body: detailJSON())
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: transport))
        var b = Book()
        b.bookUrl = "https://v5.langge.uk/detail"
        return try engine.bookInfo(b)
    }

    /// ⭐⭐⭐⭐⭐ **多占位符的 `lastChapter` 必须出值**（真机日志里失败的那条）
    func testLastChapterFromMultiPlaceholderTemplate() throws {
        let info = try bookInfo(try makeSource(groupKey: "group"))
        XCTAssertFalse(info.lastChapter.isEmpty, "lastChapter 不该是空的")
        XCTAssertTrue(info.lastChapter.contains("番茄"), "实际=\(info.lastChapter)")
        XCTAssertTrue(info.lastChapter.contains("第2489章"), "实际=\(info.lastChapter)")
    }

    /// ⭐⭐⭐⭐⭐ **站方 `category` 那个 key 必须能填出「分组」**
    func testGroupFromCategoryKey() throws {
        let info = try bookInfo(try makeSource(groupKey: "category"))
        XCTAssertFalse(info.group.isEmpty, "group 不该是空的（站方给的是 category key）")
        XCTAssertTrue(info.group.contains("玄幻"), "实际=\(info.group)")
    }

    /// ⭐⭐⭐ **站方 `group` 那个 key 也能填**
    func testGroupFromGroupKey() throws {
        let info = try bookInfo(try makeSource(groupKey: "group"))
        XCTAssertTrue(info.group.contains("玄幻"), "实际=\(info.group)")
    }

    /// ⭐⭐⭐ **书名/作者/字数照旧正常**（别把现在能用的搞坏）
    func testOtherFieldsStillWork() throws {
        let info = try bookInfo(try makeSource(groupKey: "group"))
        XCTAssertTrue(info.name.contains("恰似寒光遇骄阳"), "实际=\(info.name)")
        XCTAssertTrue(info.author.contains("囡囡有妖"), "实际=\(info.author)")
        XCTAssertTrue(info.wordCount.contains("2611270"), "实际=\(info.wordCount)")
    }
}
