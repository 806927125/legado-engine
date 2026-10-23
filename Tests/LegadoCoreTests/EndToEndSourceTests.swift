import Foundation
import XCTest
@testable import LegadoCore

/// **端到端门禁** —— 真书源 + 真页面（离线快照）跑通「分类 → 发现 → 详情 → 目录 → 正文」。
///
/// ⭐ **这是本项目最接近「真能用」的一条门禁**：
/// 前面 122 条对拍用例验的是「引擎某个零件对不对」；
/// 这一条验的是「**一个真书源能不能从头跑到尾**」。
///
/// **书源**：「过期杂志」（<https://www.52dzxy.com>）—— 规则从 125 源包**一字未改**。
/// **页面**：三个离线快照（站方 2026-10-23 与崩溃会话逐字节一致 ⇒ 未改版）。
final class EndToEndSourceTests: XCTestCase {

    // MARK: - 假传输（按 URL 后缀匹配 fixture）

    /// 把 fixture 文件当网络响应 —— **不联网**，门禁离线可跑
    final class FixtureTransport: HTTPTransport, @unchecked Sendable {
        struct Route { let pattern: String; let file: String }
        private let routes: [Route]
        private let dir: URL
        private let lock = NSLock()
        private var _requested: [String] = []

        init(dir: URL, routes: [Route]) { self.dir = dir; self.routes = routes }

