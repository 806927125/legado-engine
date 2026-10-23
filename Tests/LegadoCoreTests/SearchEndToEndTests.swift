import Foundation
import XCTest
@testable import LegadoCore

/// **搜索端到端门禁** —— 真书源「神魔」（<https://book.eayue.com>）+ 真搜索页快照。
///
/// ⭐ 这个源**一条规则就把搜索路径的语义全覆盖了**：
/// - `bookList: ".show@li"`（CSS 选择器 + 相对求值）
/// - `name: ".title@text"`（取值模式）
/// - `bookUrl: "tag.li@onclick##clickChargeBook\\('(.*?)',(.*?)\\)##novel.m?gid=$1&nid=$2"`
///   （**尾部正则 + 捕获组替换** + **相对地址绝对化**）
/// - `exploreUrl` 是**新版 JSON 数组**形态
/// - `ruleBookInfo.tocUrl` 是「**尾部正则 + 换行 + `<js>` 块**」的复合形态
final class SearchEndToEndTests: XCTestCase {

    // MARK: - 假传输

    final class FixtureTransport: HTTPTransport, @unchecked Sendable {
        private let dir: URL
        private let lock = NSLock()
        private var _requested: [String] = []
        init(dir: URL) { self.dir = dir }
        var requested: [String] {
            lock.lock(); defer { lock.unlock() }
            return _requested
        }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            lock.lock(); _requested.append(request.url); lock.unlock()
            // 搜索页快照
            if request.url.contains("/ta/search.m") {
                let data = try Data(contentsOf: dir.appendingPathComponent("search.html"))
                return HTTPResponse(statusCode: 200, headers: [:], body: data, finalURL: request.url)
            }
            throw SourceError.requestFailed(request.url, "fixture 里没有这个 URL")
        }
    }

    private static let fixtureDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/e2e")
    }()

    private func makeEngine() throws -> (SourceEngine, FixtureTransport) {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("source-eayue.json"))
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        let transport = FixtureTransport(dir: Self.fixtureDir)
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        return (engine, transport)
    }

    // MARK: - ① 搜索能出书

    func testSearchReturnsBooks() throws {
        let (engine, transport) = try makeEngine()
        let books = try engine.search("仙逍")
        XCTAssertEqual(books.count, 20, "快照里 `.show > ul > li` 是 20 个")
        XCTAssertTrue(transport.requested.contains { $0.contains("/ta/search.m") }, "搜索请求应发出")
        // ⚠️ URL 模板 `{{key}}` 要被替换
        XCTAssertTrue(transport.requested.contains { $0.contains("word=") && !$0.contains("{{") },
                      "关键词应插值进 URL：\(transport.requested)")
    }

    // MARK: - ② 字段逐字

    func testSearchFieldValues() throws {
        let (engine, _) = try makeEngine()
        let books = try engine.search("仙逍")
        let b = try XCTUnwrap(books.first, "应至少有一本书")
        XCTAssertEqual(b.name, "逍遥刀仙", "name = `.title@text`")
        XCTAssertEqual(b.author, "天刈留香", "author = `.author@text`")
        XCTAssertTrue(b.intro.contains("万世天才"), "intro = `.desc@text`")
        XCTAssertFalse(b.kind.isEmpty, "kind = `.kind@text`")
        XCTAssertFalse(b.lastChapter.isEmpty, "lastChapter = `.chapter_nums@text`")
    }

    // MARK: - ③ ⭐ 尾部正则 + 捕获组替换 + 相对地址绝对化

    func testBookURLFromRegexCapturesAndAbsolutize() throws {
        let (engine, _) = try makeEngine()
        let books = try engine.search("仙逍")
        let b = try XCTUnwrap(books.first, "应至少有一本书")
        // 站方规则：`tag.li@onclick##clickChargeBook\('(.*?)',(.*?)\)##novel.m?gid=$1&nid=$2`
        // ⇒ 从 onclick 里抠出 gid / nid ⇒ 拼成相对 URL ⇒ 相对**搜索页**绝对化
        XCTAssertEqual(b.bookUrl,
                       "https://book.eayue.com/ta/novel.m?gid=HOKeWIrzYI4zG392BOz7Aqf&nid=665384",
                       "尾部正则 + $1/$2 替换 + 绝对化")
        XCTAssertTrue(b.bookUrl.hasPrefix("https://"), "必须是绝对地址")
    }

    // MARK: - ④ 分类（新版 JSON 数组形态）

    func testExploreUrlJSONArrayForm() throws {
        let (engine, _) = try makeEngine()
        let cats = try engine.categories()
        XCTAssertGreaterThan(cats.count, 5, "应解析出多个分类")
        XCTAssertTrue(cats.allSatisfy { !$0.url.isEmpty }, "每个分类都该有 URL")
        XCTAssertTrue(cats.contains { $0.title.contains("玄幻") }, "应含「玄幻奇幻」")
    }

    // MARK: - ⑤ ⭐ 「尾部正则 + 换行 + `<js>` 块」复合形态能解析

    /// 该源的 `ruleBookInfo.tocUrl` 就是这个形状 ⇒ 引擎必须**读得懂**
    /// （求值要等 JS 后端，但**解析**不能失败 —— 否则会被误判成「JSONPath 不支持」）
    func testTrailingRegexPlusJSBlockCompositeParses() throws {
        let (engine, _) = try makeEngine()
        let rule = try XCTUnwrap(engine.source.ruleBookInfo?.tocUrl, "该源应有 tocUrl 规则")
        let ev = Evaluator()
        let ast = ev.parser.parse(rule, isJSON: false)
        guard case .post(let inner, let post) = ast else {
            return XCTFail("应解析成 .post(主体, 后处理)，实际：\(ast)")
        }
        // 主体 = 尾部正则那条链（`class.catelog@onclick##jumpPage…`）
        guard case .post = inner else {
            return XCTFail("主体应还是 .post（尾部正则），实际：\(inner)")
        }
        // 后处理 = `<js>` 块
        // ⭐⭐ **必须断言 code 的内容**（旧实现 code 是空串也过 ⇒ 平凡通过）
        guard case .jsWithTail(let code, let tail) = post else {
            return XCTFail("后处理应是 .jsWithTail 块，实际：\(post)")
        }
        XCTAssertTrue(code.contains("url=result.replace"), "JS 代码内容不对：\(code)")
        XCTAssertNil(tail)
    }

    // MARK: - ⑥ 诊断不许说谎

    func testSearchDiagnosticsHaveNoHardFailure() throws {
        let (engine, _) = try makeEngine()
        _ = try engine.search("仙逍")
        XCTAssertFalse(engine.diagnostics.isEmpty, "应留下诊断")
        let hard = engine.diagnostics.filter { $0.failure?.isHardFailure ?? false }
        XCTAssertTrue(hard.isEmpty, "不该有真错误：\(hard.map { "\($0)" })")
    }
}
