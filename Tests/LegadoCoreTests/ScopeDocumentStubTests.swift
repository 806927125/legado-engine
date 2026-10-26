import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **`document` 替身的门禁**（2026-10-26）
///
/// ──────────────────────────────────────────────────────────────
/// 为什么要它（老引擎有、新引擎没有 ⇒ 站方 JS 直接 ReferenceError）
/// ──────────────────────────────────────────────────────────────
///   · 老引擎的 scope 里 `document` 指向**当前页面的 doc**
///     （轻阅 `reference/js/engine.js` 注释原文：「base 传 page.doc ⇒ document 指向当前列表页」）
///   · 站方 **`jsLib` 里 99 处 `document.`**、**`loginUrl` 里 54 处**（大灰狼 / 番茄小说TS）
///   · 新引擎没有 `document` ⇒ **`document is not defined`** ⇒ jsLib 整个加载失败 ⇒ 规则链半残 ⭐⭐⭐
///
/// ⭐⭐⭐ **语义对齐老引擎**（不是「随便造个假对象」）：
///   · 站方那 117 处拿的都是**站方 App 自己的 UI 元素**（logList / loading / container / playBtn…）
///   · 老引擎在真机上也是 **null**（当前页是 API 响应/列表页 ⇒ 没有那些 id）
///   ⇒ ⇒ **返回 null 就是正解**（不是「更聪明」的假元素）⭐⭐⭐
///
/// ⭐ **真 DOM 能力（`querySelectorAll` 解析列表结构）**：老引擎有、**125 源语料 0 处真实用量**
///   ⇒ 现在返回空数组（**不抛**）⇒ 真能力记进「待吸收清单」⭐⭐⭐
///
/// ⭐⭐⭐ **两条路径都要有**（这是最容易漏的）：
///   ① `run`（规则求值）⇒ scope 前导里那份
///   ② `runGlobal`（**jsLib / loginUrl**）⇒ **全局上下文**里那份
///   ⇒ 只测 ① ⇒ **测不出 jsLib 那个洞** ⭐⭐⭐
final class ScopeDocumentStubTests: XCTestCase {

    // MARK: - ① scope 源码里必须有这个替身（纯 Swift ⇒ 任何平台都能验）

    func testDocumentStubSourceIsComplete() {
        // ⭐⭐⭐ **替身源码是单一真相**（JSC / Node 共用这一份 ⇒ 不会漂移）
        let src = JSScopeBuilder.documentStub
        XCTAssertTrue(src.contains("var document = {"),
                      "⭐⭐⭐ 替身源码里必须有 `var document = {`")
        XCTAssertTrue(src.contains("getElementById: function"),
                      "⭐⭐⭐ 必须有 getElementById（站方 117 处在用）")
        XCTAssertTrue(src.contains("querySelectorAll: function"),
                      "⭐⭐⭐ 必须有 querySelectorAll（站方 0 处用，但缺了会抛）")
        XCTAssertTrue(src.contains("createElement: function"),
                      "⭐⭐⭐ 必须有 createElement（番茄源在用）")
        XCTAssertTrue(src.contains("exitFullscreen: function"),
                      "⭐⭐⭐ 必须有 exitFullscreen（番茄源在用）")
    }

    // MARK: - ② 行为契约（**JSC / Node 跑同一份** ⇒ 不会漂移）

