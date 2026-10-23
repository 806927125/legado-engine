import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **URL 字段规则** —— 站方把 URL 直接写在 `bookUrl` / `chapterUrl` / `tocUrl` 里
///
/// ⚠️⚠️⚠️ **老引擎也踩这个坑**（轻阅的老债）：
///   站方真实写法：
///     `ruleToc.chapterUrl  = 'https://xs.zzxsa.com/read/@get:{xid}/{{$.num}}?app_name=…'`
///     `ruleBookInfo.bookUrl = '/novel/chapterList?novel_id={{$.novel_id}}'`   ← **以 `/` 开头**
///   ⇒ 规则以 `/` 开头会被**模式判定当成 XPath** ⇒ 查不到 ⇒ **章节 URL / 目录 URL 全空** ⭐
///   ⇒ 实测那批源的目录是 0 章 ⇒ 「老引擎有的、新引擎没有」的**反面**：
///   **新引擎要做得比老引擎好** ⇒ URL 字段按 URL 规则处理 ⭐
///
/// ⭐ 真实语料里 **224 处**规则以 `/` 或 `@XPath:` 开头 ⇒ 绝大多数其实是 URL。
final class URLFieldRuleTests: XCTestCase {

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

    private static let listHTML = """
    <html><body><ul class="list"><li><a href="/c/1">第一章</a></li></ul></body></html>
    """

    private static let listJSON = #"{"code":0,"data":{"books":[{"bookId":"77","bookName":"书"}]}}"#

    // MARK: - ① 绝对 URL 的 chapterUrl

    /// ⭐⭐⭐ **`chapterUrl` 直接写 URL** ⇒ 要能当 URL 规则处理
    func testChapterUrlAsURLRule() throws {
        let sourceJSON = """
        {"bookSourceName":"URL 字段源","bookSourceUrl":"https://legacy.example.com",
         "ruleToc":{"chapterList":"ul.list li a","chapterName":"text",
                    "chapterUrl":"https://cdn.example.com/read/{{$.num}}.html?bid=@get:{bid}"},
         "ruleSearch":{"bookList":"ul.list li a","name":"text"}}
        """
        let source = try JSONDecoder().decode(BookSource.self, from: Data(sourceJSON.utf8))
        let transport = FixedTransport(["https://legacy.example.com/toc": Self.listHTML])
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        var info = BookInfo()
        info.bookUrl = "https://legacy.example.com/toc"
        let chapters = try engine.toc(info)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters.first?.url, "https://cdn.example.com/read/.html?bid=",
                       "⭐ URL 字段要按 URL 规则处理（插值 + 保留原样）")
    }

    // MARK: - ② 相对 URL 的 bookUrl（以 `/` 开头 ⇒ 会被误判成 XPath）

    /// ⭐⭐⭐ **相对 URL 的 `bookUrl`** ⇒ 不是 XPath
    func testRelativeBookUrlIsNotTreatedAsXPath() throws {
        let sourceJSON = """
        {"bookSourceName":"相对 URL 源","bookSourceUrl":"https://legacy.example.com",
         "searchUrl":"https://legacy.example.com/s?k={{key}}",
         "ruleSearch":{"bookList":"$.data.books","name":"bookName",
                       "bookUrl":"/novel/chapterList?novel_id={{$.bookId}}"}}
        """
        let source = try JSONDecoder().decode(BookSource.self, from: Data(sourceJSON.utf8))
        let transport = FixedTransport(["https://legacy.example.com/s?k=x": Self.listJSON])
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        let books = try engine.search("x")
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.bookUrl, "https://legacy.example.com/novel/chapterList?novel_id=77",
                       "⭐ 以 / 开头的 bookUrl 是 URL（不是 XPath）")
    }

    // MARK: - ③ 选择器写法不能被 URL 兜底抢走

    /// ⭐ **`a@href` 照常**（URL 兜底只在常规求值不通时出手）
    func testSelectorChapterUrlStillWorks() throws {
        let sourceJSON = """
        {"bookSourceName":"选择器源","bookSourceUrl":"https://legacy.example.com",
         "ruleToc":{"chapterList":"ul.list li a","chapterName":"text","chapterUrl":"a@href"},
         "ruleSearch":{"bookList":"ul.list li a","name":"text"}}
        """
        let source = try JSONDecoder().decode(BookSource.self, from: Data(sourceJSON.utf8))
        let transport = FixedTransport(["https://legacy.example.com/toc": Self.listHTML])
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        var info = BookInfo()
        info.bookUrl = "https://legacy.example.com/toc"
        let chapters = try engine.toc(info)
        XCTAssertEqual(chapters.first?.url, "https://legacy.example.com/c/1",
                       "选择器写法照常")
    }

    // MARK: - ④ 判据本身

    /// ⭐ **`looksLikeURL` 的判据**：XPath 不能被当成 URL
    func testLooksLikeURLDistinguishesXPath() {
        XCTAssertTrue(SourceEngine.looksLikeURL("https://x.com/a"))
        XCTAssertTrue(SourceEngine.looksLikeURL("/novel/list?id={{$.id}}"))
        XCTAssertTrue(SourceEngine.looksLikeURL("/novel/list.html"))
        XCTAssertTrue(SourceEngine.looksLikeURL("https://x.com/a?q=@get:{bid}"))
        // ⚠️ XPath 不该被当成 URL
        XCTAssertFalse(SourceEngine.looksLikeURL("//div[@class='x']"))
        XCTAssertFalse(SourceEngine.looksLikeURL("/html/body/div[1]"))
        XCTAssertFalse(SourceEngine.looksLikeURL("a@href"))
    }
}
