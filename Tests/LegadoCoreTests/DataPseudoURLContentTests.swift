import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **`data:` 伪 URL 的内容语义**（**Linux 可跑** ⇒ 3 秒反馈）
///
/// ⚠️⚠️⚠️ **这是 2026-10-24 真机「大灰狼详情空白」的根因**：
///   站方聚合源（🍅大灰狼）的 bookUrl / tocUrl / chapterUrl 全是
///   `data:;base64,<载荷>,{"type":"qingtian"}`
///
///   站方的语义 = 「**`data:` 伪 URL 的载荷 = 页面内容**」
///   ⇒ **站方自己**用 `java.hexDecodeToString(result)` 解 ⭐
///
///   引擎以前把 `data:` 伪 URL **发给传输层**了
///   ⇒ 真机：传输层解 data: URL ⇒ 抛「illegal base64 data at input byte 9」
///   ⇒ 门禁里：假传输对任何 URL 都回详情 JSON ⇒ `result` = 详情 JSON
///      ⇒ `hexDecodeToString` 解不出 ⇒ `JSON.parse` 炸
///      ⇒ **init 输出为空** ⇒ 详情字段（书名/作者/简介）全空 ⭐⭐⭐
///
///   ⇒ 与轻阅参考实现（`reference/js/engine.js` 的 `fetchPage`
///      / `reference/js/java-api.js` 的 `rawRequest`）**逐字一致**才叫对 ⭐
///
/// ⭐ **为什么这道门禁在 Linux**：这个 bug 只有「真机 + 真 JSC」才暴露
///   ⇒ 等 CI 一轮 5 分钟 ⇒ 反馈太慢 ⇒ 同一个坑踩了三次
///   ⇒ 现在把语义钉在 Linux ⇒ 改完立刻能验 ⭐
final class DataPseudoURLContentTests: XCTestCase {

    // MARK: - 真语料（🍅大灰狼聚合的 bookUrl，一字未改）

    /// **站方真 bookUrl**（载荷后面还挂着站方的 URL 选项）
    private static let realBookURL =
        "data:;base64,eyJib29rX2lkIjogIjc2NTAzNTQ3ODA2MjUwMjM1MTIiLCAic291cmNlIjogIueVquiMhCIsICJ0YWIiOiAi5bCP6K+0IiwgInVybCI6ICIifQ==,{\"type\":\"qingtian\"}"

    /// **载荷本体**（= base64 原文 ⇒ **站方自己解** ⇒ 引擎不许先解）
    private static let realPayload =
        "eyJib29rX2lkIjogIjc2NTAzNTQ3ODA2MjUwMjM1MTIiLCAic291cmNlIjogIueVquiMhCIsICJ0YWIiOiAi5bCP6K+0IiwgInVybCI6ICIifQ=="

    /// **URL 选项后缀被百分号编码过的形态**
    /// （`URL(string:).absoluteString` 就是这么干的 ⇒ 轻阅 2026-10-21 真机栽在这）⭐
    private static let realBookURLEncoded =
        "data:;base64,eyJib29rX2lkIjogIjc2NTAzNTQ3ODA2MjUwMjM1MTIiLCAic291cmNlIjogIueVquiMhCIsICJ0YWIiOiAi5bCP6K+0IiwgInVybCI6ICIifQ==,%7B%22type%22%3A%22qingtian%22%7D"

    // MARK: - fixture

