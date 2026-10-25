import Foundation
import XCTest
@testable import LegadoCore

#if canImport(JavaScriptCore)
import JavaScriptCore

/// ⭐⭐⭐⭐⭐ **JSC 后端专属门禁**（2026-10-26 真机回归实证）
///
/// ⚠️⚠️⚠️ **为什么必须单独写**（这是今天最大的洞）：
///   · Linux 沙盒**没有 JavaScriptCore** ⇒ 沙盒门禁跑的是 **Node 后端** ⭐⭐⭐
///   · **真机跑的是 JSC 后端** ⇒ ⇒ **JSC 路径的语义沙盒完全没覆盖** ⭐⭐⭐
///   ⇒ 沙盒全绿 ≠ 真机对 ⇒ 本文件是**唯一能在 macOS CI 上验 JSC 的地方** ⭐⭐⭐
///
/// ────────────────────────────────────────────────────────────
/// 事故（JSC 侧的三级兜底「跑到有值为止」）
/// ────────────────────────────────────────────────────────────
///   第一级是 `(function(){ return eval(code); })()`
///   ⇒ **eval 的完成值对「末行表达式」风格返回 undefined**
///     （`eval("var a=1; a")` ⇒ undefined；只有纯表达式 `eval("1+2")` 才有值）
///   ⇒ ⇒ 必然要跑第二级、第三级 ⇒ **站方 JS 在真机上被执行 2~3 次**！⭐⭐⭐
///   ⇒ ⇒ ① `java.ajax` 被调 2~3 次 ⇒ **限流打爆**（番茄 3 次/天）⭐⭐⭐
///   ⇒ ⇒ ② 引擎日志写 2~3 倍 ⇒ **写盘翻倍** ⇒ 撞 iOS diskwrites 限额 ⇒ 被杀 ⭐⭐⭐
///   ⇒ ⇒ ③ 站方 JS 的**副作用**重复执行 ⇒ 变量乱 / 结果错
///     ⇒ 表现为「**以前能加载、换引擎后不行了**」⭐⭐⭐
///
/// ⇒ 修法：**静态选形态**（对象字面量 ⇒ 整段当表达式；其它 ⇒ Script 优先，
///   **只有语法错**才换函数体形态）⇒ **只执行一次**。
///   ⭐ 与 Node 后端（`NodeJSExecutor.runEval`）**同款** ⇒ 两边语义一致。
final class JSCExecutionShapeTests: XCTestCase {

