import Foundation
import XCTest
@testable import LegadoCore

#if canImport(JavaScriptCore)
import JavaScriptCore

/// ⭐⭐ **JSC 性能基准** —— 「每次新建 context」vs「复用 context」
///
/// ⚠️ **这不是门禁，是测量**（性能数字有波动 ⇒ 不该写成硬断言）
/// ⇒ 先拿到真实数字，再决定「上下文复用」值不值得做、怎么做。
///
/// ⚠️ Linux 沙盒**跑不了**（无 JavaScriptCore）⇒ 靠 **macOS CI** 出数字。
final class JSCPerfTests: XCTestCase {

    final class FakeAPI: JSHostAPIProvider, @unchecked Sendable {
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
            .string("ok")
        }
    }

    func testMeasureContextCreationVsReuse() throws {
        let api = FakeAPI()
        let exec = JSCExecutor(api: api)
        let ctx = JSRunContext(base: .page("<html>x</html>"), baseUrl: "https://x.example/",
                               raw: "<html>x</html>", key: "kw", page: 1)
        let n = 20

        // ① **现状**：每次 `run` 都新建一个 `JSContext`
        let t0 = Date()
        for _ in 0..<n { _ = try exec.run("1+1", context: ctx) }
        let perNew = Date().timeIntervalSince(t0) / Double(n)

        // ② **复用**：手工建一个 context，反复 eval
        let js = try XCTUnwrap(JavaScriptCore.JSContext())
        _ = js.evaluateScript("var result = 1; var baseUrl = 'https://x.example/';")
        let t1 = Date()
        for _ in 0..<n { _ = js.evaluateScript("var result = 1; var baseUrl = 'https://x.example/'; 1+1") }
        let perReuse = Date().timeIntervalSince(t1) / Double(n)

        // ③ **纯 eval**（不含 scope 注入）
        let t2 = Date()
        for _ in 0..<n { _ = js.evaluateScript("1+1") }
        let perBare = Date().timeIntervalSince(t2) / Double(n)

        print("[perf] 每次新建 context = \(String(format: "%.3f", perNew * 1000)) ms/次")
        print("[perf] 复用 context     = \(String(format: "%.3f", perReuse * 1000)) ms/次")
        print("[perf] 纯 eval（无注入）= \(String(format: "%.3f", perBare * 1000)) ms/次")
        print("[perf] ⇒ 复用能省 \(String(format: "%.1f", perNew / max(perReuse, 0.000001)))×")

        // ⭐ 保守断言：**复用不许比新建慢**（否则不值得做）
        XCTAssertLessThanOrEqual(perReuse, perNew * 1.5,
                                  "复用 context 比每次新建还慢 ⇒ 不值得做")
    }
}
#endif