    /// ⭐ **读 fixture 文件**（`conformance/fixtures/station/`）
    private static var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/station")
    }

    private func load(_ name: String) throws -> String {
        let url = Self.fixtureDir.appendingPathComponent(name)
        return try String(data: Data(contentsOf: url), encoding: .utf8) ?? ""
    }

    // MARK: - 假传输 / 假执行器

    /// **记录请求的假传输**
    ///
    /// ⭐ **`data:` 伪 URL 绝不能走到这里**（走了就说明引擎把载荷当 URL 发了）⭐
    private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [String] = []
        var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            lock.lock(); _urls.append(request.url); lock.unlock()
            let body = #"{"code":0,"msg":"ok","data":{"book_name":"传输层的假响应"}}"#
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"],
                                body: Data(body.utf8), finalURL: request.url)
        }
    }

    /// **捕获上下文的假 JS 执行器**（代替真 JSC）
    private final class CapturingExecutor: JSExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private var _raws: [String] = []
        private var _hasBook: [Bool] = []
        private var _hasSource: [Bool] = []
        var raws: [String] { lock.lock(); defer { lock.unlock() }; return _raws }
        var hasBook: [Bool] { lock.lock(); defer { lock.unlock() }; return _hasBook }
        var hasSource: [Bool] { lock.lock(); defer { lock.unlock() }; return _hasSource }

        func run(_ code: String, context: JSRunContext) throws -> JSONValue {
            lock.lock()
            _raws.append(context.raw)
            _hasBook.append(context.book != nil)
            _hasSource.append(context.source != nil)
            lock.unlock()
            return .string("{}")
        }
    }

    /// **返回固定 JSON 文本的假执行器**（模拟站方的复合规则：`data` 是个 JSON 串）
    private final class JSONTextExecutor: JSExecutor, @unchecked Sendable {
        private let text: String
        init(text: String) { self.text = text }
        func run(_ code: String, context: JSRunContext) throws -> JSONValue {
            return .string(text)
        }
    }

    /// **抛错的假执行器**（模拟站方 JS 抛异常）
    private final class ThrowingExecutor: JSExecutor, @unchecked Sendable {
        struct Boom: Error {}
        func run(_ code: String, context: JSRunContext) throws -> JSONValue {
            throw Boom()
        }
    }

    // MARK: - 门禁

    /// ⭐⭐⭐ **主门禁：`data:` 伪 URL 的页面内容 = 原始载荷（不解码），且不发请求**
    func testDataPseudoURLPageContentIsRawPayloadAndNoRequest() throws {
        let transport = RecordingTransport()
        let js = CapturingExecutor()
        let source = try makeSource(initRule: "<js>result</js>")
        let engine = SourceEngine(source: source,
                                  fetcher: PageFetcher(transport: transport),
                                  js: js, logger: RecordingLogger())

        var book = Book()
        book.bookUrl = Self.realBookURL
        book.name = "测试书名"

        _ = try engine.bookInfo(book)

        // ① ⭐⭐⭐ 页面内容 = **原始载荷**（不是解码后的 JSON，也不是传输层的响应）
        let raw = try XCTUnwrap(js.raws.first, "init 规则没跑到 JS 分支 ⇒ 门禁没验到东西")
        XCTAssertEqual(raw, Self.realPayload,
                       "⭐⭐⭐ `data:` 伪 URL 的内容必须是【原始载荷】\n"
                       + "实际：\(raw.prefix(120))\n"
                       + "站方要自己 `hexDecodeToString(result)` 解 ⇒ 引擎先解就解了两次 ⇒ JSON.parse 炸")

        // ② ⭐⭐⭐ **一个请求都不许发**（`data:` 伪 URL 不是页面 URL）
        XCTAssertTrue(transport.urls.isEmpty,
                      "⭐⭐⭐ `data:` 伪 URL 竟然发了请求：\(transport.urls) ⇒ 真机抛「illegal base64 data」")
    }

    /// ⭐⭐ **`data:` 载荷的剥壳规则**（选项后缀两种形态都认）
    func testDataPayloadStripsOptionsSuffixAndKeepsRawText() throws {
        // ① 真 bookUrl ⇒ 载荷（**不解码**）
        XCTAssertEqual(SourceEngine.dataPayload(Self.realBookURL), Self.realPayload,
                       "⭐⭐⭐ 载荷没剥干净 / 被解码了")
        // ② 后缀被百分号编码过 ⇒ 一样要剥掉
        XCTAssertEqual(SourceEngine.dataPayload(Self.realBookURLEncoded), Self.realPayload,
                       "⭐⭐⭐ 百分号编码的选项后缀没剥掉（轻阅 2026-10-21 真机栽在这）")
        // ③ 明文载荷里的**逗号是内容**（不是选项尾巴）⇒ 不能乱切
        XCTAssertEqual(SourceEngine.dataPayload("data:text/html,<p>a,b</p>"), "<p>a,b</p>",
                       "⭐ 明文载荷里的逗号被切掉了")
        // ④ 明文载荷 + 选项后缀 ⇒ 切在 `,{` 前面
        XCTAssertEqual(SourceEngine.dataPayload("data:text/html,<p>x</p>,{\"type\":\"a\"}"), "<p>x</p>",
                       "⭐ 选项后缀没剥掉")
        // ⑤ 不是 data: ⇒ nil
        XCTAssertNil(SourceEngine.dataPayload("https://example.com/a"))
        // ⑥ ⭐ **解不了 ⇒ 明确失败（nil）**，不许返回乱码
        //    （站方 `JSON.parse` 拿到乱码 ⇒ 炸得莫名其妙；拿 nil ⇒ 立刻炸）⭐
        XCTAssertNil(SourceEngine.dataPayload("data:;base64,!!!不是合法base64!!!"),
                     "⭐⭐⭐ 解不了的载荷必须明确失败，不许返回乱码")
        // ⑦ hex 载荷也算「解得了」（站方 `hexDecodeToString` 内部会先试 hex）⭐
        //    （`7B2261223A317D` = `{"a":1}` 的 hex）
        XCTAssertEqual(SourceEngine.dataPayload("data:;base64,7B2261223A317D"),
                       "7B2261223A317D",
                       "⭐ hex 载荷被误判成「解不了」⇒ 站方拿不到载荷")
    }

    /// ⭐⭐⭐ **init 规则必须能拿到 `book` / `source` 宿主对象**
    ///
    /// ⚠️ 站方 `ruleBookInfo.init` 的第一句就是
    /// `getArguments(source.getVariable(), "server")` / `String(book.getVariable('custom'))`
    /// ⇒ 宿主对象晚建 ⇒ 站方 JS 抛异常 ⇒ init 输出为空 ⇒ 详情字段全空 ⭐⭐⭐
    func testInitRuleSeesBookAndSourceHostObjects() throws {
        let transport = RecordingTransport()
        let js = CapturingExecutor()
        let source = try makeSource(initRule: "<js>result</js>")
        let engine = SourceEngine(source: source,
                                  fetcher: PageFetcher(transport: transport),
                                  js: js, logger: RecordingLogger())

        var book = Book()
        book.bookUrl = Self.realBookURL

        _ = try engine.bookInfo(book)

        XCTAssertEqual(js.hasBook.first, true,
                       "⭐⭐⭐ init 规则跑的时候 `book` 还是 nil ⇒ 站方 `book.getVariable()` 抛异常")
        XCTAssertEqual(js.hasSource.first, true,
                       "⭐⭐⭐ init 规则跑的时候 `source` 还是 nil ⇒ 站方 `source.getVariable()` 抛异常")
    }

    /// ⭐⭐⭐ **JS 的真实错误不许被「类型不符」盖掉**
    ///
    /// ⚠️⚠️ 2026-10-24 真机栽的：站方 JS 抛了异常（真凶），
    ///   但 `applyTail` 又写了一�� `baseTypeMismatch` ⇒ 现场只看到「不是 JSON」
    ///   ⇒ 只能靠猜（白查了两轮）⭐⭐⭐
    func testJSErrorSurvivesTailTypeCheck() throws {
        let ev = Evaluator(js: ThrowingExecutor())
        let json = #"{"data":{"book_name":"x"}}"#
        let base = RuleBase.page(json)
        let ctx = EvalContext(base: base, baseUrl: "https://v5.langge.uk",
                              raw: json, isJSON: true)
        let e = ev.evalOne("<js>throw new Error('站方炸了')</js>$.data", base: base, ctx: ctx)
        guard let failure = e.diagnostic.failure else {
            return XCTFail("⭐⭐⭐ 规则失败了却没有诊断 ⇒ 静默失败")
        }
        guard case .jsError = failure else {
            return XCTFail("⭐⭐⭐ 真凶被盖掉了：诊断说的是 \(failure) ⇒ 应该是「站方 JS 抛异常」")
        }
    }

    /// ⭐⭐⭐ **目录页也一样：载荷必须是【原始载荷】**
    ///
    /// ⚠️ 站方（大灰狼）的 `ruleToc.chapterList` 是**同一套写法**：
    ///   `<js> let res = JSON.parse(java.hexDecodeToString(result)); …`
    ///   ⇒ 目录页的内容也必须是**原始载荷**（站方自己解）⭐
    ///   ⇒ 引擎要是给了解码后的东西 ⇒ 站方再解一次 ⇒ 炸 ⇒ **目录 0 章** ⭐⭐⭐
    ///   （`ruleContent.content` 同理 ⇒ 正文也是空的）⭐
    func testTocPageContentIsAlsoRawPayload() throws {
        let transport = RecordingTransport()
        let js = CapturingExecutor()
        let source = try makeSource(initRule: "<js>result</js>",
                                    tocRule: "<js>result</js>")
        let engine = SourceEngine(source: source,
                                  fetcher: PageFetcher(transport: transport),
                                  js: js, logger: RecordingLogger())

        var info = BookInfo()
        info.bookUrl = Self.realBookURL
        info.tocUrl = Self.realBookURL      // 站方的 tocUrl 也是 data: 伪 URL

        _ = try engine.toc(info)

        // 目录规则看到的必须是**原始载荷**
        let tocRaw = js.raws.last
        XCTAssertEqual(tocRaw, Self.realPayload,
                       "⭐⭐⭐ 目录页的内容必须是【原始载荷】⇒ 不然站方解不动 ⇒ 目录 0 章")
        XCTAssertTrue(transport.urls.isEmpty,
                      "⭐⭐⭐ `data:` 伪 URL 竟然发了请求：\(transport.urls)")
    }

    /// ⭐⭐⭐ **JS 形态的列表规则 ⇒ 走【JSON 列表】路径**（哪怕页面不是 JSON）
    ///
    /// ⚠️⚠️ **2026-10-24 真机「大灰狼目录 0 章」的真根因**：
    ///   引擎的 `listItems` 以前**只按 `page.isJSON` 分流**
    ///   ⇒ 而大灰狼的**目录页内容是 `data:` 载荷的 base64 文本** ⇒ `isJSON = false`
    ///   ⇒ 复合规则 `<js>…</js>$.data` 被当 DOM 查 ⇒ 找不到任何节点 ⇒ **0 章** ⭐⭐⭐
    ///   ⇒ 老引擎的口径 = **按规则形态分流**（`rule.classify` ⇒ JS ⇒ `getJsonList`）⭐
    ///
    /// ⇒ 这条门禁在 Linux 就能跑（stub 执行器）⇒ 3 秒反馈 ⭐
    func testJSListRuleOnNonJSONPageYieldsChapters() throws {
        let transport = RecordingTransport()
        // ⭐ **章节 JSON 放 fixture 文件**（不写在 Swift 字面量里 ⇒ 不用跟引号转义打架）⭐
        let chaptersJSON = try load("chain-chapters.json")
        let js = JSONTextExecutor(text: chaptersJSON)
        let source = try makeSource(initRule: "<js>result</js>",
                                    tocRule: "<js>result</js>$.data")
        let logger = RecordingLogger()
        let engine = SourceEngine(source: source,
                                  fetcher: PageFetcher(transport: transport),
                                  js: js, logger: logger)

        var info = BookInfo()
        info.bookUrl = Self.realBookURL
        info.tocUrl = Self.realBookURL     // 目录页 = data: 载荷（**不是 JSON 页面**）

        let chapters = (try? engine.toc(info, book: Book())) ?? []
        let diag = engine.diagnostics.map { "\($0.rule) | \($0.branch ?? "-") | \($0.failure.map { String(describing: $0) } ?? "-")" }
        let log = logger.all.joined(separator: "\n")

        XCTAssertEqual(chapters.count, 2,
                       "⭐⭐⭐ JS 形态的列表规则在非 JSON 页面上被当 DOM 查了 ⇒ 目录 0 章"
                       + "\n诊断：\n" + diag.joined(separator: "\n")
                       + "\n日志：\n" + log)
        XCTAssertEqual(chapters.first?.name, "第一章 风起")
        XCTAssertTrue(chapters.first?.url.hasPrefix("data:;base64,") ?? false,
                      "⭐⭐⭐ 章节 URL 必须是原样的 data: 伪 URL（不许被绝对化改写）")
    }

    // MARK: - 工具

    private func makeSource(initRule: String, tocRule: String? = nil) throws -> BookSource {
        var src: [String: Any] = [
            "bookSourceName": "data: 伪 URL 门禁",
            "bookSourceUrl": "https://v5.langge.uk",
            "ruleBookInfo": ["init": initRule, "name": "$.book_name"],
        ]
        if let tocRule {
            src["ruleToc"] = ["chapterList": tocRule, "chapterName": "$.title",
                              "chapterUrl": "$.qr_url"]
        }
        return try JSONDecoder().decode(BookSource.self,
                                       from: try JSONSerialization.data(withJSONObject: src))
    }
}