        /// 实际发出过哪些 URL（断言「请求确实发出去了」）
        var requested: [String] {
            lock.lock(); defer { lock.unlock() }
            return _requested
        }

        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            lock.lock(); _requested.append(request.url); lock.unlock()
            for r in routes where request.url.contains(r.pattern) {
                let data = try Data(contentsOf: dir.appendingPathComponent(r.file))
                return HTTPResponse(statusCode: 200, headers: [:], body: data, finalURL: request.url)
            }
            throw SourceError.requestFailed(request.url, "fixture 里没有这个 URL")
        }
    }

    // MARK: - 准备

    private static let fixtureDir: URL = {
        URL(fileURLWithPath: #filePath)          // …/Tests/LegadoCoreTests/EndToEndSourceTests.swift
            .deletingLastPathComponent()          // LegadoCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // 项目根
            .appendingPathComponent("conformance/fixtures/e2e")
    }()

    private func makeEngine() throws -> (SourceEngine, FixtureTransport) {
        let sourceData = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("source-52dzxy.json"))
        let source = try JSONDecoder().decode(BookSource.self, from: sourceData)
        let transport = FixtureTransport(dir: Self.fixtureDir, routes: [
            .init(pattern: "/bkzs/all.html", file: "list.html"),
            .init(pattern: "/articles/", file: "chapter.html"),
            .init(pattern: "/202614/index.html", file: "detail.html"),
        ])
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        return (engine, transport)
    }

    /// 跑一遍「发现 → 详情 → 目录」，返回链上的产物（多条断言共用）
    private func runChain(_ engine: SourceEngine) throws -> (cats: [Category], books: [Book],
                                                            info: BookInfo, chapters: [Chapter]) {
        let cats = try engine.categories()
        // ⚠️ **不许强解包** —— 崩了不产汇总行，看不出是哪条断言挂的
        let target = try XCTUnwrap(cats.first { $0.title.contains("百科知识") },
                                   "应含「百科知识」分类")
        let books = try engine.explore(target.url)
        let info = try engine.bookInfo(books[0])
        let chapters = try engine.toc(info)
        return (cats, books, info, chapters)
    }

    // MARK: - 流水线

    /// ① 分类列表 —— `exploreUrl` 是老式「标题::URL」多行（23 个）
    func testCategories() throws {
        let (engine, _) = try makeEngine()
        let cats = try engine.categories()
        XCTAssertEqual(cats.count, 23, "应解析出 23 个分类")
        XCTAssertTrue(cats.contains { $0.title.contains("百科知识") }, "应含「百科知识」")
        XCTAssertTrue(cats.allSatisfy { !$0.url.isEmpty }, "老式形态每行都该有 URL")
        XCTAssertTrue(cats.allSatisfy { $0.url.hasPrefix("https://") }, "分类 URL 应是绝对地址")
    }

    /// ② 发现 —— 列表规则命中（`.magazine-grid .magazine-item` ⇒ 60 个）
    func testExplore() throws {
        let (engine, transport) = try makeEngine()
        let cats = try engine.categories()
        // ⚠️ **不许强解包** —— 崩了不产汇总行，看不出是哪条断言挂的
        let target = try XCTUnwrap(cats.first { $0.title.contains("百科知识") },
                                   "应含「百科知识」分类")
        let books = try engine.explore(target.url)
        XCTAssertEqual(books.count, 60, "应列出 60 本")
        XCTAssertEqual(books[0].name, "2026年第14期", "书名取自 `a@text`")
        XCTAssertTrue(transport.requested.contains { $0.contains("bkzs/all.html") }, "列表页请求应发出")
        // ⭐ 相对地址要绝对化（列表页里是 `../2026/bkzs/202614/index.html`）
        XCTAssertEqual(books[0].bookUrl, "https://www.52dzxy.com/2026/bkzs/202614/index.html",
                       "bookUrl 应相对**列表页 URL** 绝对化")
    }

    /// ③ 详情 —— 抓详情页并取字段
    func testBookInfo() throws {
        let (engine, _) = try makeEngine()
        let (_, books, info, _) = try runChain(engine)
        XCTAssertFalse(info.bookUrl.isEmpty)
        XCTAssertEqual(info.sourceName, "过期杂志", "书源名不该为空")
        // ⭐ 该源 `ruleBookInfo.tocUrl` 为空 ⇒ 目录规则在详情页上跑
        XCTAssertTrue(info.tocUrl.isEmpty, "该源没给 tocUrl ⇒ 应为空（目录回落到 bookUrl）")
        XCTAssertFalse(books.isEmpty)
    }

    /// ④ 目录 —— ⭐ 该源 `ruleBookInfo.tocUrl` 为空 ⇒ **目录规则在详情页上跑**
    /// 且 `chapterList` 的**逗号是 CSS 并集**（`.catalog-section-title,.article-title a`）
    func testToc() throws {
        let (engine, transport) = try makeEngine()
        let (_, _, _, chapters) = try runChain(engine)

        // ⭐⭐ 26 = 10 个卷标题（h2.catalog-section-title）+ 16 个章节（.article-title a）
        //    **这条断言专门盯「逗号被当成兜底链」那个 bug** ——
        //    逗号一拆，第一段命中就停 ⇒ 只剩 10 个卷标题、16 个章节全丢。
        XCTAssertEqual(chapters.count, 26, "应列出 26 项（10 卷标题 + 16 章节）")
        let volumes = chapters.filter { $0.isVolume }
        let articles = chapters.filter { !$0.isVolume }
        XCTAssertEqual(volumes.count, 10, "应识别出 10 个卷标题（`isVolume` 规则）")
        XCTAssertEqual(articles.count, 16, "应有 16 个章节")

        // ⭐ 章节名 / 章节地址：站方写的是 `"chapterName": "text"` / `"chapterUrl": "href"`
        //    ⇒ 「整条规则就是取值模式」这条语义必须支持
        XCTAssertTrue(articles.allSatisfy { !$0.name.isEmpty }, "章节名不该为空")
        XCTAssertTrue(articles.allSatisfy { $0.url.hasPrefix("https://") }, "章节 URL 应是绝对地址")
        XCTAssertTrue(articles.contains { $0.url.contains("/articles/") }, "章节 URL 应指向文章页")
        XCTAssertTrue(volumes.allSatisfy { $0.url.isEmpty }, "卷标题没有章节 URL")

        XCTAssertTrue(transport.requested.contains { $0.contains("202614/index.html") },
                      "目录要在详情页上跑（该源没给 tocUrl）")
    }

    /// ⑤ 正文 —— 抓章节页并取正文
    func testContent() throws {
        let (engine, transport) = try makeEngine()
        let (_, _, _, chapters) = try runChain(engine)
        let article = try XCTUnwrap(chapters.first { !$0.isVolume && !$0.url.isEmpty },
                                   "应至少有一个章节")
        let text = try engine.content(article)

        XCTAssertGreaterThan(text.count, 500, "正文应有内容（真值约 1300 字）")
        // ⭐ 真正文里的特征句 ⇒ 这条能证伪「取错了元素」
        XCTAssertTrue(text.contains("高空抛物"), "正文应是这篇文章的内容")
        // ⭐ 站方净化规则是 `##我爱读者校园网`（这站早已改名 ⇒ 规则本身没跟上站方改版）
        XCTAssertFalse(text.contains("我爱读者校园网"), "净化正则应生效")
        XCTAssertTrue(transport.requested.contains { $0.contains("/articles/") }, "章节页请求应发出")
    }

    /// ⑥ 整链跑通（发现 → 详情 → 目录 → 正文）
    func testFullChain() throws {
        let (engine, _) = try makeEngine()
        let (_, books, _, chapters) = try runChain(engine)
        let article = try XCTUnwrap(chapters.first { !$0.isVolume && !$0.url.isEmpty },
                                   "应至少有一个章节")
        let text = try engine.content(article)

        XCTAssertEqual(books.count, 60)
        XCTAssertEqual(chapters.count, 26)
        XCTAssertFalse(text.isEmpty)
    }

    /// ⑦ ⭐ **诊断不许说谎** —— 这条流水线跑完，诊断里**不许出现真错误**
    ///
    /// 本项目最大的差异化就是「不静默失败」⇒ 门禁必须盯着它。
    func testDiagnosticsHaveNoHardFailure() throws {
        let (engine, _) = try makeEngine()
        _ = try runChain(engine)
        XCTAssertFalse(engine.diagnostics.isEmpty, "跑完流水线应留下诊断")
        let hard = engine.diagnostics.filter { $0.failure?.isHardFailure ?? false }
        XCTAssertTrue(hard.isEmpty, "不该有真错误，实际：\(hard.map { $0.failure.map { "\($0)" } ?? "?" })")
    }

    /// ⭐ **书源模型必须容错** —— 缺字段不许让整个源废掉
    /// （轻阅 build215 的教训：`KindsDTO` 少一个 `group` ⇒ 整个 op 结果全废）
    func testBookSourceDecodingIsTolerant() throws {
        // 只有一个最小字段集
        let minimal = #"{"bookSourceName":"x","bookSourceUrl":"https://x/"}"#
        let source = try JSONDecoder().decode(BookSource.self, from: Data(minimal.utf8))
        XCTAssertEqual(source.bookSourceName, "x")
        XCTAssertNil(source.ruleSearch, "缺失的规则应是 nil，不是抛异常")
        XCTAssertNil(source.ruleToc)
    }
}
