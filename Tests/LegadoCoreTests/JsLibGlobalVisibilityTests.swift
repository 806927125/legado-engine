import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **jsLib 全局可见性的端到端探针**（2026-10-26 真机回归实证）
///
/// ⚠️ 现象：站方 jsLib 定义的 `hjmDec` 在**规则求值时不可见**
///   ⇒ 站方 `catch(e){return []}` 吞掉 ⇒ **0 本书**（JM小说真机症状）⭐⭐⭐
///
/// ⭐ 这个探针在 **Node 后端**跑（Linux 沙盒可跑）⇒
///   ⇒ **能在本地复现「导出 + 基线 + 全局治理」这条链** ⇒ 不用等 macOS CI ⭐⭐⭐
final class JsLibGlobalVisibilityTests: XCTestCase {

    /// ⭐⭐⭐⭐⭐ **核心**：加载 jsLib ⇒ 规则求值时必须能调到 jsLib 的函数
    func testJsLibGlobalsVisibleToRulesAfterLoad() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 显式 SKIP（不等于通过）")
        let js = try NodeJSExecutor()
        let lib = """
var K64='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function b64ToBytes(x){return x;}
function hjmDec(s){if(s===null||s===undefined||s==='')return '';return 'dec:'+s;}
"""
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        // ⭐⭐⭐ **必须先 markGlobalsAsBaseline**（loadJsLib 就是这么做的）
        _ = try js.runGlobal(lib, context: ctx)
        js.markGlobalsAsBaseline()

        let v = try js.run("typeof hjmDec", context: ctx)
        XCTAssertEqual(v.scalarString, "function",
                       "⭐⭐⭐ jsLib 的全局在规则求值时必须可见（否则 0 本书）")

        let v2 = try js.run("hjmDec('abc')", context: ctx)
        XCTAssertEqual(v2.scalarString, "dec:abc", "⭐⭐⭐ 规则里必须能【调】jsLib 的函数")
    }

    /// ⭐⭐⭐ **导出代码长啥样**（诊断用）
    func testShowExport() throws {
        let lib = "var K64='ABC';\nfunction hjmDec(s){return s;}\nlet foo=1;"
        print("=== 导出结果 ===")
        print(JSScopeBuilder.withExplicitGlobalExport(lib))
    }
}
