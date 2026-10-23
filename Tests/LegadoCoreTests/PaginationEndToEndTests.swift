import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **翻页链路门禁**（`ruleToc.nextTocUrl` / `ruleContent.nextContentUrl`）
///
/// **125 源实测**：`ruleToc.nextTocUrl` **24 个源** / `ruleContent.nextContentUrl` **28 个源**
/// ⇒ **52 个源（42%）** 的目录 / 正文以前是**残缺的**（只抓第一页）。
///
/// 真站例子（轻阅那边踩过）：红薯小说 `nextTocUrl` ⇒ 目录 **50 章 → 274 章**。
///
/// ⚠️ 这份门禁**自己构造输入**（源 + 页面都现造）⇒
/// ⇒ 坏实现时**必然红**（不依赖任何外部快照）。
final class PaginationEndToEndTests: XCTestCase {

    // MARK: - 内存传输（URL → 页面）

    final class MemTransport: HTTPTransport, @unchecked Sendable {
        private let pages: [String: String]
        private let lock = NSLock()
        private var _requested: [String] = []
        var requested: [String] { lock.lock(); defer { lock.unlock() }; return _requested }

        init(pages: [String: String]) { self.pages = pages }

        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            lock.lock(); _requested.append(request.url); lock.unlock()
            // ⭐ **最长匹配优先**（否则 `/p/2` 会命中 `/p/2x`）
            for (k, v) in pages.sorted(by: { $0.key.count > $1.key.count })
            where request.url.contains(k) {
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: Data(v.utf8), finalURL: request.url)
            }
            throw SourceError.requestFailed(request.url, "内存传输里没有这个页面")
        }
    }

    // MARK: - 准备

    private static let sourceJSON = """
    {
      "bookSourceName": "翻页测试源",
      "bookSourceUrl": "https://example.test",
      "ruleToc": {
        "chapterList": "a.chapter",
        "chapterName": "text",
        "chapterUrl": "href",
        "nextTocUrl": "a.next@href"
      },
      "ruleContent": {
        "content": "tag.p@text",
        "nextContentUrl": "a.next@href"
      }
    }
    """

    private func makeEngine(pages: [String: String]) throws -> (SourceEngine, MemTransport) {
        let data = Data(Self.sourceJSON.utf8)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        let transport = MemTransport(pages: pages)
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        return (engine, transport)
    }

    private func makeInfo(_ url: String) -> BookInfo {
        var info = BookInfo()
        info.bookUrl = url
        info.sourceName = "翻页测试源"
        return info
    }

    // MARK: - ① 目录翻页

    /// ⭐⭐ **目录要跨页抓**（`nextTocUrl`）—— 以前只抓第一页
    func testTocFollowsNextTocUrl() throws {
        let (engine, transport) = try makeEngine(pages: [
            "/p/1": """
            <html><body>
              <a class="chapter" href="/c/1">第一章</a>
              <a class="chapter" href="/c/2">第二章</a>
              <a class="next" href="/p/2">下一页</a>
            </body></html>
            """,
            "/p/2": """
            <html><body>
              <a class="chapter" href="/c/3">第三章</a>
              <a class="next" href="/p/2">下一页</a>
            </body></html>
            """,
        ])
        let chapters = try engine.toc(makeInfo("https://example.test/p/1"))

        // ⭐ 三章都在（第二页那章必须有）
        XCTAssertEqual(chapters.count, 3, "⭐ 目录应跨页抓齐 3 章，实际 \(chapters.count)：\(chapters.map(\.name))")
        XCTAssertEqual(chapters.map(\.name), ["第一章", "第二章", "第三章"])
        XCTAssertTrue(chapters.contains { $0.url.contains("/c/3") }, "第二页的章节应在列表里")
        // ⭐ 两页都请求了
        XCTAssertTrue(transport.requested.contains { $0.contains("/p/2") }, "应请求第二页")
        // ⭐⭐ **去重** —— 站方每页都给同样的 next ⇒ 不能死循环 / 不能重复章节
        XCTAssertEqual(chapters.filter { $0.url.contains("/c/3") }.count, 1, "⭐ 第二页的章节不该重复（去重）")
        XCTAssertLessThanOrEqual(transport.requested.count, 3, "⭐ 请求次数应有上限（防死循环），实际 \(transport.requested.count)")
    }

    // MARK: - ② 正文翻页

    /// ⭐⭐ **正文要跨页拼起来**（`nextContentUrl`）—— 以前只抓第一页
    func testContentFollowsNextContentUrl() throws {
        let (engine, transport) = try makeEngine(pages: [
            "/c/1": """
            <html><body><p>第一段正文</p><a class="next" href="/c/1-p2">下段</a></body></html>
            """,
            "/c/1-p2": """
            <html><body><p>第二段正文</p></body></html>
            """,
        ])
        var chapter = Chapter(name: "第一章", url: "https://example.test/c/1", isVolume: false, index: 0)
        chapter.url = "https://example.test/c/1"
        let text = try engine.content(chapter)

        XCTAssertTrue(text.contains("第一段正文"), "第一段应在内")
        XCTAssertTrue(text.contains("第二段正文"), "⭐ 第二段应在内（以前只抓第一页 ⇒ 正文被截断）")
        XCTAssertTrue(transport.requested.contains { $0.contains("/c/1-p2") }, "应请求第二段")
    }

    // MARK: - ③ 没有 next 规则时行为不变（防回归）

    /// ⚠️ **没有 `nextTocUrl` ⇒ 只抓一页**（别把普通源也抓成多页）
    func testNoNextRuleKeepsSinglePage() throws {
        let data = Data("""
        {
          "bookSourceName": "单页源",
          "bookSourceUrl": "https://example.test",
          "ruleToc": { "chapterList": "a.chapter", "chapterName": "text", "chapterUrl": "href" }
        }
        """.utf8)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        let transport = MemTransport(pages: [
            "/p/1": "<html><body><a class=\"chapter\" href=\"/c/1\">第一章</a></body></html>",
        ])
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        var info = BookInfo()
        info.bookUrl = "https://example.test/p/1"
        let chapters = try engine.toc(info)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(transport.requested.count, 1, "不该多发请求")
    }

    // MARK: - ④ 翻页页没命中 ⇒ 跳过，不炸整个目录（防回归）

    /// ⚠️ 后面某页没内容是**常态** ⇒ 不许把整个目录炸掉
    func testEmptyLaterPageDoesNotBreakToc() throws {
        let (engine, _) = try makeEngine(pages: [
            "/p/1": """
            <html><body>
              <a class="chapter" href="/c/1">第一章</a>
              <a class="next" href="/p/2">下一页</a>
            </body></html>
            """,
            "/p/2": "<html><body><p>这一页没有章节</p></body></html>",
        ])
        let chapters = try engine.toc(makeInfo("https://example.test/p/1"))
        XCTAssertEqual(chapters.count, 1, "第二页没命中 ⇒ 跳过，但第一页的章节要保住")
        XCTAssertEqual(chapters.first?.name, "第一章")
    }
}
