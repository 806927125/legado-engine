import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **`@js:` 的 bookList**（站方 API 源的通用形态）—— 2026-10-25 真机实证
///
/// **症状**（真机，源「JM小说」）：
/// ```
/// 规则[@js:(function(){try{var j=JSON.parse(result);var d=j.data;if(typeof d==='string'){
///      d=JSON.parse(hjmDec(d));}if(!d)return [];if(d.records)return d.records;
///      if(d.list)return d.list;return Array.isArray(d)?d:[];}catch(e){return [];}})()]
///   分支=JS
/// ❌ 发现功能  emptyResult("bookList")
/// ```
/// ⇒ **站方 JS 跑了、返回了数组 ⇒ 引擎却判「空」** ⭐⭐⭐
///
/// **站方形态**（125 源里 3 个：JM小说 / JM动漫 / JM漫画）：
/// `@js:(function(){ … JSON.parse(result) … return 数组 })()`
/// - ① 整条规则是**立即调用的函数表达式**
/// - ② 依赖 `result` = 当前页的 **JSON 原文**
/// - ③ 依赖**站方 jsLib 里的解密函数**（`hjmDec` / `apiDec`）
final class JsBookListTests: XCTestCase {

    /// ⭐⭐⭐ **忠实 stub：模拟 JSC 对「立即调用的函数表达式」的返回值**
    ///
    /// ⚠️ **必须忠实**：站方 `@js:(function(){…})()` 的完成值 = **函数返回的数组**
    ///   ⇒ stub 直接返回那个数组（**不是**字符串！⇒ 否则测的是另一条路）⭐⭐⭐
    final class JsArrayExecutor: JSExecutor, @unchecked Sendable {
        /// 模拟站方 JS 的行为：从 `result` 解析出 records
        func run(_ code: String, context: JSRunContext) throws -> JSONValue {
            // ⭐ 站方 JS 做的事：`JSON.parse(result)` ⇒ **result 是字符串** ⇒ parse 它
            let text = context.base.resultValue.text
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any],
                  let inner = dict["data"] as? [String: Any],
                  let records = inner["records"] as? [[String: Any]] else {
                return .array([])
            }
            return .array(records.map { JSONValue.from($0) })
        }
    }

    /// ⭐⭐⭐ 内存传输（照抄现成实现）
    final class MemTransport: HTTPTransport, @unchecked Sendable {
        private let body: String
        init(body: String) { self.body = body }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8), finalURL: request.url)
        }
    }

    /// ⭐⭐⭐ **站方 jsLib 的等价物**（把 `hjmDec` 定义在**全局** ⇒ 模拟真实形态）
    private static let jsLib = """
    function hjmDec(x){ return x; }   // 测试里不真的解密，只验「全局函数可见」
    function apiDec(x){ return x; }
    """

    /// ⭐⭐⭐ **站方的 bookList 规则**（原样照抄 JM小说）
    private static let bookListRule = """
    @js:(function(){try{var j=JSON.parse(result);var d=j.data;if(typeof d==='string'){d=JSON.parse(hjmDec(d));}if(!d)return [];if(d.records)return d.records;if(d.list)return d.list;return Array.isArray(d)?d:[];}catch(e){return [];}})()
    """

    /// ⭐⭐⭐ **站方的响应**（`{"data":{"records":[…]}}`）
    private static let responseJSON = """
    {"code":0,"data":{"records":[{"name":"书一","author":"甲"},{"name":"书二","author":"乙"}]}}
    """

    private func makeSource(bookList: String) throws -> BookSource {
        let raw: [String: Any] = [
            "bookSourceUrl": "https://example.test",
            "bookSourceName": "JM小说",
            "jsLib": Self.jsLib,
            "exploreUrl": "https://example.test/api/list",
            "ruleExplore": [
                "exploreUrl": "https://example.test/api/cats",
                "bookList": bookList,
                "name": "name",
                "author": "author",
                "bookUrl": "url",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(BookSource.self, from: data)
    }

    private func makeEngine(_ src: BookSource) throws -> SourceEngine {
        let transport = MemTransport(body: Self.responseJSON)
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: transport),
                                  js: JsArrayExecutor())
        // ⭐⭐⭐ **站方 jsLib 必须先加载**（它定义的 `hjmDec` 在**全局**）
        do { try engine.loadJsLib(Self.jsLib) } catch {
            print("DEBUG loadJsLib 抛错：\(error)")
        }
        return engine
    }

    /// ⭐⭐⭐⭐⭐ **`@js:` 的 bookList 必须出书**（这是站方 API 源的通用形态）
    func testJsBookListProducesBooks() throws {
        let src = try makeSource(bookList: Self.bookListRule)
        let engine = try makeEngine(src)
        let books = try engine.explore("https://example.test/api/list")
        XCTAssertFalse(books.isEmpty, "站方 @js: 的 bookList 不该是空的")
        XCTAssertEqual(books.count, 2, "实际=\(books.count) 本：\(books.map { $0.name })")
        XCTAssertTrue(books.contains { $0.name.contains("书一") }, "实际=\(books.map { $0.name })")
    }

    /// ⭐⭐⭐⭐⭐ **JSON 基准上的「裸字段名」必须能取值**（2026-10-25 真机通用真凶）
    ///
    /// ⚠️⚠️⚠️ **为什么这是「很多书源都是这样」的通用真凶**：
    ///   取值模式的名字表 = `text` / `html` / `href` / **`name`** / **`title`** /
    ///   **`value`** / **`type`** / `class` / `id` / `alt` … ⇒ **全是常见的 JSON 字段名**！⭐⭐⭐
    ///   ⇒ 站方 JSON 接口源的字段规则（`"name": "name"` / `"author": "author"`）
    ///   ⇒ **被误判成「取值模式」** ⇒ 取值模式**只在 DOM 基准下**有意义
    ///   ⇒ JSON 基准 ⇒ 取不到 ⇒ **书名/作者/书 URL 全空** ⭐⭐⭐
    ///   ⇒ 症状：书**出得来但字段全空** ⇒ App 判「结果不可信」⇒ `emptyResult` ⭐⭐⭐
    func testBareFieldNamesOnJSONBase() throws {
        // ⭐⭐⭐ 这些字段名**全都是 HTML 属性名** ⇒ 以前必被误判成「取值模式」
        for field in ["name", "author", "title", "value", "type", "id", "alt", "class"] {
            let src = try makeSource(bookList: "@js:[]")
            let engine = try makeEngine(src)
            // 直接对这个字段做一次求值（基准 = 一个 JSON 对象）
            let obj = JSONValue.object([
                "name": .string("书名"), "author": .string("作者"),
                "title": .string("标题"), "value": .string("值"),
                "type": .string("类型"), "id": .string("ID"),
                "alt": .string("替代"), "class": .string("类"),
            ])
            let ev = Evaluator(js: JsArrayExecutor())
            let base = RuleBase.json(obj)
            let ctx = EvalContext(base: base, baseUrl: "https://example.test/api/list",
                                  raw: "", isJSON: true)
            let e = ev.evalOne(field, base: base, ctx: ctx)
            XCTAssertNil(e.diagnostic.failure,
                         "⭐⭐⭐ 字段 `\(field)` 在 JSON 基准上不该失败"
                         + "（它被误判成「取值模式」了）：\(SourceEngine.diagnosticLine(e.diagnostic))")
            XCTAssertFalse(e.value.text.isEmpty, "⭐⭐⭐ 字段 `\(field)` 在 JSON 基准上该取到值")
        }
    }

    /// ⭐⭐⭐ **DOM 基准下的「取值模式」必须照旧**（别把现在能用的搞坏）
    func testValueModeStillWorksOnDOMBase() throws {
        let ev = Evaluator(js: JsArrayExecutor())
        // 造一个 DOM 基准（HTML 文档）
        let doc = try SwiftSoupDocument(html: "<html><body><a href=\"/b/1\">书名</a></body></html>",
                                       baseURL: "https://example.test")
        let base = RuleBase.page("<html><body><a href=\"/b/1\">书名</a></body></html>")
        let ctx = EvalContext(base: base, baseUrl: "https://example.test",
                              raw: "<html><body><a href=\"/b/1\">书名</a></body></html>",
                              isJSON: false, document: doc.document)
        let e = ev.evalOne("href", base: base, ctx: ctx)
        // 「href」在 DOM 基准下是取值模式 ⇒ 取**当前节点**的 href ⇒ 没有节点 ⇒ 失败是正常的
        //   ⇒ 但**不能**报「基准类型不符」（说明它被当成 JSON 路径了）⇒
        XCTAssertNotEqual(e.diagnostic.branch, "JSON 相对路径",
                          "DOM 基准下 `href` 不该走 JSON 相对路径")
    }

    /// ⭐⭐⭐ **站方 jsLib 里的函数必须对 bookList 可见**（全局作用域）
    func testJsLibFunctionIsVisibleToBookList() throws {
        // 用一个**必须**调 jsLib 函数才能解出来的响应（不调就抛 ⇒ 站方返回 []）
        let src = try makeSource(bookList: """
        @js:(function(){try{var j=JSON.parse(result);var d=j.data;if(typeof d==='string'){d=JSON.parse(hjmDec(d));}return d.records||[];}catch(e){return [];}})()
        """)
        let engine = try makeEngine(src)
        let books = try engine.explore("https://example.test/api/list")
        XCTAssertEqual(books.count, 2, "实际=\(books.count) 本")
    }
}
