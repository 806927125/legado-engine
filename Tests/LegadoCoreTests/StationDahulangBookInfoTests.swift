#if canImport(JavaScriptCore)
import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **真书源门禁（详情页 bookInfo）** —— 🍅大灰狼聚合
///
/// ⚠️⚠️ **这是 2026-10-24 真机「新引擎的详情是空的」的守门人**：
///   真机日志（用户诊断包）：
///   ```
///   [新引擎] 规则[$.book_name] 分支=JSONPath 失败=noMatch(reason: "JSONPath 未命中：$.book_name")
///   [新引擎] 规则[$.author]   分支=JSONPath 失败=noMatch
///   [引擎] 新引擎的「bookInfo」结果不可信（书名/书 URL 是空的）⇒ 回退老引擎
///   ```
///   ⇒ **分类已经对了（359 个）**，但**详情字段全取不到** ⇒ 整本书打不开
///
/// ⭐⭐⭐ **这条链的形状（站方 `ruleBookInfo.init`）**：
/// ```js
/// <js>
/// if (String(baseUrl).startsWith("data:")) {
///     let res = JSON.parse(java.hexDecodeToString(result));   // 解 data: 载荷
///     …
///     result = java.ajax(`${base_url}/detail?book_id=…`);      // 拿详情
///     JSON.parse(result);
/// }
/// result
/// </js>$.data
/// ```
/// ⇒ ⭐ **init 的 JS 完成值 = 详情 JSON 的【文本】** ⇒ 尾巴 `$.data` 要在**解析后的对象**上取
///   ⇒ 然后字段规则 `$.book_name` / `$.author` 要在 **init 的输出**上取（不是页原文）⭐⭐⭐
///
/// ⇒ 这条门禁用**真规则** + **真 jsLib** + **真 JSC** 跑**生产路径** `bookInfo()`
///   ⇒ 上面任何一环坏掉 ⇒ **必红** ⭐
final class StationDahulangBookInfoTests: XCTestCase {

    private static let fixtureDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/station")
    }()

    private func load(_ name: String) throws -> String {
        String(data: try Data(contentsOf: Self.fixtureDir.appendingPathComponent(name)),
               encoding: .utf8) ?? ""
    }

    /// 假传输（**不联网**）：任何 URL 都回同一份详情 JSON
    private struct DetailTransport: HTTPTransport, @unchecked Sendable {
        let body: String
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"],
                         body: Data(body.utf8), finalURL: request.url)
        }
    }

    private final class Host: JSHostAPIProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var vars = ""
        private func readVars() -> String { lock.lock(); defer { lock.unlock() }; return vars }
        private func writeVars(_ v: String) { lock.lock(); vars = v; lock.unlock() }

        func hostObject(named name: String) -> HostObject? {
            switch name {
            case "source":
                return HostObject(name: "source", methods: [
                    "getVariable": { [self] _ in .string(readVars()) },
                    "setVariable": { [self] args in
                        writeVars(args.first?.scalarString ?? ""); return .string("")
                    },
                    "getLoginInfoMap": { _ in .object([:]) },
                    "loginUi": { _ in .string("") },
                    "getKey": { _ in .string("") },
                    "header": { _ in .string("") },
                ])
            case "cookie":
                return HostObject(name: "cookie", methods: [
                    "getCookie": { _ in .string("") },
                    "setCookie": { _ in .string("") },
                    "removeCookie": { _ in .string("") },
                    "getKey": { _ in .string("") },
                ])
            default: return nil
            }
        }

        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
            switch method {
            case "deviceID": return .string("GT-DEVICE")
            case "androidId": return .string("GT-ANDROID")
            default: return .string("")
            }
        }
    }

    /// ⭐⭐⭐ 详情必须**真的有内容**（不是空、不是 "undefined"）
    func testRealStationBookInfoHasNameAndAuthor() throws {
        let rulesData = try Data(contentsOf:
            Self.fixtureDir.appendingPathComponent("dahulang-bookinfo-rules.json"))
        let rules = try JSONDecoder().decode([String: [String: String]].self, from: rulesData)
        let jsLib = try load("dahulang-jsLib.js")
        let detail = try load("dahulang-detail-response.json")
        let bookUrl = try load("dahulang-bookurl.txt")

        let src: [String: Any] = [
            "bookSourceName": "大灰狼详情门禁",
            "bookSourceUrl": "https://v5.langge.uk",
            "ruleBookInfo": rules["ruleBookInfo"] ?? [:],
        ]
        let source = try JSONDecoder().decode(BookSource.self,
                                              from: try JSONSerialization.data(withJSONObject: src))
        let logger = RecordingLogger()
        let engine = SourceEngine(source: source,
                                  fetcher: PageFetcher(transport: DetailTransport(body: detail)),
                                  js: JSCExecutor(api: Host()),
                                  logger: logger)
        try engine.loadJsLib(jsLib)

        var book = Book()
        book.bookUrl = bookUrl
        book.name = "测试书名"

        let info = try engine.bookInfo(book)
        let log = logger.all.joined(separator: "\n")

        // ⭐⭐⭐ **书名/作者必须取到**（真机就是这里空的）
        XCTAssertEqual(info.name, "测试书名",
                       "⭐⭐⭐ 书名取不到 ⇒ 详情是空的\n引擎日志：\n\(log)")
        XCTAssertEqual(info.author, "测试作者",
                       "⭐⭐⭐ 作者取不到 ⇒ 详情是空的\n引擎日志：\n\(log)")
        XCTAssertFalse(info.bookUrl.isEmpty, "书 URL 不能空")
        // ⭐ 简介不能是「一串 ⇒」（那是把 {{}} 当成规则链的坏法）
        XCTAssertFalse(info.intro.contains("⇒"),
                       "⭐⭐⭐ 简介里出现了规则链符号 ⇒ ⇒ 引擎把多行 {{}} 插值当成了链\n简介：\(info.intro.prefix(200))\n引擎日志：\n\(log)")
    }
}
#endif
