import Foundation
import XCTest
@testable import LegadoCore

#if canImport(JavaScriptCore)
import JavaScriptCore

/// ⭐⭐⭐⭐⭐ **JM小说 · JSC 后端端到端门禁**（2026-10-26 真机回归实证）
///
/// ────────────────────────────────────────────────────────────
/// 为什么必须有这个文件（今天最大的洞）
/// ────────────────────────────────────────────────────────────
///   · **Node 后端**的同款门禁在 `LiveSourceNodeJSTests.swift` ⇒ **Linux 沙盒跑它**
///   · **真机跑的是 JSC** ⇒ ⇒ **JSC 路径的端到端行为从未被验过** ⭐⭐⭐
///   · ⇒ 沙盒全绿 ≠ 真机对 ⇒ 「以前能加载、去掉老引擎后不行」就是这么漏过去的 ⭐⭐⭐
///
/// ⭐⭐⭐⭐⭐ **这个文件的价值**：**同一份 fixture、同样的断言、只换执行器**
///   ⇒ **Node 过 / JSC 不过 ⇒ 差异就是 JSC 的 bug** ⇒ 一轮 CI 定位 ⭐⭐⭐
///   ⇒ 这正是「把真机的洞搬进沙盒」的升级版：**把真机的洞搬进【真 JSC 的 CI】** ⭐⭐⭐
///
/// fixture（与 Node 版**同一份** ⇒ 差异只可能来自执行器）：
/// · `fixtures/jm-novel-source.json`   ⇒ 真源的 jsLib + ruleExplore
/// · `fixtures/jm-novel-response.json` ⇒ 真实站方的响应（`data` 字段是**加密串**）
final class LiveSourceJSCTests: XCTestCase {

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures")
    }

    private func loadJsLib() throws -> String {
        let data = try Data(contentsOf: Self.fixturesDir.appendingPathComponent("jm-novel-source.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj["jsLib"] as? String ?? ""
    }

    private func loadSource() throws -> BookSource {
        let data = try Data(contentsOf: Self.fixturesDir.appendingPathComponent("jm-novel-source.json"))
        return try JSONDecoder().decode(BookSource.self, from: data)
    }

    private func loadRealResponse() throws -> String {
        let data = try Data(contentsOf: Self.fixturesDir.appendingPathComponent("jm-novel-response.json"))
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// ⭐⭐⭐ 内存传输（返回**真响应**）
    final class MemTransport: HTTPTransport, @unchecked Sendable {
        private let body: String
        init(body: String) { self.body = body }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8), finalURL: request.url)
        }
    }

    /// ⭐⭐⭐⭐⭐ **主用例**：真源 + 真响应 + **真 JSC** ⇒ 必须出 15 本
    ///
    /// ⇒ 与 Node 版**逐字同样的断言** ⇒ 差异只可能来自执行器 ⭐⭐⭐
    func testRealSourceRealResponseProducesBooksOnJSC() throws {
        let src = try loadSource()
        let response = try loadRealResponse()
        let js = try JSCExecutor(api: LiveSourceJSCTests.NoopAPI())
        let transport = MemTransport(body: response)
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: transport), js: js)

        // ⭐⭐⭐ **站方 jsLib 必须先加载**（它定义 `hjmDec` / `b64ToBytes` / `bytesToUtf8`）
        try engine.loadJsLib(try loadJsLib())

        let listURL = "https://cof03.bahfn.cn/jbapi/book/onetab/61/1/15/sort/hjm.ojbk"

        let books: [Book]
        do {
            books = try engine.explore(listURL)
        } catch {
            // ⭐⭐⭐ **失败时把诊断打出来**（否则 CI 只有一句「failed」⇒ 定位不到）⭐⭐⭐
            let lines = engine.failureDiagnosticLines.joined(separator: "\n")
            XCTFail("⭐⭐⭐ JSC 后端跑真源失败：\(error)\n引擎诊断：\n\(lines)")
            return
        }
        XCTAssertFalse(books.isEmpty,
                       "⭐⭐⭐ 真源 + 真响应 + **JSC** 必须出书（真机症状：emptyResult(\"bookList\")）")
        XCTAssertEqual(books.count, 15, "实际=\(books.count) 本：\(books.map { $0.name })")
        XCTAssertTrue(books.contains { $0.name.contains("诱逃") },
                      "实际书名=\(books.map { $0.name })")
    }

    /// ⭐⭐⭐ **空结果时，诊断必须带「URL + 响应摘要」**（与 Node 版同款断言）
    func testEmptyResultDiagnosticHasURLAndResponseOnJSC() throws {
        let src = try loadSource()
        let response = try loadRealResponse()
        let js = try JSCExecutor(api: LiveSourceJSCTests.NoopAPI())
        var src2 = src
        src2.ruleExplore?.bookList = "@js:(function(){return [];})()"
        let transport = MemTransport(body: response)
        let engine = SourceEngine(source: src2, fetcher: PageFetcher(transport: transport), js: js)
        try engine.loadJsLib(try loadJsLib())
        let listURL = "https://cof03.bahfn.cn/jbapi/book/onetab/61/1/15/sort/hjm.ojbk"
        do { _ = try engine.explore(listURL) } catch { }
        let lines = engine.failureDiagnosticLines
        XCTAssertFalse(lines.isEmpty, "⭐⭐⭐ 空结果时必须有诊断行")
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("URL="), "⭐⭐⭐ 诊断必须带 URL：\(joined)")
        XCTAssertTrue(joined.contains("响应长度="), "⭐⭐⭐ 诊断必须带响应长度：\(joined)")
        XCTAssertTrue(joined.contains("响应前 200 字="), "⭐⭐⭐ 诊断必须带响应摘要：\(joined)")
    }

    /// ⭐⭐⭐⭐⭐ **站方 jsLib 的全局，规则求值时必须看得见**
    ///
    /// ⚠️ 这是 JM 的核心依赖：\`bookList\` 里调 \`hjmDec\`（定义在 **jsLib** 里）
    ///   ⇒ 若 jsLib 的全局丢了 ⇒ \`hjmDec is not a function\`
    ///   ⇒ 站方的 \`catch(e){return []}\` 吞掉 ⇒ **0 本书**（真机症状）⭐⭐⭐
    func testJsLibGlobalsVisibleToRulesOnJSC() throws {
        let js = try JSCExecutor(api: LiveSourceJSCTests.NoopAPI())
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        // ⭐ 先加载 jsLib（用真实的那份）
        let lib = try loadJsLib()
        _ = try js.runGlobal(lib, context: ctx)
        // ⭐ 规则求值时能不能调到 jsLib 的函数
        let v = try js.run("typeof hjmDec", context: ctx)
        XCTAssertEqual(v.scalarString, "function",
                       "⭐⭐⭐ jsLib 的全局在规则求值时必须可见（否则 hjmDec is not a function ⇒ 0 本书）")
    }

    /// ⭐⭐⭐⭐⭐ **诊断探针：JSC 上「全局」到底是什么**（2026-10-26）
    ///
    /// ⚠️ 这条**不判对错，只打印事实** ⇒ 让 CI 给出确切答案，而不是我猜 ⭐⭐⭐
    func testProbeWhatGlobalIsOnJSC() throws {
        let js = try JSCExecutor(api: LiveSourceJSCTests.NoopAPI())
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        let lib = try loadJsLib()
        _ = try js.runGlobal(lib, context: ctx)
        js.markGlobalsAsBaseline()

        let probe = [
            "(function(){",
            "var out=[];",
            "try{out.push('gt===this: '+(globalThis===this));}catch(e){out.push('gt===t: ERR');}",
            "try{out.push('typeof this: '+(typeof this));}catch(e){out.push('typeof this: ERR');}",
            "try{out.push('gtNames: '+Object.getOwnPropertyNames(globalThis).length);}catch(e){out.push('gtNames: ERR');}",
            "try{out.push('tNames: '+Object.getOwnPropertyNames(this).length);}catch(e){out.push('tNames: ERR');}",
            "try{out.push('gt.hjmDec: '+(typeof globalThis.hjmDec));}catch(e){out.push('gt.hjmDec: ERR');}",
            "try{out.push('t.hjmDec: '+(typeof this.hjmDec));}catch(e){out.push('t.hjmDec: ERR');}",
            "try{out.push('bare hjmDec: '+(typeof hjmDec));}catch(e){out.push('bare hjmDec: ERR');}",
            "return out.join(' | ');",
            "})()"
        ].joined(separator: "\n")
        let v = try js.run(probe, context: ctx)
        print("⭐⭐⭐ [JSC 全局诊断] " + v.scalarString)
    }

    /// ⭐⭐⭐ **空宿主**（这个测试不需要宿主能力）
    final class NoopAPI: JSHostAPIProvider, @unchecked Sendable {
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? { nil }
    }
}
#else
/// ⭐⭐⭐ **Linux 上整个文件跳过**（没 JSC ⇒ **没验到**，不等于通过）
final class LiveSourceJSCTests: XCTestCase {
    func testSkippedOnLinuxBecauseNoJSC() {
        print("⏭️ 跳过：Linux 没有 JavaScriptCore ⇒ **JSC 路径的端到端行为没验到**（不等于通过）")
    }
}
#endif
