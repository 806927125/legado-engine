import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **URL 选项全集**门禁（2026-11-18 · 对齐 Legado/legado-E/栖阅）
///
/// 背景：「同个书源轻阅不行、柴阅可以」的一类结构性原因：
/// 轻阅原来只支持 `method` / `headers` / `body` 三个选项键，
/// 而 **legado-E 的 `AnalyzeUrl`** 与**栖阅的 17 键**高度一致 ⇒ 柴阅能做、轻阅不能。
///
/// 判据：**每个键都要能被解析出来并透传到宿主**（宿主才是真发请求的人）。
final class UrlOptionsContractTests: XCTestCase {

    // MARK: ① 解析

    func testParsesAllOptions() {
        let raw = #"https://x.com/s?k=1,{"method":"POST","headers":{"Referer":"https://x.com/"},"body":"a=1","charset":"gbk","retry":2,"useWebView":true,"webJs":"result","bodyJs":"java.getString('x')","dnsIp":"1.2.3.4","serverID":"s1","webViewDelayTime":2,"proxy":"http://p:8080","type":"qingtian2","initialHeaderMap":{"A":"b"},"requestContextVariables":{"c":"d"},"sourceRegex":"<a>(.*?)</a>","overrideUrlRegex":"\\d+","requestTimeout":15}"#
        let b = URLBuilder.parse(raw, baseUrl: "https://x.com/")
        XCTAssertEqual(b.method, "POST")
        XCTAssertEqual(b.headers["Referer"], "https://x.com/")
        XCTAssertEqual(b.body, "a=1")
        XCTAssertEqual(b.charset, "gbk", "⭐⭐⭐ charset 必须解析出来（老站乱码的根因）")
        XCTAssertEqual(b.retry, 2, "⭐⭐⭐ retry 必须解析出来（柴阅有重试、轻阅没有）")
        XCTAssertTrue(b.useWebView)
        XCTAssertEqual(b.webJs, "result")
        XCTAssertEqual(b.bodyJs, "java.getString('x')")
        XCTAssertEqual(b.dnsIp, "1.2.3.4")
        XCTAssertEqual(b.serverID, "s1")
        XCTAssertEqual(b.webViewDelayTime, 2)
        XCTAssertEqual(b.proxy, "http://p:8080")
        XCTAssertEqual(b.type, "qingtian2")
        XCTAssertEqual(b.initialHeaderMap["A"], "b")
        XCTAssertEqual(b.requestContextVariables["c"], "d")
        XCTAssertEqual(b.sourceRegex, "<a>(.*?)</a>")
        XCTAssertEqual(b.overrideUrlRegex, "\\d+")
        XCTAssertEqual(b.requestTimeout ?? 0, 15, "⭐ 站方指定的超时必须生效")
    }

    func testDefaultsWhenNoOptions() {
        let b = URLBuilder.parse("https://x.com/s?k=1", baseUrl: "")
        XCTAssertEqual(b.charset, "")
        XCTAssertEqual(b.retry, 0)
        XCTAssertFalse(b.useWebView)
        XCTAssertNil(b.requestTimeout)
        XCTAssertEqual(b.url, "https://x.com/s?k=1")
    }

    // MARK: ② 透传到 HTTPRequest（宿主要拿得到）

    func testOptionsFlowIntoRequest() {
        let raw = #"https://x.com/s,{"charset":"gb2312","retry":3,"useWebView":true,"proxy":"http://p"}"#
        let built = URLBuilder.parse(raw, baseUrl: "")
        let req = HTTPRequest(built: built, timeout: 8)
        XCTAssertEqual(req.charset, "gb2312")
        XCTAssertEqual(req.retry, 3)
        XCTAssertTrue(req.useWebView)
        XCTAssertEqual(req.proxy, "http://p")
    }

    func testRequestTimeoutOverridesDefault() {
        let built = URLBuilder.parse(#"https://x.com/s,{"requestTimeout":25}"#, baseUrl: "")
        XCTAssertEqual(HTTPRequest(built: built, timeout: 8).timeout, 25)
        let noOpt = URLBuilder.parse("https://x.com/s", baseUrl: "")
        XCTAssertEqual(HTTPRequest(built: noOpt, timeout: 8).timeout, 8)
    }

    // MARK: ③ retry 的行为（站方语义：失败重试 N 次）

    /// ⭐ 计数用**引用类型**（struct 的 mutating 方法在协议实现里会报错）
    private final class AttemptBox: @unchecked Sendable {
        var count = 0
        let lock = NSLock()
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    func testRetryRetriesOnTransportFailure() throws {
        final class Flaky: HTTPTransport, @unchecked Sendable {
            let box = AttemptBox()
            func send(_ request: HTTPRequest) throws -> HTTPResponse {
                if box.bump() < 3 { throw SourceError.requestFailed(request.url, "boom") }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("ok".utf8), finalURL: request.url)
            }
        }
        let flaky = Flaky()
        let fetcher = PageFetcher(transport: flaky)
        let resp = try fetcher.fetch(rule: #"https://x.com/s,{"retry":2}"#, baseUrl: "")
        XCTAssertEqual(flaky.box.count, 3, "⭐⭐⭐ retry=2 ⇒ 最多试 3 次（1 + 2）")
        XCTAssertEqual(resp.statusCode, 200)
    }

    func testNoRetryWhenNotSpecified() throws {
        final class Flaky: HTTPTransport, @unchecked Sendable {
            let box = AttemptBox()
            func send(_ request: HTTPRequest) throws -> HTTPResponse {
                box.bump()
                throw SourceError.requestFailed(request.url, "boom")
            }
        }
        let flaky = Flaky()
        let fetcher = PageFetcher(transport: flaky)
        _ = try? fetcher.fetch(rule: "https://x.com/s", baseUrl: "")
        XCTAssertEqual(flaky.box.count, 1, "⭐ 没写 retry ⇒ 不重试（不偷偷多打站方）")
    }

    // MARK: ④ 回归：不带选项的普通 URL 不受影响

    func testPlainUrlUnaffected() {
        let b = URLBuilder.parse("https://x.com/a/b.html", baseUrl: "https://x.com/")
        XCTAssertEqual(b.url, "https://x.com/a/b.html")
        XCTAssertEqual(b.method, "GET")
        XCTAssertTrue(b.headers.isEmpty)
    }
}
