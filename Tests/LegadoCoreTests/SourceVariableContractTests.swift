import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **站方变量 / 书源变量 的通用契约**（2026-10-27）
///
/// ⚠️⚠️ **Legado 是两套**（这是「通用书源系统」的地基）：
///
/// | API | 语义 |
/// |---|---|
/// | `source.getVariable()` / `setVariable(str)` | **站方变量**（一整串） |
/// | `source.get(key)` / `put(key, value)` | **书源变量**（map） |
///
/// ⚠️ **混成一套 ⇒ 三个真 bug**：
///   ① 聚合源（UAA）把 token 存站方变量 ⇒ 请求头 `Bearer {"androidId":"…"}`
///      ⇒ 服务端 **403「无效JWT」** ⇒ **永远拿不到 token** ⭐⭐⭐
///   ② 聚合源（NovelHub）改一次发现页筛选（`setVariable(JSON…)`）⇒ **解锁态被冲掉** ⭐
///   ③ 站方 `setVariable(token)` 会把 `put` 存的项**整份冲掉** ⭐
///
/// ⚠️⚠️ **这份契约跟轻阅仓库那份一模一样**
///   （轻阅：`test/fixtures/source-variable-contract.json` + `test/source-variable-contract.test.js`）
///   ⇒ **两个实现跑同一份契约** ⇒ 谁漂移谁红 ⭐⭐⭐
final class SourceVariableContractTests: XCTestCase {

    private func makeSource() throws -> BookSource {
        try JSONDecoder().decode(BookSource.self, from: Data("""
        {"bookSourceName":"某源","bookSourceUrl":"https://src.example.com"}
        """.utf8))
    }

    // MARK: - ① 聚合源·大灰狼式：站方变量 = 发现页设置 JSON 串

    func testDahuanglangStyle_站方变量是设置JSON() throws {
        let source = try makeSource()
        let slot = TextSlot()
        let obj = SourceEngine.makeSourceObject(source, varBox: VarBox(), sourceVariable: slot)

        _ = obj.call("setVariable", [.string("{\"server\":\"https://api.example.com\",\"proxy\":\"\"}")])
        let variable = obj.call("getVariable", [])?.scalarString ?? ""
        XCTAssertEqual(variable, "{\"server\":\"https://api.example.com\",\"proxy\":\"\"}",
                       "站方变量 = 那一串（Legado 语义）")
    }

    // MARK: - ② 聚合源·NovelHub 式：站方变量存筛选 + 书源变量存解锁态（互不冲掉）

    func testNovelHubStyle_两套互不冲掉() throws {
        let source = try makeSource()
        let slot = TextSlot()
        let box = VarBox()
        let obj = SourceEngine.makeSourceObject(source, varBox: box, sourceVariable: slot)

        _ = obj.call("put", [.string("nhAuthed"), .string("HASH123")])
        _ = obj.call("setVariable", [.string("{\"gender\":\"1\"}")])

        XCTAssertEqual(obj.call("get", [.string("nhAuthed")])?.scalarString, "HASH123",
                       "⭐ setVariable 不能把 put 存的项冲掉（Legado 两套语义）")
        XCTAssertEqual(obj.call("getVariable", [])?.scalarString, "{\"gender\":\"1\"}",
                       "站方变量 = 筛选 JSON")
    }

    // MARK: - ③ UAA 式：站方变量 = token 串 + 书源变量 = aid

    func testUAAStyle_token不被map污染() throws {
        let source = try makeSource()
        let slot = TextSlot()
        let box = VarBox()
        let obj = SourceEngine.makeSourceObject(source, varBox: box, sourceVariable: slot)

        _ = obj.call("put", [.string("aid"), .string("42")])
        _ = obj.call("setVariable", [.string("TOKEN-ABC")])

        XCTAssertEqual(obj.call("getVariable", [])?.scalarString, "TOKEN-ABC",
                       "⭐ 站方变量 = token 串（**不是**整份 map ⇒ 请求头不会变成 `Bearer {…}`）")
        XCTAssertEqual(obj.call("get", [.string("aid")])?.scalarString, "42")
        XCTAssertEqual(box.get("aid"), "42", "书源变量独立存")
    }

    // MARK: - ④ 老宿主兜底：没给槽位 ⇒ 老语义（零影响）

    func testLegacyHost_没有槽位则保持老语义() throws {
        let source = try makeSource()
        let box = VarBox()
        box.set("server", "https://legacy.example.com")
        let obj = SourceEngine.makeSourceObject(source, varBox: box)   // ⭐ 不传槽位

        let whole = obj.call("getVariable", [])?.scalarString ?? ""
        XCTAssertTrue(whole.contains("server"),
                      "老宿主（没塞槽位）⇒ getVariable() 仍返回整份变量串（零影响）：\(whole)")
    }

    // MARK: - ⑤ 宿主每个 op 改槽位内容 ⇒ 已建好的 sourceObject 也看得见

    func testSlot是引用_宿主改text立刻可见() throws {
        let source = try makeSource()
        let slot = TextSlot("第一串")
        let obj = SourceEngine.makeSourceObject(source, varBox: VarBox(), sourceVariable: slot)
        XCTAssertEqual(obj.call("getVariable", [])?.scalarString, "第一串")

        slot.text = "第二串"          // ⭐ 宿主侧换 op 时改内容
        XCTAssertEqual(obj.call("getVariable", [])?.scalarString, "第二串",
                       "槽位是引用 ⇒ 宿主改 text 后 sourceObject 立刻看得见")
    }
}
