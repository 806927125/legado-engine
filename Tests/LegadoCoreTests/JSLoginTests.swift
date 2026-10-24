import Foundation
import XCTest
@testable import LegadoCore

#if canImport(JavaScriptCore)
import JavaScriptCore

/// ⭐⭐⭐ **登录链路的 JSC 门禁**（macOS CI 跑）
///
/// ⚠️⭐ **这条是整轮最关键的**：
///   JSC 上下文复用的代价是「每次求值前清掉相对基线新增的全局」
///   ⇒ 而站方 `loginUrl` 定义的 `function login()` / `function get_type()`
///   **恰恰就是要长期留在全局的** ⇒ 不处理 ⇒ 站方登录按钮点了就炸 ⭐
///
/// ⇒ 解法：**加载完站方脚本 ⇒ 调 `markGlobalsAsBaseline()`** ⇒ 新的基线
///   ⇒ 之后照常清理「相对新基线新增的」⇒ **站方的全局被保留** ✔
final class JSLoginTests: XCTestCase {

    final class FakeAPI: JSHostAPIProvider, @unchecked Sendable {
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
            .string("host:" + method)
        }
    }

    final class T: HTTPTransport, @unchecked Sendable {
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data("<html/>".utf8),
                                finalURL: request.url)
        }
    }

    private func makeEngine(loginUrl: String) throws -> (SourceEngine, JSCExecutor) {
        let json = """
        { "bookSourceName": "登录源", "bookSourceUrl": "https://x.example",
          "loginUrl": \(Self.jsLiteral(loginUrl)) }
        """
        let src = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        let exec = JSCExecutor(api: FakeAPI())
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: T()), js: exec)
        return (engine, exec)
    }

    /// 把 JS 源码安全地塞进 JSON 字符串
    private static func jsLiteral(_ code: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [code])
        // ⚠️⚠️⚠️ 2026-10-24：**必须返回【带引号的 JSON 文本】**
        //   ⇒ 以前返回的是**解码后的原文** ⇒ 嵌进 JSON 模板 ⇒ **不是合法 JSON** ⇒ 解码必炸
        //   ⇒ 而且 macOS/新 Foundation 上 `as! [String]` 还会先崩 ⇒ **这些用例从没通过过** ⭐
        let data = try! JSONSerialization.data(withJSONObject: code)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - ① ⭐⭐⭐ 站方 loginUrl 的全局必须活过后续求值

    /// ⭐⭐⭐ **核心**：加载 loginUrl ⇒ 之后跑一次普通规则求值（会清全局）
    ///   ⇒ 站方定义的 `function login()` **必须还在** ⇒ 能被调用
    func testLoginScriptGlobalsSurviveLaterEvaluations() throws {
        let (engine, _) = try makeEngine(loginUrl: """
        function get_type(){ return 'T1'; }
        function login(){ return 'LOGINED-' + get_type(); }
        """)
        XCTAssertTrue(try engine.loadLoginScript(), "⭐ loginUrl 应加载成功")

        // ⭐ 跑一次**普通规则求值**（内部会「清掉相对基线新增的全局」）
        let ev = Evaluator()
        let ctx = EvalContext(base: .page("<html/>"))
        _ = ev.evalOne("tag.p@text", base: .page("<html/>"), ctx: ctx)

        // ⭐⭐ 站方的 login() 必须还能调
        let out = try engine.performLogin()
        XCTAssertEqual(out, "LOGINED-T1",
                       "⭐⭐ loginUrl 定义的全局必须活过后续求值（否则登录按钮点了就炸）")
    }

    // MARK: - ② 反向：不重设基线 ⇒ 全局会被清掉（证明机制真的在起作用）

    /// ⚠️ **反向验证**：不调 `loadLoginScript`（不重设基线）⇒ 站方全局会被清
    /// ⇒ 这条证明「基线机制」不是摆设
    func testWithoutBaselineMarkGlobalsAreCleared() throws {
        let api = FakeAPI()
        let exec = JSCExecutor(api: api)
        // 直接跑 loginUrl（**不**调 markGlobalsAsBaseline）
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        _ = try exec.run("function myGlobalFn(){ return 1; }", context: ctx)
        // 再跑一次别的规则 ⇒ 相对基线新增的全局被清
        _ = try exec.run("1+1", context: ctx)
        let out = try exec.run("typeof myGlobalFn", context: ctx)
        XCTAssertEqual(out.scalarString, "undefined",
                       "（对照）没重设基线时，全局会被清掉 ⇒ 证明基线机制有效")
    }

    // MARK: - ③ 登录界面（`@js:` 形态）

    /// ⭐ **`loginUi` 的 `@js:` 形态**（番茄小说TS 的写法）⇒ 跑 JS 拿 JSON
    func testLoginUIFromJS() throws {
        let json = """
        { "bookSourceName": "登录源", "bookSourceUrl": "https://x.example",
          "loginUi": "@js: JSON.stringify([{name:'B',type:'button',action:'x()'}])" }
        """
        let src = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        let exec = JSCExecutor(api: FakeAPI())
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: T()), js: exec)
        let fields = try engine.loginUI()
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].action, "x()")
    }

    // MARK: - ④ 登录态检测

    /// ⭐ **`loginCheckJs`** ⇒ 对给定页面跑，返回原始结果
    func testCheckLoginRunsScript() throws {
        let json = """
        { "bookSourceName": "登录源", "bookSourceUrl": "https://x.example",
          "loginCheckJs": "result.indexOf('已登录') >= 0" }
        """
        let src = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        let exec = JSCExecutor(api: FakeAPI())
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: T()), js: exec)
        let out = try engine.checkLogin(pageText: "<html>已登录</html>",
                                        pageURL: "https://x.example/me")
        XCTAssertFalse(out.isEmpty, "⭐ loginCheckJs 应有返回值")
    }
}
#endif