    /// ⭐⭐⭐ **会记账的宿主**（统计 `java.ajax` 被调了几次）
    final class CountingAPI: JSHostAPIProvider, @unchecked Sendable {
        var javaCalls: [String] = []
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
            javaCalls.append(method)
            if method == "ajax" { return .string("{\"ok\":1}") }
            return .string("host:" + method)
        }
    }

    private func ctx(_ raw: String = "<html>x</html>") -> JSRunContext {
        JSRunContext(base: .page(raw), baseUrl: "https://x.example/", raw: raw,
                     key: "kw", page: 1)
    }

    // MARK: - ① 站方 JS 只执行一次（副作用不重复）

    /// ⭐⭐⭐⭐⭐ **核心回归**：站方 JS 的副作用**只该发生一次**
    ///
    /// ⚠️ 以前 JSC 侧「跑到有值为止」⇒ 同一个 JS **跑 2~3 次**
    ///   ⇒ `source.putVariable` / `cache.put` / `cookie.set` 重复执行
    ///   ⇒ 而且 `java.ajax` 重复发请求 ⇒ 限流打爆 ⭐⭐⭐
    func testStationJSExecutesOnlyOnce() throws {
        let exec = JSCExecutor(api: CountingAPI())
        let c = ctx()
        // ⭐ 站方 JS 里放一个会累加的副作用 ⇒ 跑几次就加几次
        let code = "globalThis.__qrSideEffect = (globalThis.__qrSideEffect || 0) + 1; 'ok'"
        _ = try exec.run(code, context: c)
        // ⭐⭐⭐ **必须 markGlobalsAsBaseline**（引擎的 `loadJsLib` 就是这么做的）
        //   ⇒ 否则每次求值前的「全局治理」会把 `__qrSideEffect` **置 undefined** ⇒ 计数 0
        //   ⇒ ⇒ 那不是「执行两次」，而是「全局被清」⇒ 两者要分清 ⭐⭐⭐
        exec.markGlobalsAsBaseline()
        let after = try exec.run("String(globalThis.__qrSideEffect || 0)", context: c)
        XCTAssertEqual(after.scalarString, "1",
                       "⭐⭐⭐ 站方 JS 必须【只执行一次】（副作用计数应=1）"
                       + "⇒ 否则副作用重复 ⇒ 真机回归的根因")
    }

    /// ⭐⭐⭐ **ajax 也只能调一次**（限流的直接防线）
    func testAjaxCalledOnlyOnce() throws {
        let api = CountingAPI()
        let exec = JSCExecutor(api: api)
        let c = ctx()
        _ = try exec.run("java.ajax('https://x.example/a')", context: c)
        let ajaxCount = api.javaCalls.filter { $0 == "ajax" }.count
        XCTAssertEqual(ajaxCount, 1,
                       "⭐⭐⭐ java.ajax 只能调 1 次（实际 \(ajaxCount) 次）⇒ 否则限流打爆")
    }

    // MARK: - ② 三种站方写法都要能出值（改形态选择后不能退化）

    /// ⭐ **末行表达式**（Legado 主语义）
    func testLastExpressionStillWorks() throws {
        let exec = JSCExecutor(api: CountingAPI())
        let v = try exec.run("1 + 2", context: ctx())
        XCTAssertEqual(v.scalarString, "3", "末行表达式必须出值")
    }

    /// ⭐⭐⭐ **顶层 `return`**（站方真的这么写 ⇒ 大灰狼的 tocUrl 就是）
    func testTopLevelReturnStillWorks() throws {
        let exec = JSCExecutor(api: CountingAPI())
        let v = try exec.run("return 'id=' + '7';", context: ctx())
        XCTAssertEqual(v.scalarString, "id=7", "顶层 return 必须出值")
    }

    /// ⭐⭐⭐ **对象字面量**（站方把它当规则用）
    func testObjectLiteralStillWorks() throws {
        let exec = JSCExecutor(api: CountingAPI())
        let v = try exec.run("{ name: '书名', author: '作者' }", context: ctx())
        XCTAssertEqual(v.scalarString, "书名", "对象字面量必须出值（取 name）")
    }

    /// ⭐⭐⭐ **`var` + 末行**（大灰狼 jsLib 的常见形态）
    func testVarThenExpressionStillWorks() throws {
        let exec = JSCExecutor(api: CountingAPI())
        let v = try exec.run("var b = 5; b * 2", context: ctx())
        XCTAssertEqual(v.scalarString, "10", "var + 末行表达式必须出值")
    }

    /// ⭐⭐⭐ **函数体内的 return 不该被误判成「顶层 return」**
    /// （静态判断「有没有 return」会误判 ⇒ 整条规则死 ⇒ 用「抛语法错才换形态」）
    func testReturnInsideFunctionNotMisjudged() throws {
        let exec = JSCExecutor(api: CountingAPI())
        let v = try exec.run("(function(){ return []; })()", context: ctx())
        XCTAssertFalse(v.scalarString.isEmpty, "函数体内的 return 必须正常出值")
    }

    /// ⭐⭐⭐ **语法错要能报出来**（不是静默空）
    func testRealSyntaxErrorStillThrows() throws {
        let exec = JSCExecutor(api: CountingAPI())
        XCTAssertThrowsError(try exec.run("this is ) not ( valid js", context: ctx()),
                             "真语法错必须抛（不许静默空 ⇒ 否则规则静默失效）")
    }

    /// ⭐⭐⭐ **scope 变量仍然可见**（`result` / `baseUrl` / `source`）
    func testScopeStillVisible() throws {
        let exec = JSCExecutor(api: CountingAPI())
        let v = try exec.run("String(result)", context: ctx("<html>hello</html>"))
        XCTAssertEqual(v.scalarString, "<html>hello</html>", "scope 里的 result 必须可见")
    }
}
#else
/// ⭐⭐⭐ **Linux 上整个文件跳过**（没 JSC ⇒ **没验到**，不等于通过）
final class JSCExecutionShapeTests: XCTestCase {
    func testSkippedOnLinuxBecauseNoJSC() {
        print("⏭️ 跳过：Linux 没有 JavaScriptCore ⇒ JSC 路径**没验到**（不等于通过）")
    }
}
#endif
