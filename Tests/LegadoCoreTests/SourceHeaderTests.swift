import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **源级请求头门禁**（`BookSource.header`）
///
/// **125 源实测：54 个源（43%）在用 `header`** ⇒ 缺了 UA / Referer / Cookie
/// ⇒ 很多站直接 403 / 跳验证 / 返回空页。
///
/// ⚠️ 以前编排层**一次都没用** `source.header` ⇒ 这 54 个源的请求全是「裸请求」。
final class SourceHeaderTests: XCTestCase {

    /// 捕获请求头的假传输
    final class HeaderTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [HTTPRequest] = []
        var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            lock.lock(); _requests.append(request); lock.unlock()
            return HTTPResponse(statusCode: 200, headers: [:],
                                body: Data("<html><body><p>正文</p></body></html>".utf8),
                                finalURL: request.url)
        }
    }

    private func makeEngine(_ header: String?) throws -> (SourceEngine, HeaderTransport) {
        var src: [String: Any] = [
            "bookSourceName": "带头源",
            "bookSourceUrl": "https://example.test",
            "ruleToc": ["chapterList": "a.chapter", "chapterName": "text", "chapterUrl": "href"],
        ]
        if let header { src["header"] = header }
        let data = try JSONSerialization.data(withJSONObject: src)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        let transport = HeaderTransport()
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
        return (engine, transport)
    }

    // MARK: - ① 源级 header 要发出去

    /// ⭐⭐ **源级 header 必须发出去**（54 个源受影响）
    func testSourceHeaderIsSent() throws {
        let (engine, transport) = try makeEngine("{\"User-Agent\":\"Mozilla/5.0 QR\",\"Referer\":\"https://example.test/\"}")
        var info = BookInfo()
        info.bookUrl = "https://example.test/toc"
        _ = try engine.toc(info)

        let req = try XCTUnwrap(transport.requests.first, "应发出过请求")
        XCTAssertEqual(req.headers["User-Agent"], "Mozilla/5.0 QR", "⭐ 源级 User-Agent 应发出去")
        XCTAssertEqual(req.headers["Referer"], "https://example.test/")
    }

    // MARK: - ② URL 级 header = **替换**

    /// ⭐⭐ **URL 级的 `,{"headers":…}` 是【替换】源级 header，不是合并**
    func testURLLevelHeadersReplaceSourceHeaders() throws {
        let (engine, transport) = try makeEngine("{\"User-Agent\":\"源级UA\",\"X-Src\":\"1\"}")
        var info = BookInfo()
        info.bookUrl = "https://example.test/toc,{\"headers\":{\"User-Agent\":\"URL级UA\"}}"
        _ = try engine.toc(info)

        let req = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(req.headers["User-Agent"], "URL级UA", "URL 级应替换源级")
        XCTAssertNil(req.headers["X-Src"], "⭐ 源级 header 应被【替换】掉（不是合并）")
    }

    // MARK: - ③ 三种写法都要认

    /// ⚠️ 站方有三种写法 ⇒ 都要认
    func testHeaderFormats() throws {
        // ① JSON 对象
        XCTAssertEqual(SourceEngine.parseSourceHeader("{\"A\":\"1\"}")["A"], "1")
        // ② JSON 字符串（Legado 官方写法）
        XCTAssertEqual(SourceEngine.parseSourceHeader("\"{\\\"A\\\":\\\"2\\\"}\"")["A"], "2")
        // ③ 原始头格式
        XCTAssertEqual(SourceEngine.parseSourceHeader("A: 3\nB: 4")["B"], "4")
        // ⚠️ 解析不出来 ⇒ 空，**不炸**
        XCTAssertTrue(SourceEngine.parseSourceHeader("这不是 JSON 也不是头").isEmpty)
        XCTAssertTrue(SourceEngine.parseSourceHeader(nil).isEmpty)
    }

    // MARK: - ④ 没有 header ⇒ 不受影响（防回归）

    func testNoHeaderMeansNoHeaders() throws {
        let (engine, transport) = try makeEngine(nil)
        var info = BookInfo()
        info.bookUrl = "https://example.test/toc"
        _ = try engine.toc(info)
        let req = try XCTUnwrap(transport.requests.first)
        XCTAssertTrue(req.headers.isEmpty, "源没给 header ⇒ 不该自己加头")
    }
}
