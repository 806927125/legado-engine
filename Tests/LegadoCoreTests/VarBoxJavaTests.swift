import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **源级变量的门禁**（`java.getString` / `java.get` / `java.put`）
///
/// **125 源真实用量**：`getString` 63 处 · `get` 34 处 · `put` 23 处 ⇒ **120 处**
///
/// ⚠️⭐ **站方 `java.getString('$.status')` 的实参是【JSONPath】**，不是「读文件」
/// ⇒ 实参以 `$` 开头 ⇒ **对当前基准做 JSONPath**；否则 ⇒ 读源级变量。
final class VarBoxJavaTests: XCTestCase {

    private func engine() throws -> SourceEngine {
        let data = Data("{\"bookSourceName\":\"x\",\"bookSourceUrl\":\"https://example.test\"}".utf8)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        return SourceEngine(source: source, fetcher: PageFetcher(transport: MemTransport()))
    }

    final class MemTransport: HTTPTransport, @unchecked Sendable {
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data("<html/>".utf8), finalURL: request.url)
        }
    }

    // MARK: - ① `java.getString('$.x')` ⇒ 对基准做 JSONPath

    /// ⭐⭐ **实参是 JSONPath** ⇒ 对当前基准取值
    func testGetStringWithJSONPath() throws {
        let e = try engine()
        let base = RuleBase.json(.object([
            "status": .string("连载"),
            "score": .int(95),
            "nested": .object(["bid": .string("B-1")]),
        ]))
        XCTAssertEqual(e.engineJava("getString", [.string("$.status")], base)?.scalarString, "连载")
        XCTAssertEqual(e.engineJava("getString", [.string("$.score")], base)?.scalarString, "95")
        XCTAssertEqual(e.engineJava("getString", [.string("$.nested.bid")], base)?.scalarString, "B-1")
        // ⚠️ 取不到 ⇒ 空串（不是 nil —— nil = 不接管）
        XCTAssertEqual(e.engineJava("getString", [.string("$.nope")], base)?.scalarString, "")
    }

    // MARK: - ② `java.get` / `java.put` ⇒ 源级变量

    func testPutThenGet() throws {
        let e = try engine()
        // ⭐ `java.put(key, value)` ⇒ 写变量
        e.engineJava("put", [.string("bid"), .string("B-42")], .page(""))
        // ⭐ `java.get(key)` ⇒ 读回来
        XCTAssertEqual(e.engineJava("get", [.string("bid")], .page(""))?.scalarString, "B-42")
        // ⚠️ 没有的键 + 有默认值 ⇒ 默认值
        XCTAssertEqual(e.engineJava("get", [.string("nope"), .string("def")], .page(""))?.scalarString, "def")
        // ⚠️ 没有的键 + 没默认值 ⇒ 空串
        XCTAssertEqual(e.engineJava("get", [.string("nope")], .page(""))?.scalarString, "")
    }

    /// ⭐⭐⭐ **核心**：`java.put` 写的变量 ⇒ **后续规则读得到**（穿透）
    ///
    /// ⚠️ 以前 `EvalContext.vars` 是**值类型** ⇒ 在 struct 里改它传不出去
    /// ⇒ 站方 `java.put` 写的变量**后续规则读不到** ⇒ 「变量」名存实亡。
    func testPutIsVisibleToLaterRules() throws {
        let e = try engine()
        e.engineJava("put", [.string("xid"), .string("X-9")], .page(""))
        // ⭐ 走**正常求值路径**（`@get:{xid}`）⇒ 必须读得到
        let ev = Evaluator()
        let ctx = EvalContext(base: .page(""), varBox: e.varBox)
        let out = ev.evalOne("@get:{xid}", base: .page(""), ctx: ctx)
        XCTAssertEqual(out.value.text, "X-9",
                       "⭐⭐ java.put 写的变量，后续规则必须读得到（共享存储）")
    }

    /// ⭐ `@put:` 写的变量 ⇒ 站方 `java.get` 也读得到（**同一份存储**）
    ///
    /// ⚠️ `@put:{k:v}` 的 `v` 是**表达式**（`$.x` / 裸路径）⇒ 要有基准才取得到值
    func testAtPutIsVisibleToJavaGet() throws {
        let e = try engine()
        let ev = Evaluator()
        let base = RuleBase.json(.object(["v": .string("值V")]))
        let ctx = EvalContext(base: base, varBox: e.varBox)
        _ = ev.evalOne("@put:{myKey:$.v}", base: base, ctx: ctx)
        XCTAssertEqual(e.engineJava("get", [.string("myKey")], .page(""))?.scalarString, "值V",
                       "⭐ @put: 与 java.get 必须共用同一份存储")
    }

    /// ⚠️ `java.getString('key')`（不带 `$`）⇒ **读变量**，不做 JSONPath
    func testGetStringWithoutDollarReadsVariable() throws {
        let e = try engine()
        e.engineJava("put", [.string("novelId"), .string("N-7")], .page(""))
        XCTAssertEqual(e.engineJava("getString", [.string("novelId")], .page(""))?.scalarString, "N-7")
    }
}
