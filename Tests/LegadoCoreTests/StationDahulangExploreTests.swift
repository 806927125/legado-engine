#if canImport(JavaScriptCore)
import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **真书源门禁（发现页 → 书籍 URL）** —— 🍅大灰狼聚合
///
/// ⚠️⚠️ **这是 2026-10-24 真机「还是不行」的守门人**：
///   真机症状：发现功能通过（5 本书），但**每本书的 `bookUrl` 是空的**
///   ⇒ 详情 `invalidSource("bookUrl 为空")` / 目录 `invalidSource("目录 URL 为空")`
///   ⇒ 正文「没有章节可取正文」⇒ **整条链从「书 URL」这一环就断了**
///
/// ⭐ **大灰狼的 `bookUrl` 不是字段规则，是一段 `<js>` 块**：
/// ```js
/// let book_id = result.book_id;
/// …
/// qtdetail = java.base64Encode(JSON.stringify(qtdetail));
/// `data:;base64,${qtdetail},{"type":"qingtian"}`
/// ```
/// ⇒ 它同时踩了三个点：
///   ① **`<js>` 块当字段规则**（要能跑 JS + 取完成值）
///   ② **`java.base64Encode`**（引擎侧能力 ⇒ 宿主通道）
///   ③ **`data:;base64,…` 伪 URL**（不能被绝对化 / 要剥 `,{json}` 后缀）
///
/// ⇒ 这条门禁用**真规则** + **真 jsLib** 跑**生产路径** `explore()`
///   ⇒ 上面任何一环坏掉 ⇒ **必红** ⭐
/// ⇒ **期望值不是「非空」**（那太弱）⇒ 而是**载荷解出来真的有 book_id**
///   （`java.base64Encode` 没接上时，载荷会是 `undefined` ⇒ 字符串非空但内容是垃圾
///     ⇒ 只断言「非空」会漏掉这种最常见的坏法）⭐⭐
final class StationDahulangExploreTests: XCTestCase {

    private static let fixtureDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/station")
    }()

    private func loadFixture(_ name: String) throws -> String {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent(name))
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 门禁用的假传输（**不联网**）：发现页 URL ⇒ 真形状的 JSON 响应
    private struct FixtureTransport: HTTPTransport, @unchecked Sendable {
        let body: String
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"],
                         body: Data(body.utf8), finalURL: request.url)
        }
    }

    private func makeEngine(_ logger: RecordingLogger) throws -> (SourceEngine, String) {
        let rulesData = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("dahulang-rules.json"))
        let rules = try JSONDecoder().decode([String: [String: String]].self, from: rulesData)
        let jsLib = try loadFixture("dahulang-jsLib.js")
        let response = try loadFixture("dahulang-explore-response.json")

        // ⭐ 站方源（只保留这次要验的字段；其余不重要）
        let src: [String: Any] = [
            "bookSourceName": "大灰狼真语料门禁",
            "bookSourceUrl": "https://v5.langge.uk",
            "ruleExplore": rules["ruleExplore"] ?? [:],
        ]
        let data = try JSONSerialization.data(withJSONObject: src)
        let source = try JSONDecoder().decode(BookSource.self, from: data)

        let engine = SourceEngine(source: source,
                                  fetcher: PageFetcher(transport: FixtureTransport(body: response)),
                                  js: JSCExecutor(api: StationHostAPI()),
                                  logger: logger)
        // ⭐⭐ **站方 jsLib 必须先加载**（它定义 `host` / `getArguments` ⇒ 站方规则的前提）
        try engine.loadJsLib(jsLib)
        return (engine, response)
    }

    /// ⭐ 大灰狼真语料用到的最小宿主 API
    private final class StationHostAPI: JSHostAPIProvider, @unchecked Sendable {
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
            default:
                return nil
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

    // MARK: - ①⭐⭐ bookUrl 必须是**真载荷**（不是空、也不是 "undefined"）

    func testRealStationBookUrlCarriesRealPayload() throws {
        let logger = RecordingLogger()
        let (engine, _) = try makeEngine(logger)
        let books = try engine.explore("https://v5.langge.uk/api/explore", page: 1)
        XCTAssertFalse(books.isEmpty, "⭐ 发现页必须出书（真规则 + 假响应）\n引擎日志：\(logger.all.joined(separator: "\n"))")

        let book = try XCTUnwrap(books.first, "⭐ 第一本书")
        let url = book.bookUrl
        XCTAssertFalse(url.isEmpty,
                       "⭐⭐ 大灰狼的 bookUrl 是 `<js>` 块算出来的 ⇒ 不能是空\n引擎日志：\(logger.all.joined(separator: "\n"))")
        XCTAssertTrue(url.hasPrefix("data:;base64,"),
                      "⭐⭐ bookUrl 必须是 `data:;base64,` 伪 URL（站方形态）\n实际：\(url)\n引擎日志：\(logger.all.joined(separator: "\n"))")

        // ⭐⭐⭐ **载荷必须解得出真的 book_id**（`java.base64Encode` 没接上时会是 `undefined`）
        let payload = String(url.dropFirst("data:;base64,".count))
            .components(separatedBy: ",{\"type\"").first ?? payload
        let decoded = Crypto.base64Decode(payload) ?? ""
        XCTAssertFalse(decoded.isEmpty,
                       "⭐⭐ 载荷解不出来 ⇒ `java.base64Encode` 没接上（引擎侧能力没接管）\n实际：\(url)")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any],
                                "⭐⭐ 载荷必须是一份 JSON\n解出来：\(decoded)")
        XCTAssertEqual(obj["book_id"] as? String, "7412345678901234567",
                       "⭐⭐⭐ 载荷里必须有真的 book_id（站方靠它拼请求）\n解出来：\(decoded)")
    }

    // MARK: - ② 书籍的其它字段也要跟着出来（别只测一个）

    func testRealStationBookFields() throws {
        let logger = RecordingLogger()
        let (engine, _) = try makeEngine(logger)
        let books = try engine.explore("https://v5.langge.uk/api/explore", page: 1)
        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(book.name, "测试书名一", "⭐ 名字")
        XCTAssertEqual(book.author, "作者一", "⭐ 作者")
        // ⭐ 原始字段必须带下去（站方 JS 要读 book_id / bid 之类）
        XCTAssertEqual(book.raw["book_id"], "7412345678901234567",
                       "⭐⭐ 列表项的原始字段必须一路带下去（少了整本书崩）")
    }
}
#endif
