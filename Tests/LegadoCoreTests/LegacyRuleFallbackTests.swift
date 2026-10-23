import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **老引擎的「规则兜底」** —— 老引擎有、新引擎原来没有的三条
///
/// ⚠️ **这三条是用「真实源双实现对拍」挖出来的**（2026-10-23）：
///   125 个真源逐个跑，老引擎能出、新引擎报错的那些源，根因全在这三条 ⭐
///
/// | # | 老引擎的兜底 | 少了会怎样 |
/// |---|---|---|
/// | ① | `exploreUrl` 顶层空 ⇒ 试 **`ruleExplore.exploreUrl`** | 「该书源没有发现规则」⇒ 发现页空白 |
/// | ② | 发现页 `ruleExplore.bookList` 空 ⇒ **回退 `ruleSearch`** | 「列表 0 本」⇒ 一本都不出 |
/// | ③ | 搜索**永远**用 `ruleSearch` | （两边一致，仅固化）|
///
/// 依据：老引擎 `engine.js` 的
/// ```js
/// var spec = ruleText(src.exploreUrl) || ruleText(src.ruleExplore && src.ruleExplore.exploreUrl);
/// function pickListRule(src, isSearch) {
///   if (isSearch) return search;
///   if (!ruleText(explore.bookList).trim()) return search;   // ← 回退
///   return explore;
/// }
/// ```
/// （Legado `BookList.kt` 同款语义）
final class LegacyRuleFallbackTests: XCTestCase {

    /// 假传输：按 URL 返回固定响应
    final class FixedTransport: HTTPTransport, @unchecked Sendable {
        private let byURL: [String: String]
        init(_ byURL: [String: String]) { self.byURL = byURL }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            guard let body = byURL[request.url] else {
                throw SourceError.requestFailed(request.url, "测试里没有这个 URL")
            }
            return HTTPResponse(statusCode: 200, headers: [:],
                                body: Data(body.utf8), finalURL: request.url)
        }
    }

    // MARK: - ① exploreUrl 写在规则块里

    /// ⭐⭐⭐ **顶层 `exploreUrl` 空 ⇒ 试 `ruleExplore.exploreUrl`**
    func testExploreKindsFallsBackToRuleExploreExploreUrl() throws {
        let sourceJSON = """
        {"bookSourceName":"兜底源","bookSourceUrl":"https://legacy.example.com",
         "ruleExplore":{"exploreUrl":"玄幻::https://legacy.example.com/fantasy"}}
        """
        let source = try JSONDecoder().decode(BookSource.self, from: Data(sourceJSON.utf8))
        let transport = FixedTransport([:])
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        let (kinds, _) = try engine.exploreKinds()
        XCTAssertEqual(kinds.count, 1, "⭐ 顶层 exploreUrl 空时，要用 ruleExplore.exploreUrl")
        XCTAssertEqual(kinds.first?.title, "玄幻")
        XCTAssertTrue(kinds.first?.url.contains("fantasy") == true)
    }

    /// ⭐ 两处都没有 ⇒ 仍然该报「没有发现规则」（别把兜底做成静默空）
    func testExploreKindsStillFailsWhenNoExploreUrlAnywhere() throws {
        let sourceJSON = """
        {"bookSourceName":"没规则的源","bookSourceUrl":"https://none.example.com"}
        """
        let source = try JSONDecoder().decode(BookSource.self, from: Data(sourceJSON.utf8))
        let engine = SourceEngine(source: source,
                                  fetcher: PageFetcher(transport: FixedTransport([:])))
        XCTAssertThrowsError(try engine.exploreKinds())
    }

    // MARK: - ② 发现页回退 ruleSearch

    /// ⭐⭐⭐ **发现页 `ruleExplore.bookList` 空 ⇒ 回退 `ruleSearch`**
    func testExploreFallsBackToRuleSearchWhenExploreBookListEmpty() throws {
        let listHTML = """
        <html><body>
          <div class="book"><a href="/b/1">书一</a><span>作者一</span></div>
          <div class="book"><a href="/b/2">书二</a><span>作者二</span></div>
        </body></html>
        """
        let sourceJSON = """
        {"bookSourceName":"只有搜索规则的源","bookSourceUrl":"https://legacy.example.com",
         "ruleExplore":{"exploreUrl":"玄幻::https://legacy.example.com/fantasy"},
         "ruleSearch":{"bookList":".book","name":"a@text","author":"span@text","bookUrl":"a@href"}}
        """
        let source = try JSONDecoder().decode(BookSource.self, from: Data(sourceJSON.utf8))
        let transport = FixedTransport(["https://legacy.example.com/fantasy": listHTML])
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))

        let books = try engine.explore("https://legacy.example.com/fantasy")
        XCTAssertEqual(books.count, 2, "⭐ ruleExplore.bookList 空时要回退 ruleSearch")
        XCTAssertEqual(books.first?.name, "书一")
        XCTAssertEqual(books.first?.author, "作者一")
    }

    /// ⭐ 有 bookList 时**用 ruleExplore**（别被兜底抢了）
    func testExplorePrefersRuleExploreWhenBookListPresent() throws {
        let listHTML = """
        <html><body>
          <div class="ex"><a href="/e/1">发现的书</a></div>
          <div class="sr"><a href="/s/1">搜索的书</a></div>
        </body></html>
        """
        let sourceJSON = """
        {"bookSourceName":"两套规则的源","bookSourceUrl":"https://legacy.example.com",
         "ruleExplore":{"exploreUrl":"玄幻::https://legacy.example.com/fantasy",
                       "bookList":".ex","name":"a@text","bookUrl":"a@href"},
         "ruleSearch":{"bookList":".sr","name":"a@text","bookUrl":"a@href"}}
        """
        let source = try JSONDecoder().decode(BookSource.self, from: Data(sourceJSON.utf8))
        let transport = FixedTransport(["https://legacy.example.com/fantasy": listHTML])
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        let books = try engine.explore("https://legacy.example.com/fantasy")
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "发现的书", "有 bookList 时要用 ruleExplore")
    }
}
