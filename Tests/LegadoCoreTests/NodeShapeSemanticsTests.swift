import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **形态语义契约 · Node 后端**（Linux 沙盒可跑 ⇒ 3 秒反馈）⭐⭐⭐⭐⭐
///
/// ⚠️ **为什么 Node 侧也要跑同一份契约**：
///   · JSC 侧**只有 macOS CI 能验** ⇒ 反馈慢
///   · Node 侧**沙盒就能验** ⇒ ⭐ **改完先在这里过一遍** ⇒ 再上 CI ⭐⭐⭐
///   · 两边跑**同一份契约** ⇒ **不可能漂移** ⭐⭐⭐
///
/// ⭐⭐⭐ **契约的期望值来自老引擎（轻阅 `rule-analyzer.js`）的实测语义** ⭐⭐⭐
final class NodeShapeSemanticsTests: XCTestCase {

    func testNodeBackendMeetsShapeSemanticsContract() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node")
        let js = try NodeJSExecutor()
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        try ShapeSemanticsContract.check("Node 后端") { code in
            try js.run(code, context: ctx)
        }
    }

    /// ⭐⭐⭐⭐⭐ **同一段含 `let` 的代码跑三次**（真机「重复声明」的老坑）⭐⭐⭐⭐⭐
    func testNodeBackendRepeatedLetDoesNotCrash() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node")
        let js = try NodeJSExecutor()
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        try ShapeSemanticsContract.checkRepeatedLet("Node 后端") { code in
            try js.run(code, context: ctx)
        }
    }
}
