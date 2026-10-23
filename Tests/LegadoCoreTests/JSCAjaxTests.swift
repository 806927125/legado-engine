import Foundation
import XCTest
@testable import LegadoCore

#if canImport(JavaScriptCore)
import JavaScriptCore

/// ⭐⭐ **`java.ajax` 在真 JSC 里的门禁**（macOS CI 跑）
///
/// ⚠️ 沙盒那份（`AjaxEngineTests`）验的是**引擎侧逻辑**（请求构造 / `data:` 伪 URL）；
/// 这份验的是「**站方 JS 在 JSC 里真的能调 `java.ajax`**」——
/// ⇒ 这是**宿主不实现 `java.ajax` 也能跑**的关键证据 ⭐
///
/// ⭐ **这个文件整个在 `#if canImport(JavaScriptCore)` 内**
/// ⇒ Linux 沙盒**一个字节都不编译** ⇒ 只能靠 macOS CI 验
/// ⇒ ⚠️ 所以**别在里面放 Linux 能跑的东西**（会让人误以为验过了）
final class JSCAjaxTests: XCTestCase {

    /// 记录请求的假传输
    final class MemTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [HTTPRequest] = []
        var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        let body: String
        init(body: String) { self.body = body }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            lock.lock(); _requests.append(request); lock.unlock()
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8),
                                finalURL: request.url)
        }
    }

    /// 假宿主：**故意不实现 `java.ajax`** ⇒ 验证引擎接管了它
    final class NoAjaxAPI: JSHostAPIProvider, @unchecked Sendable {
        var javaCalls: [String] = []
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
            javaCalls.append(method)
            return .string("HOST-SHOULD-NOT-BE-CALLED")
        }
    }

    private func makeExec(_ transport: MemTransport) -> (JSCExecutor, NoAjaxAPI) {
        let api = NoAjaxAPI()
        let exec = JSCExecutor(api: api)
        exec.setEngineAPI { method, args in
            guard method == "ajax" else { return nil }
            var req = HTTPRequest(url: args.first?.scalarString ?? "", method: "GET")
            if let o = args.count > 1 ? args[1] : nil, case .object(let oo) = o {
                if let m = oo["method"]?.scalarString { req.method = m.uppercased() }
                if let b = oo["body"], !b.isNull { req.body = Data(b.scalarString.utf8) }
            }
            guard let resp = try? transport.send(req) else { return nil }
            return .string(String(data: resp.body, encoding: .utf8) ?? "")
        }
        return (exec, api)
    }

    // MARK: - ① 站方 JS 里能调 `java.ajax`

    /// ⭐⭐ **站方 JS 调 `java.ajax` ⇒ 拿到响应正文**
    func testJavaAjaxWorksInsideJSC() throws {
        let transport = MemTransport(body: "<html>页面正文</html>")
        let (exec, api) = makeExec(transport)
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        let out = try exec.run("java.ajax('https://x.example/api/list')", context: ctx)

        XCTAssertEqual(out.scalarString, "<html>页面正文</html>",
                       "⭐ JS 里 java.ajax 应返回响应正文")
        XCTAssertEqual(transport.requests.count, 1, "应发出过请求")
        XCTAssertFalse(api.javaCalls.contains("ajax"),
                       "⭐⭐ 引擎接管后**不该再问宿主**要 java.ajax")
    }

    // MARK: - ② 带 options（POST）

    /// ⭐ **第二个参数**（`{method, body}`）⇒ 站方 POST 能用
    func testJavaAjaxWithOptionsInJSC() throws {
        let transport = MemTransport(body: "{\"ok\":1}")
        let (exec, _) = makeExec(transport)
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        let out = try exec.run(
            "java.ajax('https://x.example/api/post', {method:'POST', body:'a=1'})",
            context: ctx)
        XCTAssertEqual(out.scalarString, "{\"ok\":1}")
        let req = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(req.method, "POST")
    }

    // MARK: - ③ 引擎侧纯计算（md5Encode 等）

    /// ⭐⭐ **`java.md5Encode` 在 JSC 里真能跑**（125 源里 233 处 ⇒ 用得最多的 API）
    func testMD5EncodeInJSC() throws {
        let api = NoAjaxAPI()
        let exec = JSCExecutor(api: api)
        exec.setEngineAPI { method, args in
            guard method == "md5Encode" else { return nil }
            return .string(Crypto.md5Hex(args.first?.scalarString ?? ""))
        }
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        let out = try exec.run("java.md5Encode('abc')", context: ctx)
        XCTAssertEqual(out.scalarString, "900150983cd24fb0d6963f7d28e17f72",
                       "⭐ MD5 官方测试向量")
        XCTAssertFalse(api.javaCalls.contains("md5Encode"),
                       "⭐⭐ 引擎接管后不该再问宿主")
    }

    // MARK: - ④ 失败 ⇒ undefined（不抛）

    /// ⚠️ 引擎 ajax 失败 ⇒ JS 侧拿 undefined ⇒ **不抛异常**
    func testJavaAjaxFailureYieldsUndefined() throws {
        let api = NoAjaxAPI()
        let exec = JSCExecutor(api: api)
        // ⭐ **返回 `.null` = 「我接管了，但这次失败」**
        // ⚠️ **返回 nil = 「我不接管」⇒ 落回宿主**（那是另一条语义，§S-JS-19）
        exec.setEngineAPI { _, _ in .null }   // 已接管但失败
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        let out = try exec.run("java.ajax('https://x.example/a')", context: ctx)
        XCTAssertTrue(out.isNull || out.scalarString.isEmpty,
                      "⭐ 失败时应是 null/undefined，实际：\(out)")
    }
}
#endif
