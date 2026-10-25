import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **Node 后端**（沙盒里没有 JSC ⇒ 用 Node 顶替）
final class NodeBackendTests: XCTestCase {
    func testNodeBackendRunsStationJS() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node")
        let js = try NodeJSExecutor()
        let jsLib = """
        var host = ['https://a.example.com'];
        function getArguments(a, k) { return { tab: '小说', server: host[0] }; }
        """
        try js.runGlobal(jsLib, context: JSRunContext(base: .page(""), baseUrl: "https://x"))
        let r = try js.run("getArguments('', '')",
                          context: JSRunContext(base: .page(""), baseUrl: "https://x"))
        // ⭐⭐⭐ **对象要用 `jsonValue` 看**（`scalarString` 对对象/数组是空串！2026-10-25 踩过）
        print("⭐ Node 后端结果 =", r.foundationValue)
        XCTAssertTrue(r.foundationValue is [String: Any],
                      "应返回对象，实际=\(r.foundationValue)")
    }
}
