#if canImport(JavaScriptCore)
import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **站方 JS 的作用域语义** —— 真机栽过（2026-10-23 🍅大灰狼聚合）
///
/// ⚠️ **症状**：`SyntaxError: Can't create duplicate variable: 'device_type'`
///   ⇒ 大灰狼的 `exploreUrl` 里有 `let device_type = '安卓';`
///   ⇒ 以前站方代码是**直接拼接后在 JSContext 全局执行** ⇒ `let` 进了全局
///   ⇒ 同一段代码再跑一次 ⇒ **重复声明** ⇒ 整条规则炸 ⭐
///
/// ⚠️ **老引擎为什么没事**：站方代码跑在**函数作用域**里 ⇒ `let` 是局部的
///
/// ⇒ 现在两个入口、两种语义：
/// | 入口 | 作用域 | 谁用 |
/// |---|---|---|
/// | `run`（eval 包一层） | **局部** | 普通规则求值 |
/// | `runGlobal`（间接 eval） | **全局** | **站方 jsLib**（规则要调它的函数）|
///
/// ⚠️ **这些门禁只在 Apple 平台编**（Linux 没有 JSC）⇒ 由 CI 的 `jsc` job（macOS）跑 ⭐
final class JSCScopeSemanticsTests: XCTestCase {

    private func makeExecutor() -> JSCExecutor {
        let api = TestHostAPI()
        return JSCExecutor(api: api)
    }

    /// 空的宿主 API（测试里站方代码不碰宿主）
    private struct TestHostAPI: JSHostAPIProvider {
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? { nil }
    }

    // MARK: - ① 同一段含 `let` 的代码跑两次不许炸（⭐ 这次的根因）

    func testRepeatedLetDeclarationDoesNotCrash() throws {
        let js = makeExecutor()
        let code = "let device_type = '安卓'; device_type;"
        let ctx = JSRunContext(base: .page(""))
        // ⭐ 第一次
        let first = try js.run(code, context: ctx)
        XCTAssertEqual(first.scalarString, "安卓")
        // ⭐⭐⭐ **第二次（以前这里炸 `Can't create duplicate variable`）**
        let second = try js.run(code, context: ctx)
        XCTAssertEqual(second.scalarString, "安卓", "⭐ 同一段代码跑两次必须都成功")
        // 第三次也来
        _ = try js.run(code, context: ctx)
    }

    // MARK: - ② 完成值仍然拿得到（不能为了修作用域把完成值弄丢）

    func testCompletionValueStillWorks() throws {
        let js = makeExecutor()
        let ctx = JSRunContext(base: .page(""))
        XCTAssertEqual(try js.run("1 + 2", context: ctx).scalarString, "3")
        XCTAssertEqual(try js.run("'a' + 'b'", context: ctx).scalarString, "ab")
        // 站方常见形态：赋值表达式的值就是赋的值
        XCTAssertEqual(try js.run("result = String(123);", context: ctx).scalarString, "123")
    }

    // MARK: - ③ scope 变量照样可见（eval 在闭包里）

    func testScopeVariablesVisible() throws {
        let js = makeExecutor()
        let ctx = JSRunContext(base: .page("<html>整页原文</html>"), baseUrl: "https://x.example.com/")
        let v = try js.run("String(result) + '|' + baseUrl", context: ctx)
        XCTAssertTrue(v.scalarString.contains("整页原文"), "result 要看得见：\(v.scalarString)")
        XCTAssertTrue(v.scalarString.contains("x.example.com"), "baseUrl 要看得见：\(v.scalarString)")
    }

    // MARK: - ④ jsLib 的全局仍然可用（规则要调 jsLib 定义的函数）

    func testJsLibGlobalsRemainVisible() throws {
        let js = makeExecutor()
        let ctx = JSRunContext(base: .page(""))
        // ⭐ jsLib 用**间接 eval** 加载 ⇒ 定义进全局
        _ = try js.runGlobal("function stationHost() { return 'HOST-OK'; } var stationVar = 42;", context: ctx)
        // ⇒ 之后的规则求值（局部 eval）**照样能看到**全局
        let v = try js.run("stationHost() + '|' + stationVar", context: ctx)
        XCTAssertEqual(v.scalarString, "HOST-OK|42", "⭐ jsLib 定义的全局必须能被规则看到")
    }

    // MARK: - ⑤⭐⭐ Java 兼容层（JavaImporter / Packages.*）

    /// ⭐⭐⭐ **站方 JS 的 Java 兼容层必须可用**
    ///
    /// ⚠️ **真机栽过**（🍅大灰狼聚合）：大灰狼的 jsLib 第一行是
    ///   `var javaImport = CompatibilityUtils.safeImport(new JavaImporter());`
    /// ⇒ 没有 `JavaImporter` ⇒ **`new` 抛错** ⇒ **jsLib 整个加载失败**
    /// ⇒ 站方 JS 走兜底分支 ⇒ 分类里冒出「未分组」假分类 ⇒ **整本书打不开** ⭐
    func testJavaCompatLayerIsAvailable() throws {
        let js = makeExecutor()
        let ctx = JSRunContext(base: .page(""))
        let v = try js.run("typeof JavaImporter + '|' + typeof Packages", context: ctx)
        XCTAssertEqual(v.scalarString, "function|object", "⭐ JavaImporter / Packages 必须存在")
    }

    /// ⭐⭐ **大灰狼实际用到的那几个类**（真实语料统计）
    func testPackagesClassesUsedByAggregateSource() throws {
        let js = makeExecutor()
        let ctx = JSRunContext(base: .page(""))
        let v = try js.run(
            "typeof Packages.io.legato.kazusa.utils.TimeoutCancellationException + '|' + "
            + "typeof Packages.android.util.Base64.encodeToString + '|' + "
            + "typeof Packages.java.lang.Thread.sleep",
            context: ctx)
        XCTAssertEqual(v.scalarString, "function|function|function",
                       "⭐ 大灰狼用到的 3 个 Packages 类必须都在")
    }

    // MARK: - ⑥ jsLib 的全局不会被「每次求值前清全局」清掉

    func testJsLibGlobalsSurviveRepeatedRuns() throws {
        let js = makeExecutor()
        let ctx = JSRunContext(base: .page(""))
        _ = try js.runGlobal("var stationKeep = 'KEEP';", context: ctx)
        js.markGlobalsAsBaseline()
        for _ in 0..<3 {
            let v = try js.run("stationKeep", context: ctx)
            XCTAssertEqual(v.scalarString, "KEEP", "⭐ jsLib 的全局要长期保留")
        }
    }
}
#endif
