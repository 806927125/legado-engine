import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **真源 + 真响应 + 真引擎**（Node 驱动的 JS）—— 2026-10-25 真机 JM小说 实证
///
/// **真机症状**：源「JM小说」的发现功能 `emptyResult("bookList")`
/// ⇒ 引擎日志显示 `规则[@js:(function(){…})()] 分支=JS`（JS 跑了）⇒ **返回了空数组** ⭐⭐⭐
/// ⇒ 站方 JS 的 `catch(e){return []}` 吞掉了真凶 ⇒ **真凶在 JS 内部** ⭐⭐⭐
///
/// ⭐ **为什么必须用 Node 驱动**：
/// · 站方 JS 有**自定义加密**（`hjmDec` = base64 + 字节反转 + 二次解码）
///   ⇒ 必须**真跑 JS** 才能验 ⇒ 手写 stub 会「假定 result 是页原文」⇒ **测不出真机的问题** ⭐⭐⭐
/// · Linux 沙盒**没有 JSC** ⇒ Node 的 `vm` 语义与 JSC 的 `eval` 完成值一致 ⇒ 替身 ⭐⭐⭐
/// ⇒ **「别用真机当调试器」** ⇒ 把真机的洞搬进沙盒 ⭐⭐⭐
///
/// ⭐ fixture（都是 2026-10-25 从真机/真站抓的）：
/// · `fixtures/jm-novel-source.json`   ⇒ 真源的 jsLib + ruleExplore
/// · `fixtures/jm-novel-response.json` ⇒ 真实站方的响应（`data` 字段是**加密串**）
final class LiveSourceNodeJSTests: XCTestCase {

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures")
    }

    /// ⭐⭐⭐ **真源的 jsLib**（引擎的 `BookSource` 没这个字段 ⇒ 宿主单独带进来）
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

    /// ⭐⭐⭐⭐⭐ **主用例**：真源 + 真响应 + 真引擎 ⇒ 必须出 15 本
    ///
    /// ⇒ 这条在 2026-10-25 **复现了真机的 `emptyResult("bookList")`** ⇒ 修好后必须绿 ⭐⭐⭐
    func testRealSourceRealResponseProducesBooks() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 跑不了（显式 SKIP，不许假绿）")

        let src = try loadSource()
        let response = try loadRealResponse()
        let js = try NodeJSExecutor()
        let transport = MemTransport(body: response)
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: transport), js: js)

        // ⭐⭐⭐ **站方 jsLib 必须先加载**（它定义 `hjmDec` / `b64ToBytes` / `bytesToUtf8`）
        try engine.loadJsLib(try loadJsLib())

        // ⭐⭐⭐ **探索页的分类 URL**（站方 JS 生成的那条）
        let listURL = "https://cof03.bahfn.cn/jbapi/book/onetab/61/1/15/sort/hjm.ojbk"

        let books = try engine.explore(listURL)
        XCTAssertFalse(books.isEmpty,
                       "⭐⭐⭐ 真源 + 真响应 必须出书（真机症状：emptyResult(\"bookList\")）")
        XCTAssertEqual(books.count, 15, "实际=\(books.count) 本：\(books.map { $0.name })")
        XCTAssertTrue(books.contains { $0.name.contains("诱逃") },
                      "实际书名=\(books.map { $0.name })")
    }

    /// ⭐⭐⭐⭐⭐ **空结果时，诊断必须带「URL + 响应摘要」**（2026-10-25 真机实证）
    ///
    /// ⇒ 以前诊断只有「规则[...] 分支=JS」⇒ **看不出引擎看到了什么** ⇒ 只能猜 ⭐⭐⭐
    /// ⇒ 现在：**URL + 响应长度 + 响应前 200 字 + isJSON** ⇒ 真机一次定位 ⭐⭐⭐
    func testEmptyResultDiagnosticHasURLAndResponse() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node")
        let src = try loadSource()
        let response = try loadRealResponse()
        let js = try NodeJSExecutor()
        // ⭐ 用一个**永远返回空**的 bookList ⇒ 触发「列表为空」⇒ 看诊断里有没有 URL/响应
        var src2 = src
        src2.ruleExplore?.bookList = "@js:(function(){return [];})()"
        let transport = MemTransport(body: response)
        let engine = SourceEngine(source: src2, fetcher: PageFetcher(transport: transport), js: js)
        try engine.loadJsLib(try loadJsLib())
        let listURL = "https://cof03.bahfn.cn/jbapi/book/onetab/61/1/15/sort/hjm.ojbk"
        do { _ = try engine.explore(listURL) } catch {
            // 预期抛 emptyResult
        }
        let lines = engine.failureDiagnosticLines
        XCTAssertFalse(lines.isEmpty, "⭐⭐⭐ 空结果时必须有诊断行")
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("URL="), "⭐⭐⭐ 诊断必须带 URL：\(joined)")
        XCTAssertTrue(joined.contains("响应长度="), "⭐⭐⭐ 诊断必须带响应长度：\(joined)")
        XCTAssertTrue(joined.contains("响应前 200 字="), "⭐⭐⭐ 诊断必须带响应摘要：\(joined)")
    }

    /// ⭐⭐⭐ **诊断 3**：打印引擎生成的 scope（看 `result` 到底是什么）
    func testPrintScope() throws {
        let item = JSONValue.object(["id": .int(39132), "title": .string("诱逃")])
        let base = RuleBase.json(item)
        let ctx = JSRunContext(base: base, baseUrl: "https://x")
        let scope = JSScopeBuilder.build(ctx)
        print("DEBUG scope = \(scope)")
        print("DEBUG jsonLiteral = \(JSScopeBuilder.jsonLiteral(JSScopeBuilder.toJSON(base.resultValue)))")
    }

    /// ⭐⭐⭐ **诊断 2**：字段规则 `@js:result.title` 在列表项上取值
    func testFieldRuleOnListItem() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node")
        let js = try NodeJSExecutor()
        let ev = Evaluator(js: js)
        // 列表项 = 一个 JSON 对象（站方 record）
        let item = JSONValue.object(["id": .int(39132), "title": .string("诱逃"),
                                     "miaoshu": .string("简介")])
        let base = RuleBase.json(item)
        let ctx = EvalContext(base: base, baseUrl: "https://x", raw: "", isJSON: true)
        for rule in ["@js:result.title", "title", "$.title"] {
            let e = ev.evalOne(rule, base: base, ctx: ctx)
            print("DEBUG 规则 \(rule) ⇒ 分支=\(e.diagnostic.branch ?? "nil") 失败=\(e.diagnostic.failure.map { "\($0)" } ?? "无") 值=\(e.value.text)")
        }
    }

    /// ⭐⭐⭐ **诊断**：如果上面红了，这条会**指出到底哪一步空**
    func testDiagnoseWhereItFails() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 跑不了")
        let src = try loadSource()
        let response = try loadRealResponse()
        let js = try NodeJSExecutor()
        let transport = MemTransport(body: response)
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: transport), js: js)
        try engine.loadJsLib(try loadJsLib())
        let listURL = "https://cof03.bahfn.cn/jbapi/book/onetab/61/1/15/sort/hjm.ojbk"
        do {
            let books = try engine.explore(listURL)
            print("DEBUG 出 \(books.count) 本：\(books.map { $0.name })")
        } catch {
            print("DEBUG explore 抛错：\(error)")
        }
        print("DEBUG 诊断行：")
        for d in engine.diagnostics { print("  ", SourceEngine.diagnosticLine(d)) }
    }
}
