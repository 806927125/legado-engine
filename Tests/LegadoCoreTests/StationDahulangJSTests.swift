#if canImport(JavaScriptCore)
import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **真书源门禁（JSC 真跑）** —— 🍅大灰狼聚合
///
/// ⚠️⚠️ **这是 2026-10-23 真机「未分组」假分类的**守门人**：
///   症状：发现页分类里冒出一个「**未分组**」⇒ 整本书打不开。
///   根因链（三个都是**引擎**的锅，站方规则一个字没改）：
///   ① **Java 兼容层**（`JavaImporter` / `Packages.*`）没注入
///      ⇒ 大灰狼 jsLib 第一行 `new JavaImporter()` 抛错 ⇒ **jsLib 整个加载失败**
///   ② **宿主通道**（`source` / `java` / `cookie`）**必须先于 jsLib 注入**
///      ⇒ 否则 jsLib 里的 `source.getVariable()` 拿不到东西
///   ③ **JSC 的 `evaluateScript` 顶层 `var` 不进全局**（与 WebKit 不同！）
///      ⇒ jsLib 必须用**间接 eval** `(0, eval)(code)` 加载
///
/// ⇒ 这条门禁加载**真 jsLib（32KB）** + 跑**真 exploreUrl（12KB）**
///   ⇒ 上面三条**任何一条回退 ⇒ 必红** ⭐
///
/// ⚠️ **期望值来自 Node 端到端实测**（同一份 jsLib / exploreUrl / 同样的注入顺序）
///   ⇒ 分类 7 个筛选栏（线路/模式/频道/平台/字数/状态/排序）+ 2 个分类（登录大灰狼书源/登录番茄）
///   ⇒ 与真机观测一致（轻阅交接文档：「发现页分类 ✅ 9 个」）
///
/// ⚠️ **这些门禁只在 Apple 平台编**（Linux 没有 JSC）⇒ 由 CI 的 `jsc` job（macOS）跑 ⭐
final class StationDahulangJSTests: XCTestCase {

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

    // MARK: - 宿主 API（大灰狼真语料用到的那些）

    /// ⭐ 大灰狼真语料的**最小宿主实现**（语义与真机一致：没登录、没 cookie）
    private final class StationHostAPI: JSHostAPIProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var vars = ""

        private func readVars() -> String {
            lock.lock(); defer { lock.unlock() }
            return vars
        }
        private func writeVars(_ v: String) {
            lock.lock(); defer { lock.unlock() }
            vars = v
        }

        func hostObject(named name: String) -> HostObject? {
            switch name {
            case "source":
                return HostObject(name: "source", methods: [
                    "getVariable": { [self] _ in .string(readVars()) },
                    "setVariable": { [self] args in
                        writeVars(args.first?.scalarString ?? "")
                        return .string("")
                    },
                    "getLoginInfoMap": { _ in .object([:]) },
                    "getLoginInfo": { _ in .string("") },
                    "putLoginInfo": { _ in .string("") },
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
            case "cache":
                return HostObject(name: "cache", methods: [
                    "put": { _ in .string("") },
                    "get": { _ in .string("") },
                    "putMemory": { _ in .string("") },
                    "getFromMemory": { _ in .string("") },
                ])
            default:
                return nil
            }
        }

        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
            switch method {
            case "deviceID": return .string("GT-DEVICE")
            case "androidId": return .string("GT-ANDROID")
            // ajax / toast / log / qread / startBrowser … ⇒ 空即可（站方自己判空）
            default: return .string("")
            }
        }
    }

    /// 门禁用的空传输（这个测试不联网）
    private struct NoopTransport: HTTPTransport, @unchecked Sendable {
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data(), finalURL: request.url)
        }
    }

    /// ⭐ 造一个「装着真站方 jsLib + 真 exploreUrl」的引擎
    private func makeEngine() throws -> (SourceEngine, String) {
        let jsLib = try loadFixture("dahulang-jsLib.js")
        let explore = try loadFixture("dahulang-exploreUrl.js")
        let obj: [String: Any] = [
            "bookSourceName": "大灰狼真语料门禁",
            "bookSourceUrl": "https://v5.langge.uk",
            "exploreUrl": explore,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        let engine = SourceEngine(source: source,
                                  fetcher: PageFetcher(transport: NoopTransport()),
                                  js: JSCExecutor(api: StationHostAPI()))
        return (engine, jsLib)
    }

    // MARK: - ①⭐⭐ 真 jsLib 必须能加载（这一条就能逮住三个根因里的大部分）

    func testRealStationJsLibLoads() throws {
        let (engine, jsLib) = try makeEngine()
        // ⚠️ 加载失败时 `loadJsLib` 会抛（站方 jsLib 的异常**不再被吞**）
        XCTAssertNoThrow(try engine.loadJsLib(jsLib),
                         "⭐⭐ 真站方 jsLib（32KB）必须能加载 ⇒ Java 兼容层 + 宿主通道 + 间接 eval 三者都在")
    }

    // MARK: - ② jsLib 定义的全局必须可见（站方规则要调 `host` / `getArguments`）

    func testRealStationJsLibGlobalsVisible() throws {
        let (engine, jsLib) = try makeEngine()
        try engine.loadJsLib(jsLib)
        let js = try XCTUnwrap(engine.evaluator.js, "⭐ 必须有 JS 后端")
        let v = try js.run("typeof host + '|' + typeof getArguments + '|' + typeof JavaImporter",
                           context: JSRunContext(base: .page("")))
        XCTAssertEqual(v.scalarString, "object|function|function",
                       "⭐ jsLib 的全局（host / getArguments）+ Java 兼容层（JavaImporter）都要在")
    }

    // MARK: - ③⭐⭐ 发现页分类必须是真的（不是「未分组」假分类）

    func testRealStationExploreUrlProducesRealCategories() throws {
        let (engine, jsLib) = try makeEngine()
        try engine.loadJsLib(jsLib)
        // ⚠️ 这一步走**生产路径**：exploreUrl（`<js>` 块）→ JS 求值 → 拆分类/筛选栏
        let (kinds, filters) = try engine.exploreKinds()
        XCTAssertEqual(filters.map(\.title),
                       ["线路", "模式", "频道", "平台", "字数", "状态", "排序"],
                       "⭐ 站方的 7 个筛选栏要拆出来")
        XCTAssertEqual(kinds.map(\.title), ["登录大灰狼书源", "登录番茄"],
                       "⭐⭐ 2 个真分类要出来（jsLib 半残时这里会变成「未分组」）")
        let all = kinds.map(\.title) + filters.map(\.title)
        XCTAssertFalse(all.contains("未分组"),
                       "⭐⭐ 真机症状：分类变成「未分组」假分类 ⇒ 整本书打不开")
    }
}
#endif
