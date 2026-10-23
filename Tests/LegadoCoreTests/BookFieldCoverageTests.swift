import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **书/章节字段覆盖门禁** —— `wordCount` / `isVip`
///
/// **125 源实测**：
/// - `wordCount`（字数）：ruleSearch 38 / ruleExplore 29 / ruleBookInfo 44 ⇒ **111 处**
/// - `isVip`（付费章节）：ruleToc **9 处**
///
/// ⚠️ 以前**模型里有字段、编排层一次都没求值** ⇒ 字数恒空、付费标记恒 false。
final class BookFieldCoverageTests: XCTestCase {

    final class MemTransport: HTTPTransport, @unchecked Sendable {
        private let body: String
        init(body: String) { self.body = body }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8), finalURL: request.url)
        }
    }

    private func makeEngine(_ json: [String: Any]) throws -> SourceEngine {
        var src: [String: Any] = [
            "bookSourceName": "字段源",
            "bookSourceUrl": "https://example.test",
            "ruleSearch": ["name": "tag.a@text", "bookUrl": "tag.a@href",
                           "bookList": "div.row", "wordCount": "span.w@text"],
            "ruleBookInfo": ["name": "tag.h1@text", "intro": "tag.p@text",
                             "wordCount": "span.w@text"],
            "ruleToc": ["chapterList": "tag.li", "chapterName": "tag.a@text",
                        "chapterUrl": "tag.a@href", "isVip": "span.vip@text"],
        ]
        for (k, v) in json { src[k] = v }
        let data = try JSONSerialization.data(withJSONObject: src)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        let transport = MemTransport(body: """
        <html><body>
          <div class="row"><a href="/b/1">书名一</a><span class="w">12.3万字</span></div>
          <h1>详情书名</h1><p>简介</p><span class="w">12.3万字</span>
          <ul><li><a href="/c/1">第一章</a><span class="vip">VIP</span></li>
              <li><a href="/c/2">第二章</a></li></ul>
        </body></html>
        """)
        return SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
    }

    // MARK: - ① 字数

    /// ⭐ **列表里的字数**（38 个源）
    func testWordCountInSearchResults() throws {
        let engine = try makeEngine(["searchUrl": "https://example.test/s?k={{key}}"])
        let books = try engine.search("书")
        XCTAssertFalse(books.isEmpty, "应有搜索结果")
        XCTAssertEqual(books.first?.wordCount, "12.3万字", "⭐ 列表字数不该是空")
    }

    /// ⭐ **详情页的字数**（44 个源）
    func testWordCountInBookInfo() throws {
        let engine = try makeEngine([:])
        var book = Book()
        book.bookUrl = "https://example.test/b/1"
        let info = try engine.bookInfo(book)
        XCTAssertEqual(info.wordCount, "12.3万字", "⭐ 详情字数不该是空")
    }

    // MARK: - ② 付费章节

    /// ⭐ **`isVip` 规则**（9 个源）—— 命中的那个章节是 VIP
    func testIsVipFlag() throws {
        let engine = try makeEngine([:])
        var info = BookInfo()
        info.bookUrl = "https://example.test/b/1"
        let chapters = try engine.toc(info)
        XCTAssertEqual(chapters.count, 2, "应有两章")
        XCTAssertTrue(chapters[0].isVip, "⭐ 第一章带 VIP 标记")
        XCTAssertFalse(chapters[1].isVip, "第二章不该是 VIP")
    }

    // MARK: - ③ 没给规则时不该瞎标（防回归）

    func testNoRuleMeansNoVip() throws {
        var src: [String: Any] = [
            "bookSourceName": "无标记源",
            "bookSourceUrl": "https://example.test",
            "ruleToc": ["chapterList": "tag.li", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href"],
        ]
        let data = try JSONSerialization.data(withJSONObject: src)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        let transport = MemTransport(body: """
        <html><body><ul><li><a href="/c/1">第一章</a><span class="vip">VIP</span></li></ul></body></html>
        """)
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        var info = BookInfo()
        info.bookUrl = "https://example.test/b/1"
        let chapters = try engine.toc(info)
        XCTAssertFalse(chapters.first?.isVip ?? true, "没给 isVip 规则 ⇒ 不该标 VIP")
    }
}
