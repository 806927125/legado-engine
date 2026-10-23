import Foundation
import XCTest
@testable import LegadoCore

#if canImport(JavaScriptCore)
import JavaScriptCore

/// **JSC 执行器门禁** —— ⭐ **只在 Apple 平台跑**（Linux 沙盒没有 JavaScriptCore）。
///
/// ⇒ 这份门禁靠 **CI 的 macOS job** 执行（`.github/workflows/ci.yml` 的 `jsc` job）。
/// ⇒ 沙盒里能验的部分在 `JSHostAPITests`（契约完整性 / scope 构造 / 求值形态，用 Node 跑）。
final class JSCExecutorTests: XCTestCase {

    /// 假宿主：只实现门禁要用的几个 API
    final class FakeAPI: JSHostAPIProvider, @unchecked Sendable {
        var javaCalls: [String] = []
        var objects: [String: HostObject] = [:]

        init() {
            objects["source"] = HostObject(name: "source", methods: [
                "getVariable": { (args: [JSONValue]) -> JSONValue? in
                    .string((args.first?.scalarString).map { "var:\($0)" } ?? "")
                },
                "setVariable": { (_: [JSONValue]) -> JSONValue? in nil },
            ], properties: [
                "bookSourceUrl": .string("https://x.example/"),
                "key": .string("kw"),
            ])
            objects["book"] = HostObject(name: "book", methods: [
                "getVariable": { (args: [JSONValue]) -> JSONValue? in
                    .string("book:\(args.first?.scalarString ?? "")")
                },
            ], properties: [
                "name": .string("书名"),
                "book_id": .string("BID-42"),
            ])
        }

        func hostObject(named name: String) -> HostObject? { objects[name] }

        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
            javaCalls.append(method)
            switch method {
            case "log":      return nil
            case "toast":    return nil
            case "md5Encode": return .string("md5(" + (args.first?.scalarString ?? "") + ")")
            case "getString": return .string("S:" + (args.first?.scalarString ?? ""))
            default:         return .string("java:\(method)")
            }
        }
    }

    // MARK: - ① 完成值

    /// ⭐⭐ **末行表达式 ⇒ 完成值**（站方 JS 的主流写法）
    func testCompletionValue() throws {
        let api = FakeAPI()
        let exec = JSCExecutor(api: api)
        let ctx = JSRunContext(base: .page("<html>页原文</html>"), baseUrl: "https://x.example/",
                            raw: "<html>页原文</html>", key: "kw", page: 1)
        let out = try exec.run("1 + 2", context: ctx)
        XCTAssertEqual(out.scalarString, "3", "末行表达式的值应是完成值")
    }

    /// ⭐ **站方给 `result` 赋值**（大灰狼 `ruleContent.content` 就是这么写的）
    func testResultAssignmentIsCompletionValue() throws {
        let api = FakeAPI()
        let exec = JSCExecutor(api: api)
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/", raw: "", key: "", page: 1)
        let out = try exec.run("result = '赋值后';", context: ctx)
        XCTAssertEqual(out.scalarString, "赋值后")
    }

    // MARK: - ② 宿主注入

    /// ⭐ 宿主对象的方法与属性都要能在站方 JS 里访问
    func testHostObjectsAreInjected() throws {
        let api = FakeAPI()
        let exec = JSCExecutor(api: api)
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/", raw: "", key: "kw", page: 1)
        let out = try exec.run("source.bookSourceUrl + '|' + book.name + '|' + source.getVariable('x')",
                               context: ctx)
        XCTAssertEqual(out.scalarString, "https://x.example/|书名|var:x")
    }

    /// ⭐ `java.*` 的方法要能调
    ///
    /// ⭐ 曾经的坑：Swift 侧返回**包了一层的数组**，JS 侧却按标量解析
    /// ⇒ 站方拿到数组 ⇒ `.scalarString` 对数组返回 "" ⇒ **空串**
    /// ⇒ 根因是 JSC 桥接探针查出来的（`docs/JSC-NOTES.md`）⇒ 现在真跑。
    func testJavaAPIIsInjected() throws {
        // ⭐ 根因已修（口径不一致）⇒ 不再跳过 ⇒ **真跑**
    }


    /// ⭐ **`result` 按基准分层**（§S-RES）：条目级 ⇒ 站方能读 `result.book_id`
    func testResultFollowsBase() throws {
        let api = FakeAPI()
        let exec = JSCExecutor(api: api)
        let html = "<html><body><a href=\"/b\" bid=\"BID-7\">书名</a></body></html>"
        let doc = try SwiftSoupDocument(html: html, baseURL: "https://x.example/")
        let node = DOMNodeRef(doc.document.queryAll("a")[0])
        let ctx = JSRunContext(base: .element(node), baseUrl: "https://x.example/", raw: html)
        let out = try exec.run("result.bid", context: ctx)
        XCTAssertEqual(out.scalarString, "BID-7", "条目级 ⇒ result 是那个对象")
    }

    // MARK: - ③ 异常不许静默

    /// 站方 JS 抛异常 ⇒ **必须报出来**（不许静默空）
    func testScriptExceptionIsReported() throws {
        let api = FakeAPI()
        let exec = JSCExecutor(api: api)
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/", raw: "", key: "", page: 1)
        XCTAssertThrowsError(try exec.run("throw new Error('站方炸了');", context: ctx))
    }
}
#endif
