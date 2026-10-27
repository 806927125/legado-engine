import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **UAA 四合一（知秋）· 原版直跑**（2026-10-27 真机截图实证）
///
/// **真机症状**：详情页打不开 ⇒「书源无效：bookUrl 为空」
///   引擎诊断：`规则[videoId||id @js: let type = baseUrl.match(new RegExp(api + '/(\w+)/'))…]`
///              `分支=|| 兜底链 失败=noMatch(reason: "|| 兜底链全部未命中")`
///   ⇒ **目录也进不去**（没 bookUrl ⇒ 详情失败 ⇒ 目录拿不到）⭐⭐⭐
///
/// ⭐⭐⭐ **这个 fixture 是【原版源】**（一字未改）⇒
///   **「站方原版能不能直接用」就是这条门禁** ⇒ 以后新增源照抄这条 ⇒ 不用人肉适配 ⭐⭐⭐
///
/// ⭐ **站方的 bookUrl 规则**（`ruleSearch.bookUrl`）：
/// ```
/// id
/// @js:
/// let type = baseUrl.match(new RegExp(api + '/(\w+)/'))[1]   ← ① 从 baseUrl 推类型
/// getApiUrl(`/${type}/info`, { novelId: result })             ← ② jsLib 里的全局函数
/// ```
/// ⇒ 它同时依赖**两个东西**：
///   ① `baseUrl` = **搜索请求的真实 URL**（`https://www.uaa1234.com/novel/search?...`）
///      ⇒ 推出来的 type 才是 `novel`（不是 comic/audio/video）⭐⭐⭐
///   ② `api` / `getApiUrl` = **jsLib 的顶层全局**（`let api = …` ⇒ 必须是**全局可见**）⭐⭐⭐
final class LiveSourceUAATests: XCTestCase {

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures")
    }

    private func loadSource() throws -> BookSource {
        let data = try Data(contentsOf: Self.fixturesDir.appendingPathComponent("uaa-source.json"))
        return try JSONDecoder().decode(BookSource.self, from: data)
    }

    private func loadJsLib() throws -> String {
        let data = try Data(contentsOf: Self.fixturesDir.appendingPathComponent("uaa-source.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj["jsLib"] as? String ?? ""
    }

    /// ⭐ 站方的搜索响应形状（`ruleSearch.bookList = "data.data[*]"`）
    private static let searchResponse = """
    {"code":0,"data":{"data":[{"id":"b1","title":"测试书名","authors":["作者甲"],
    "brief":"简介","cover":"https://cdn.uaa.com/x.webp","latestUpdate":"2026-10-27",
    "wordCountFormat":"17.5万","finished":"1","categories":"[]","tags":"[]"}]}}
    """

    /// ⭐ JSC 后端要一个 host provider（Linux 编译不到 ⇒ 这段在 macOS 才生效）⭐
    final class NoopAPI: JSHostAPIProvider, @unchecked Sendable {
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? { nil }
    }

    final class MemTransport: HTTPTransport, @unchecked Sendable {
        private let body: String
        private(set) var lastURL: String = ""
        init(body: String) { self.body = body }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            lastURL = request.url
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8), finalURL: request.url)
        }
    }

    // MARK: - ① Node 后端（Linux 沙盒 3 秒反馈）

    func testUAASearchProducesBookUrl() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 显式 SKIP（不许假绿）")
        let src = try loadSource()
        let js = try NodeJSExecutor()
        let transport = MemTransport(body: Self.searchResponse)
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: transport), js: js)
        try engine.loadJsLib(try loadJsLib())

        let books = try engine.search("测试")
        XCTAssertFalse(books.isEmpty,
                       "⭐⭐⭐ 原版源必须能出书（真机症状：bookUrl 为空 ⇒ 详情/目录全断）")
        let url = books[0].bookUrl
        XCTAssertFalse(url.isEmpty, "⭐⭐⭐ bookUrl 不能为空（真机症状）")
        XCTAssertTrue(url.contains("/novel/info"),
                      "⭐⭐⭐ bookUrl 必须带上正确的类型（novel）⇒ 实际：\(url)")
    }

    // MARK: - ② JSC 后端（真机用的那个 ⇒ macOS CI 才跑得到）

    func testUAASearchProducesBookUrlOnJSC() throws {
        #if canImport(JavaScriptCore)
        let src = try loadSource()
        let js = try JSCExecutor(api: NoopAPI())
        let transport = MemTransport(body: Self.searchResponse)
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: transport), js: js)
        try engine.loadJsLib(try loadJsLib())

        let books = try engine.search("测试")
        XCTAssertFalse(books.isEmpty, "⭐⭐⭐ 原版源必须能出书（JSC）")
        XCTAssertFalse(books[0].bookUrl.isEmpty, "⭐⭐⭐ bookUrl 不能为空（JSC）")
        XCTAssertTrue(books[0].bookUrl.contains("/novel/info"),
                      "⭐⭐⭐ bookUrl 必须带正确类型（JSC）⇒ 实际：\(books[0].bookUrl)")
        #endif
    }
}
