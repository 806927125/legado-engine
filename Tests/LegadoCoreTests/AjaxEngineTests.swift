import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **`java.ajax` 的引擎侧实现门禁**（沙盒可跑，不碰 JSC）
///
/// 站方 JS 靠 `java.ajax` 抓页面（**125 源里 22 处 / 12 个源**）⇒
/// 而引擎自己就有 transport + cookie jar + 源级 header ⇒ **天然该由引擎做**。
///
/// ⚠️ 这份门禁直接调 `SourceEngine.ajax(...)`（不经 JSC）⇒ Linux 沙盒能跑；
/// JSC 那层（`java.ajax` 在 JS 里真能调）由 `JSCAjaxTests`（macOS CI）验。
final class AjaxEngineTests: XCTestCase {

    /// 记录请求的假传输
    final class MemTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [HTTPRequest] = []
        var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        let body: String
        init(body: String = "<html>抓到的页面</html>") { self.body = body }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            lock.lock(); _requests.append(request); lock.unlock()
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8),
                                finalURL: request.url)
        }
    }

    private func makeEngine(_ transport: MemTransport,
                            header: String? = nil) throws -> SourceEngine {
        var src: [String: Any] = [
            "bookSourceName": "ajax 源",
            "bookSourceUrl": "https://example.test",
        ]
        if let header { src["header"] = header }
        let data = try JSONSerialization.data(withJSONObject: src)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        return SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
    }

    // MARK: - ① GET

    /// ⭐ **基本 ajax** ⇒ 返回响应正文
    func testAjaxGetReturnsBody() throws {
        let transport = MemTransport(body: "<html>正文内容</html>")
        let engine = try makeEngine(transport)
        let body = engine.ajax(url: "https://example.test/api/list", options: nil)
        XCTAssertEqual(body, "<html>正文内容</html>", "⭐ ajax 应返回响应正文")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url, "https://example.test/api/list")
    }

    // MARK: - ② POST + body + headers

    /// ⭐ **站方的第二个参数**（`{method, body, headers}`）⇒ 转成 URL 规则后缀
    func testAjaxPostWithBodyAndHeaders() throws {
        let transport = MemTransport()
        let engine = try makeEngine(transport)
        let opts: JSONValue = .object([
            "method": .string("post"),
            "body": .string("a=1&b=2"),
            "headers": .object(["X-Token": .string("T42")]),
        ])
        _ = engine.ajax(url: "https://example.test/api/post", options: opts)

        let req = try XCTUnwrap(transport.requests.first, "应发出过请求")
        XCTAssertEqual(req.method, "POST", "⭐ method 应是 POST")
        let bodyText = try XCTUnwrap(req.body.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(bodyText, "a=1&b=2")
        XCTAssertEqual(req.headers["X-Token"], "T42", "URL 级 header 应生效")
    }

    /// ⚠️ **body 是对象** ⇒ 要 JSON 化（站方常这么写）
    func testAjaxPostWithObjectBody() throws {
        let transport = MemTransport()
        let engine = try makeEngine(transport)
        let opts: JSONValue = .object([
            "method": .string("POST"),
            "body": .object(["id": .string("42"), "n": .int(7)]),
        ])
        _ = engine.ajax(url: "https://example.test/api/post", options: opts)
        let req = try XCTUnwrap(transport.requests.first)
        let text = try XCTUnwrap(req.body.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(text.contains("\"id\""), "body 应被 JSON 化：\(text)")
    }

    // MARK: - ③ 源级 header 要带上

    /// ⭐ **ajax 也要带源级 header**（54 个源在用）
    func testAjaxSendsSourceHeaders() throws {
        let transport = MemTransport()
        let engine = try makeEngine(transport, header: "{\"User-Agent\":\"QR/1.0\"}")
        _ = engine.ajax(url: "https://example.test/a", options: nil)
        let req = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(req.headers["User-Agent"], "QR/1.0")
    }

    // MARK: - ④ `data:` 伪 URL ⇒ **绝不能发请求**

    /// ⭐⭐ **`data:` 伪 URL 不发请求**，**原始载荷**当响应体
    /// （站方聚合源用它装载荷 ⇒ 发出去会炸「illegal base64」）
    ///
    /// ⭐⭐⭐ **2026-10-24 真机「大灰狼详情空白」实证：载荷要【原样】给站方**
    ///   站方的 init 规则自己会解：`JSON.parse(java.hexDecodeToString(result))`
    ///   ⇒ **引擎先解一遍 = 解两次** ⇒ 站方拿到的是「解过一次的文本」⇒ `JSON.parse` 炸
    ///   ⇒ **整条 init 规则挂掉** ⇒ 详情字段全空 ⭐⭐⭐
    ///   ⇒ 与轻阅参考实现逐字一致
    ///   （`reference/js/java-api.js` 的 `rawRequest` / `reference/js/engine.js` 的 `fetchPage`）⭐
    func testDataURLDoesNotSendRequest() throws {
        let transport = MemTransport()
        let engine = try makeEngine(transport)
        // 载荷 = {"tab":"小说","url":""}
        let payload = "data:;base64,eyJ0YWIiOiLlsI/or7QiLCJ1cmwiOiIifQ==,{\"type\":\"qingtian\"}"
        let body = engine.ajax(url: payload, options: nil)
        XCTAssertEqual(body, "eyJ0YWIiOiLlsI/or7QiLCJ1cmwiOiIifQ==",
                       "⭐ 载荷要【原样】给站方（站方自己 `hexDecodeToString` 解）⇒ 不能先解一遍")
        XCTAssertEqual(transport.requests.count, 0, "⭐⭐ data: URL **一个请求都不该发**")
    }

    /// ⚠️ **解不了 base64 ⇒ 明确失败**（不许返回乱码）
    func testInvalidBase64FailsExplicitly() throws {
        let transport = MemTransport()
        let engine = try makeEngine(transport)
        let body = engine.ajax(url: "data:;base64,!!!不是合法base64!!!", options: nil)
        XCTAssertNil(body, "⭐ 解不了必须明确失败（返回 nil），不能返回乱码")
        XCTAssertEqual(transport.requests.count, 0)
    }

    /// 非 base64 的 `data:` ⇒ 载荷就是明文
    func testPlainDataURL() throws {
        let transport = MemTransport()
        let engine = try makeEngine(transport)
        let body = engine.ajax(url: "data:text/plain,hello", options: nil)
        XCTAssertEqual(body, "hello")
        XCTAssertEqual(transport.requests.count, 0)
    }

    // MARK: - ⑤ 失败不抛（JS 侧拿 undefined）

    /// ⚠️ 请求失败 ⇒ **返回 nil，不抛**（站方自己判空）⇒ 且**不静默**
    func testAjaxFailureReturnsNil() throws {
        final class Failing: HTTPTransport, @unchecked Sendable {
            func send(_ request: HTTPRequest) throws -> HTTPResponse {
                throw SourceError.requestFailed(request.url, "网络不通")
            }
        }
        let source = try JSONDecoder().decode(BookSource.self, from:
            Data("{\"bookSourceName\":\"x\",\"bookSourceUrl\":\"https://example.test\"}".utf8))
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: Failing()))
        let body = engine.ajax(url: "https://example.test/a", options: nil)
        XCTAssertNil(body, "失败应返回 nil 而不是抛")
    }
}
