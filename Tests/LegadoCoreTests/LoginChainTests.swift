import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **登录链路门禁**（沙盒可跑的部分）
///
/// **站方真实用法**（125 源实测，只有 3 个源用登录）：
/// - 猫眼看书：`loginUrl` = 一大段 JS（定义 `function login()` / `get_type()`…）
///   + `loginUi` = **JSON 数组**（按钮列表）
/// - 番茄小说TS：`loginUrl` = JS + `loginUi` = **`@js:` 脚本**
/// - 聚合书库：`loginCheckJs` = 登录态检测 JS
///
/// ⚠️ JSC 那层（加载脚本 / 执行 login()）由 `JSLoginTests`（macOS CI）验。
final class LoginChainTests: XCTestCase {

    // MARK: - ① 模型解码

    /// ⭐ **书源里没有 login 字段** ⇒ 以前**整个登录链路都不存在**
    func testBookSourceDecodesLoginFields() throws {
        let json = """
        {
          "bookSourceName": "带登录的源",
          "bookSourceUrl": "https://x.example",
          "loginUrl": "function login(){ return 'ok'; }",
          "loginUi": "[{\\"name\\":\\"按钮\\",\\"type\\":\\"button\\",\\"action\\":\\"doIt()\\"}]",
          "loginCheckJs": "result.indexOf('已登录') >= 0",
          "loginInfo": { "user": "u1", "token": "t1" }
        }
        """
        let src = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        XCTAssertEqual(src.loginUrl, "function login(){ return 'ok'; }")
        XCTAssertNotNil(src.loginUi)
        XCTAssertEqual(src.loginCheckJs, "result.indexOf('已登录') >= 0")
        XCTAssertEqual(src.loginInfo?["user"], "u1")
        XCTAssertEqual(src.loginInfo?["token"], "t1")
    }

    /// ⚠️ **没有 login 字段的书源也要能解**（容错）
    func testBookSourceWithoutLoginFieldsDecodes() throws {
        let json = """
        { "bookSourceName": "普通源", "bookSourceUrl": "https://x.example" }
        """
        let src = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        XCTAssertNil(src.loginUrl)
        XCTAssertNil(src.loginUi)
        XCTAssertNil(src.loginCheckJs)
        XCTAssertNil(src.loginInfo)
    }

    // MARK: - ② `loginUi` 解析

    /// ⭐⭐ **`loginUi` 的 JSON 数组**（猫眼书看的形态）
    func testParseLoginUIJSONArray() {
        let raw = """
        [
          { "name": "🐈猫眼①", "type": "button", "action": "Source('first')" },
          { "name": "服务器", "type": "text", "hint": "填服务器", "viewName": "host",
            "default": "https://api.x" },
          { "name": "记住我", "type": "check", "viewName": "remember" }
        ]
        """
        let fields = SourceEngine.parseLoginUI(raw)
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(fields[0].name, "🐈猫眼①")
        XCTAssertEqual(fields[0].type, "button")
        XCTAssertEqual(fields[0].action, "Source('first')", "⭐ 按钮的 action 要保住（站方 JS）")
        XCTAssertEqual(fields[1].type, "text")
        XCTAssertEqual(fields[1].hint, "填服务器")
        XCTAssertEqual(fields[1].viewName, "host", "⭐ 输入框的键要保住（站方用它读 loginInfo）")
        XCTAssertEqual(fields[1].defaultValue, "https://api.x")
        XCTAssertEqual(fields[2].type, "check")
    }

    /// ⚠️ **坏 JSON ⇒ 空数组**（不许抛 —— 登录界面坏了不该让整个源挂掉）
    func testParseLoginUIBadJSONReturnsEmpty() {
        XCTAssertTrue(SourceEngine.parseLoginUI("不是 JSON").isEmpty)
        XCTAssertTrue(SourceEngine.parseLoginUI("{").isEmpty)
        XCTAssertTrue(SourceEngine.parseLoginUI("[]").isEmpty)
    }

    // MARK: - ③ `loginInfo` 存取

    /// ⭐ **登录信息**（站方 `source.getLoginInfoMap()` 读它）⇒ 存进 `KeyValueStorage`
    func testLoginInfoRoundTrip() throws {
        let storage = MemoryStorage()
        let json = """
        { "bookSourceName": "s", "bookSourceUrl": "https://x.example" }
        """
        let src = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: T()),
                                 storage: storage)

        XCTAssertTrue(engine.loadLoginInfo().isEmpty, "一开始没有登录信息")
        engine.saveLoginInfo(["user": "u1", "token": "t2"])
        let back = engine.loadLoginInfo()
        XCTAssertEqual(back["user"], "u1")
        XCTAssertEqual(back["token"], "t2")
        // ⭐ 存在 storage 里（宿主能直接读）
        XCTAssertNotNil(storage.string(forKey: SourceEngine.loginInfoKey))
    }

    // MARK: - ④ 引擎的 loginUI() 走通（JSON 形态）

    func testEngineLoginUIFromJSON() throws {
        let json = """
        { "bookSourceName": "s", "bookSourceUrl": "https://x.example",
          "loginUi": "[{\\"name\\":\\"B\\",\\"type\\":\\"button\\",\\"action\\":\\"x()\\"}]" }
        """
        let src = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: T()))
        let fields = try engine.loginUI()
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].action, "x()")
    }

    /// ⚠️ **没有 loginUi ⇒ 空数组**（不抛）
    func testEngineLoginUIWithoutSourceField() throws {
        let json = """
        { "bookSourceName": "s", "bookSourceUrl": "https://x.example" }
        """
        let src = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: T()))
        XCTAssertTrue(try engine.loginUI().isEmpty)
    }

    final class T: HTTPTransport, @unchecked Sendable {
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data(), finalURL: request.url)
        }
    }
}
