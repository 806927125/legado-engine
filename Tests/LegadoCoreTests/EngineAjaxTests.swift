import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **引擎侧 `java.ajax` 的门禁** —— 沙盒可跑（不依赖 JSC）
///
/// ⚠️⚠️ **2026-10-24 真机栽的**：真机发现页冒出「**未分组**」假分类
///   ⇒ 查下来：站方 `exploreUrl` 的 JS **自己去 ajax `/discovestyle`** 拿真分类
///   ⇒ 那个 ajax 失败 ⇒ 站方只剩硬编码的 7 个筛选栏 + **一个兜底分类「未分组」** ⭐⭐
///   ⇒ 而引擎的 ajax 失败时**只记了个空诊断**（连原因都没有）⇒ 宿主根本看不出哪错了
///
/// ⇒ 这条门禁钉死三件事：
///   ① **成功路径**：URL 原样发出去、正文原样回来
///   ② **失败路径**：**必须带上状态码和 URL**（不然宿主只能猜）⭐
///   ③ **失败不许炸**（JS 侧拿 undefined ⇒ 站方自己判空 ⇒ 走兜底）
final class EngineAjaxTests: XCTestCase {

    /// 记录请求的假传输
    private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
        let body: String
        let status: Int
        private(set) var requests: [HTTPRequest] = []
        init(body: String, status: Int = 200) { self.body = body; self.status = status }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            requests.append(request)
            return HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8),
                                finalURL: request.url)
        }
    }

    private func makeEngine(_ transport: RecordingTransport) throws -> SourceEngine {
        let data = Data(#"{"bookSourceName":"ajax 门禁源","bookSourceUrl":"https://x.example.com"}"#.utf8)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        return SourceEngine(source: source,
                            fetcher: PageFetcher(transport: transport))
    }

    // MARK: - ① 成功：URL 原样发、正文原样回

    func testAjaxReturnsBodyAndSendsURLAsIs() throws {
        let transport = RecordingTransport(body: #"{"ok":true}"#)
        let engine = try makeEngine(transport)
        let out = engine.ajax(url: "https://v5.langge.uk/discovestyle?source=番茄&tab=小说", options: nil)
        XCTAssertEqual(out, #"{"ok":true}"#, "⭐ ajax 必须把正文原样带回（站方要 JSON.parse 它）")
        XCTAssertEqual(transport.requests.count, 1, "⭐ 必须发一次请求")
        let sent = transport.requests[0].url
        XCTAssertTrue(sent.contains("discovestyle"), "⭐ URL 要原样（不能被改坏）：\(sent)")
        XCTAssertTrue(sent.contains("source="), "⭐ query 不能丢：\(sent)")
    }

    // MARK: - ②⭐⭐ 失败：必须带上**状态码和 URL**（不然宿主只能猜）

    func testAjaxFailureRecordsReasonAndURL() throws {
        let transport = RecordingTransport(body: "boom", status: 502)
        let engine = try makeEngine(transport)
        let out = engine.ajax(url: "https://v5.langge.uk/discovestyle?x=1", options: nil)
        XCTAssertNil(out, "⭐ 失败返回 nil（站方自己判空）")
        let diag = try XCTUnwrap(engine.diagnostics.last, "⭐⭐ 失败必须留下诊断")
        XCTAssertNotNil(diag.failure, "⭐⭐ 诊断必须带失败原因（以前是空诊断 ⇒ 宿主看不到）")
        let text = SourceEngine.diagnosticLine(diag)
        XCTAssertTrue(text.contains("502"), "⭐⭐ 诊断里要有状态码：\(text)")
        XCTAssertTrue(text.contains("discovestyle"), "⭐⭐ 诊断里要有请求的 URL：\(text)")
    }

    // MARK: - ③ 失败不许抛（站方 JS 要能 catch 住）

    func testAjaxFailureDoesNotThrow() throws {
        let transport = RecordingTransport(body: "boom", status: 500)
        let engine = try makeEngine(transport)
        // ⇒ 不抛 = 站方 JS 拿到 undefined ⇒ 走自己的兜底分支
        XCTAssertNil(engine.ajax(url: "https://x.example.com/a", options: nil))
    }

    // MARK: - ④ `data:` 伪 URL 绝不能真发请求（聚合源全中招）

    func testDataURLIsNotFetched() throws {
        let transport = RecordingTransport(body: "{}")
        let engine = try makeEngine(transport)
        // `data:;base64,<载荷>,{"type":"qingtian"}` ⇒ 载荷就是「页面内容」
        let out = engine.ajax(url: "data:;base64,eyJhIjoxfQ==,{\"type\":\"qingtian\"}", options: nil)
        XCTAssertNotNil(out, "⭐ data: 伪 URL 要返回载荷")
        XCTAssertEqual(transport.requests.count, 0, "⭐⭐ data: 伪 URL **一个请求都不许发**")
    }
}
