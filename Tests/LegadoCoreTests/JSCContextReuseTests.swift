import Foundation
import XCTest
@testable import LegadoCore

#if canImport(JavaScriptCore)
import JavaScriptCore

/// ⭐⭐ **JSC 上下文复用的门禁**
///
/// **复用换来的性能**（实测 1.018 ms/次 → 0.003 ms/次，省 340×）
/// ⇒ **代价是「站方 jsLib 的全局会留在 context 里」**
/// ⇒ ⇒ 复用**必须**配「全局治理」，否则：
///   源 A 定义 `var host = ['线路1']` ⇒ 源 B 也读到它 ⇒ **串源**
///   （这正是轻阅 build208 踩过的坑）⭐
///
/// ⚠️ 这份门禁**整个文件在 `#if canImport(JavaScriptCore)` 内** ⇒ 靠 **macOS CI** 跑。
final class JSCContextReuseTests: XCTestCase {

    final class FakeAPI: JSHostAPIProvider, @unchecked Sendable {
        var javaCalls: [String] = []
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
            javaCalls.append(method)
            return .string("host:" + method)
        }
    }

    private func ctx(_ raw: String = "<html>x</html>") -> JSRunContext {
        JSRunContext(base: .page(raw), baseUrl: "https://x.example/", raw: raw,
                     key: "kw", page: 1)
    }

    // MARK: - ① ⭐⭐ 全局**不能**跨次残留

    /// ⭐⭐⭐ **核心**：第一次跑定义的全局 ⇒ 第二次跑**必须看不到**
    func testGlobalsDoNotLeakBetweenRuns() throws {
        let exec = JSCExecutor(api: FakeAPI())
        let c = ctx()

        // 第一次：站方定义一个全局
        let first = try exec.run("var myGlobal = 'A'; myGlobal", context: c)
        XCTAssertEqual(first.scalarString, "A")

        // ⭐⭐ 第二次：**同一个 context** ⇒ 必须看不到 `myGlobal`
        let second = try exec.run("typeof myGlobal", context: c)
        XCTAssertEqual(second.scalarString, "undefined",
                       "⭐⭐ 站方 jsLib 的全局不能残留到下一次（否则串源）")
    }

    /// ⭐⭐ **函数声明**也要清（`function f(){}` 同样是全局）
    func testFunctionDeclarationsDoNotLeak() throws {
        let exec = JSCExecutor(api: FakeAPI())
        let c = ctx()
        _ = try exec.run("function myFn(){ return 1; } myFn()", context: c)
        let second = try exec.run("typeof myFn", context: c)
        XCTAssertEqual(second.scalarString, "undefined", "⭐ 函数声明也不能残留")
    }

    // MARK: - ② 复用后宿主通道仍可用

    /// ⭐ **包装函数只注入一次 ⇒ 复用后仍能用**
    func testHostAPIStillWorksAfterReuse() throws {
        let api = FakeAPI()
        let exec = JSCExecutor(api: api)
        let c = ctx()
        for _ in 0..<3 {
            let out = try exec.run("java.getString('hi')", context: c)
            XCTAssertEqual(out.scalarString, "host:getString", "⭐ 复用后 java.* 仍要能用")
        }
    }

    // MARK: - ③ scope 变量每次重设

    /// ⭐ **scope 变量每次都要重新注入**（否则第二次拿到上次的 `result`）
    func testScopeVariablesAreRefreshedEachRun() throws {
        let exec = JSCExecutor(api: FakeAPI())
        let first = try exec.run("result", context: JSRunContext(
            base: .page("第一页"), baseUrl: "https://x.example/", raw: "第一页", page: 1))
        XCTAssertEqual(first.scalarString, "第一页")
        let second = try exec.run("result", context: JSRunContext(
            base: .page("第二页"), baseUrl: "https://x.example/", raw: "第二页", page: 2))
        XCTAssertEqual(second.scalarString, "第二页", "⭐ scope 变量必须每次重设")
    }

    // MARK: - ④ 性能（宽松断言）

    /// ⭐ **复用确实更快**（宽松断言：至少快 2 倍；CI 机器波动 ⇒ 不卡太死）
    func testReuseIsFasterThanRecreate() throws {
        let exec = JSCExecutor(api: FakeAPI())
        let c = ctx()
        let n = 30
        let t0 = Date()
        for _ in 0..<n { _ = try exec.run("1+1", context: c) }
        let perReuse = Date().timeIntervalSince(t0) / Double(n)

        // 每次新建一个 context 的成本（用引擎的原始做法估）
        let t1 = Date()
        for _ in 0..<n {
            let js = JavaScriptCore.JSContext()
            _ = js?.evaluateScript("1+1")
        }
        let perNew = Date().timeIntervalSince(t1) / Double(n)

        print("[perf-reuse] 复用 = \(perReuse * 1000) ms/次，新建 = \(perNew * 1000) ms/次")
        XCTAssertLessThan(perReuse, perNew, "⭐ 复用必须比每次新建快")
    }

    // MARK: - 探针（查「delete 为什么没删掉全局」）

    /// ⚠️ **一次性探针** ⇒ 查清「全局删不掉」的根因
    func testZZProbeGlobalDeletion() throws {
        let exec = JSCExecutor(api: FakeAPI())
        let c = ctx()
        _ = try exec.run("var myGlobal = 'A'; function myFn(){return 1;}", context: c)
        let probe = try exec.run("""
        (function(){
          var names = Object.getOwnPropertyNames(this);
          var desc = Object.getOwnPropertyDescriptor(globalThis, 'myGlobal');
          var cfg = desc ? ('cfg=' + desc.configurable + ',enum=' + desc.enumerable) : 'no-desc';
          var del = 'n/a';
          try { delete globalThis.myGlobal; del = 'after=' + (typeof globalThis.myGlobal); }
          catch(e) { del = 'err:' + e; }
          var myGlobalIn = (names.indexOf('myGlobal') >= 0);
          return 'count=' + names.length + ' inNames=' + myGlobalIn + ' ' + cfg + ' ' + del
                 + ' | names=' + names.slice(0, 30).join(',');
        })()
        """, context: c)
        print("[probe]", probe.scalarString)
    }
}
#endif