    func testNodeBackendMatchesDocumentContract() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable,
                          "⚠️【SKIP】没装 node ⇒ 本次没验 `document` 行为（**不等于通过**）")
        let exec = try NodeJSExecutor()
        try Self.assertContract(exec)
    }

    /// ⚠️⚠️ **不能复用别的测试类里的嵌套 `FakeAPI`**（`JSCContextReuseTests.FakeAPI` 是**嵌套类型**
    ///   ⇒ 跨文件不可见 ⇒ macOS CI 直接编译失败）⇒ 自己定义一个（2026-10-26 真机教训）⭐⭐⭐
    final class DocumentStubAPI: JSHostAPIProvider, @unchecked Sendable {
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? { .string("host:" + method) }
    }

    /// ⭐⭐⭐ **这里【不要】用 `#if canImport(JavaScriptCore)` 把整段挡掉**（2026-10-26 实证）：
    ///   挡掉 ⇒ **Linux 沙盒根本不编这段** ⇒ macOS 专属的类型错（`cannot find 'FakeAPI' in scope`）
    ///   ⇒ **在沙盒里完全看不见** ⇒ 只能等 macOS CI 才炸 ⇒ 白等一轮 ⭐⭐⭐
    ///   ⇒ 现在有 `JSCExecutor+NonAppleStub.swift` ⇒ **两边都能编** ⇒ 沙盒 3 秒就能抓 ⭐⭐⭐
    func testJSCBackendMatchesDocumentContract() throws {
        try XCTSkipUnless(JSCExecutor.isAvailable,
                          "⚠️【SKIP】本机没有 JavaScriptCore ⇒ 本次没验 JSC 侧（**不等于通过**）")
        let exec = JSCExecutor(api: DocumentStubAPI())
        try Self.assertContract(exec)
    }

    /// ⭐⭐⭐ **同一份契约**（Node 3 秒 / JSC 慢 ⇒ 但跑的是同一批期望值）
    private static func assertContract(_ exec: JSExecutor) throws {
        let ctx = JSRunContext(base: .page("<html>x</html>"), baseUrl: "https://x.example/")

        // —— 路径 ①：规则求值（scope 前导）
        for (probe, expected) in DocumentStubContract.probes {
            let v = try exec.run(probe, context: ctx)
            XCTAssertEqual(v.scalarString, expected,
                           "⭐⭐⭐ 探针 `\(probe)` 的结果不对（老引擎语义：\(expected)）")
        }

        // —— 路径 ②：全局（jsLib / loginUrl 走 runGlobal ⇒ **全局作用域**）
        XCTAssertEqual(try exec.runGlobal("typeof document", context: ctx).scalarString, "object",
                       "⭐⭐⭐ `document` 必须在**全局**（jsLib 走 runGlobal ⇒ 只放 scope 前导不够）")
        XCTAssertTrue(try exec.runGlobal("document.getElementById('logList')", context: ctx).isNull,
                      "⭐⭐⭐ 全局 document 的 getElementById 也要返回 null（不抛）")

        // —— ⭐⭐⭐ **顺序陷阱**：跑过规则【之后】全局治理不能把 `document` 清掉
        //   （`removeGlobals(notIn: baselineGlobals)` ⇒ 不在基线里的全局会被删）
        //   ⇒ 注入时机必须在**基线快照之前** ⇒ 否则「先跑规则、后加载 jsLib」就炸 ⭐⭐⭐
        XCTAssertEqual(try exec.runGlobal("typeof document", context: ctx).scalarString, "object",
                       "⭐⭐⭐ 跑过规则之后 `document` 必须还在（全局治理把它当垃圾清掉了）")

        // —— 站方 jsLib 的真实形状：加载一段用 document 的 jsLib ⇒ 不许抛
        let jsLib = """
        var QRHost = { log: function(m) { var el = document.getElementById('logList'); return m; } };
        """
        _ = try exec.runGlobal(jsLib, context: ctx)
        // ⭐⭐⭐⭐⭐ **必须重设全局基线**（2026-10-26 macOS CI 实证）
        //
        // ⚠️⚠️⚠️ **JSC 侧真实失败**：不重设基线 ⇒ `run` 开头的「清全局」把站方 jsLib 的
        //   `QRHost` **删掉** ⇒ 规则求值时 `QRHost.log is not a function` ⇒ 整条链死 ⭐⭐⭐
        //   ⇒ 真身流程（`SourceEngine.loadJsLib`）就是：runGlobal 之后 `markGlobalsAsBaseline()` ⭐⭐⭐
        //   ⇒ 门禁**照抄真身流程**（不是照抄我以为的流程）⭐⭐⭐
        exec.markGlobalsAsBaseline()
        XCTAssertEqual(try exec.run("QRHost.log('hi')", context: ctx).scalarString, "hi",
                       "⭐⭐⭐ 站方 jsLib（用 document 的那种）必须能正常加载并被规则调到")
    }
}

/// ⭐⭐⭐ **两个后端共用的期望值**（**单一真相** ⇒ JSC / Node 不会各跑各的）
enum DocumentStubContract {
    /// - 语义对齐老引擎：`getElementById` 在真机上也拿不到站方 UI 元素 ⇒ **null**
    static let probes: [(String, String)] = [
        ("typeof document", "object"),
        ("document.getElementById('logList') === null", "true"),
        ("document.querySelector('p') === null", "true"),
        ("document.querySelectorAll('p').length", "0"),
        ("typeof document.createElement('div')", "object"),
        ("document.createElement('div').setAttribute('id','x') === undefined", "true"),
        // ⭐ 同一个元素上 set 完再 get（**两个 createElement 是两个对象** ⇒ 别写成两条探针）
        ("var e = document.createElement('div'); e.setAttribute('id','x'); e.getAttribute('id')", "x"),
        ("typeof document.exitFullscreen", "function"),
        ("typeof document.addEventListener", "function"),
        ("document.fullscreenElement === null", "true")
    ]
}
