import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **JSON 源 / init 规则 / 原始字段 / 宿主对象** 的门禁。
///
/// ⚠️ **这些是「把老引擎完全换掉」的前置条件**（2026-10-23 换引擎时暴露的四个缺口）：
/// ① **JSON 列表源**：以前编排层的列表项**只有 DOM 节点** ⇒ JSONPath 命中的是 JSON 值
///    ⇒ `evalNodes` 返回空 ⇒ **JSON 接口源一个都出不来**（列表 0 本）⭐
/// ② **裸字段名相对取值**：站方 JSON 源的字段规则是**裸字段名**（`name: "bookName"`）
///    ⇒ 老引擎在 JSON 基准上返回空 ⇒ 字段全空 ⭐
/// ③ **`ruleBookInfo.init`**：JSON 接口源几乎全靠它（`$.data` 把包装层剥掉）
/// ④ **原始字段（raw）**：站方聚合源要 `book_id` 之类 ⇒ 少了整本书崩（base64 报错）⭐
///
/// ⭐ **输入全部自己造**（不依赖任何外部快照）⇒ 改坏实现时这些门禁**必然变红**。
final class JsonSourceSupportTests: XCTestCase {

    // MARK: - 假传输（按 URL 返回固定响应）

    final class FixedTransport: HTTPTransport, @unchecked Sendable {
        private let byURL: [String: Data]
        init(_ byURL: [String: Data]) { self.byURL = byURL }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            // ⚠️ URL 里的中文会被**百分号编码** ⇒ 用「包含」匹配，别拿原串当 key
            for (key, body) in byURL where request.url.contains(key) {
                return HTTPResponse(statusCode: 200, headers: [:], body: body, finalURL: request.url)
            }
            throw SourceError.requestFailed(request.url, "测试里没有这个 URL")
        }
    }

    private func makeEngine(_ sourceJSON: String, responses: [String: String]) throws -> SourceEngine {
        let source = try JSONDecoder().decode(BookSource.self, from: Data(sourceJSON.utf8))
        let transport = FixedTransport(responses.mapValues { Data($0.utf8) })
        return SourceEngine(source: source, fetcher: PageFetcher(transport: transport))
    }

    // MARK: - ① JSON 列表源

    /// ⭐⭐⭐ **JSON 接口源要能出书**（以前一个都出不来）
    func testJSONListSourceProducesBooks() throws {
        let listJSON = """
        {"code":0,"data":{"books":[
          {"bookId":101,"bookName":"斗破苍穹","authorName":"天蚕土豆","bid":"XID-001","words":90000},
          {"bookId":102,"bookName":"庆余年","authorName":"猫腻","bid":"XID-002","words":120000}
        ]}}
        """
        let sourceJSON = """
        {"bookSourceName":"JSON源","bookSourceUrl":"https://json.example.com",
         "searchUrl":"https://json.example.com/search?q={{key}}&page={{page}}",
         "ruleSearch":{"bookList":"$.data.books","name":"bookName","author":"authorName",
                       "bookUrl":"bookId","wordCount":"words"}}
        """
        let engine = try makeEngine(sourceJSON, responses: [
            "json.example.com/search": listJSON,
        ])
        let books = try engine.search("斗破苍穹", page: 1)
        XCTAssertEqual(books.count, 2, "JSON 列表源必须能出书（老引擎这里是 0 本）")
        XCTAssertEqual(books[0].name, "斗破苍穹")
        XCTAssertEqual(books[0].author, "天蚕土豆")
        XCTAssertEqual(books[1].name, "庆余年")
        XCTAssertEqual(books[0].wordCount, "90000")
        XCTAssertTrue(books[0].bookUrl.contains("101"), "bookUrl 应由 bookId 拼出来")
    }

    // MARK: - ② 裸字段名相对取值

    /// ⭐⭐⭐ **裸字段名要相对当前 JSON 项取**（`name: "bookName"`）
    func testBareFieldNameResolvesRelativeToJSONItem() throws {
        let listJSON = """
        {"code":0,"data":{"books":[{"bookName":"九界吞天","authorName":"我吃西红柿"}]}}
        """
        let sourceJSON = """
        {"bookSourceName":"JSON源","bookSourceUrl":"https://json.example.com",
         "searchUrl":"https://json.example.com/s?k={{key}}",
         "ruleSearch":{"bookList":"$.data.books","name":"bookName","author":"authorName"}}
        """
        let engine = try makeEngine(sourceJSON, responses: [
            "https://json.example.com/s?k=x": listJSON,
        ])
        let books = try engine.search("x", page: 1)
        XCTAssertEqual(books.count, 1)
        // ⭐ 这两条在老引擎上是**空**（JSON 基准上按 CSS 查 ⇒ 0 命中）
        XCTAssertEqual(books[0].name, "九界吞天", "裸字段名必须相对当前 JSON 项取值")
        XCTAssertEqual(books[0].author, "我吃西红柿")
    }

    // MARK: - ③ init 规则

    /// ⭐⭐⭐ **`ruleBookInfo.init` 要把字段规则的基准换掉**
    func testInitRuleRebasesDetailFields() throws {
        let detailJSON = """
        {"code":0,"msg":"ok","data":{"bookName":"庆余年","authorName":"猫腻","catalog":"/toc/7"}}
        """
        let withInit = """
        {"bookSourceName":"JSON源","bookSourceUrl":"https://json.example.com",
         "ruleBookInfo":{"init":"$.data","name":"bookName","author":"authorName","tocUrl":"catalog"}}
        """
        let withoutInit = """
        {"bookSourceName":"JSON源","bookSourceUrl":"https://json.example.com",
         "ruleBookInfo":{"name":"bookName","author":"authorName","tocUrl":"catalog"}}
        """
        let book = Book(bookUrl: "https://json.example.com/book/1")

        let e1 = try makeEngine(withInit, responses: ["https://json.example.com/book/1": detailJSON])
        let info = try e1.bookInfo(book)
        XCTAssertEqual(info.name, "庆余年", "init 之后字段规则要在 init 的输出上求值")
        XCTAssertEqual(info.author, "猫腻")
        XCTAssertTrue(info.tocUrl.contains("/toc/7"))

        // ⚠️ **反向验证**：没有 init ⇒ 基准是整个包装 JSON ⇒ 裸字段名取不到
        let e2 = try makeEngine(withoutInit, responses: ["https://json.example.com/book/1": detailJSON])
        let info2 = try e2.bookInfo(book)
        XCTAssertEqual(info2.name, "", "没有 init 时不该命中（否则这条门禁就是装饰品）")
    }

    // MARK: - ④ 原始字段（raw）

    /// ⭐⭐⭐ **列表项的原始字段必须保留**（站方聚合源要 `book_id` 之类）
    func testRawFieldsArePreserved() throws {
        let listJSON = """
        {"code":0,"data":{"books":[{"bookId":101,"bookName":"斗破苍穹","bid":"XID-001","item_id":"it-9"}]}}
        """
        let sourceJSON = """
        {"bookSourceName":"JSON源","bookSourceUrl":"https://json.example.com",
         "searchUrl":"https://json.example.com/s?k={{key}}",
         "ruleSearch":{"bookList":"$.data.books","name":"bookName"}}
        """
        let engine = try makeEngine(sourceJSON, responses: [
            "https://json.example.com/s?k=x": listJSON,
        ])
        let books = try engine.search("x", page: 1)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].raw["bookId"], "101", "原始字段 bookId 必须保留")
        XCTAssertEqual(books[0].raw["bid"], "XID-001", "原始字段 bid 必须保留")
        XCTAssertEqual(books[0].raw["item_id"], "it-9")
    }

    // MARK: - ⑤ `result.` 前缀的两种语义

    /// ⭐⭐⭐ **`result.X` 要两种语义都覆盖**（规格 §32）
    ///
    /// ① 根别名：基准 `{"bookName":"X"}` + 规则 `result.bookName` ⇒ 命中
    /// ② 顶层 `result` 字段：基准 `{"code":0,"result":{"resultList":[…]}}` + 规则 `result.resultList` ⇒ 命中
    func testResultPrefixTriesBothMeanings() throws {
        let ev = Evaluator()

        // ① 根别名
        let j1 = JSONValue(json: #"{"bookName":"斗破苍穹"}"#)
        let e1 = ev.evalOne("result.bookName", base: .json(j1),
                            ctx: EvalContext(base: .json(j1), isJSON: true))
        XCTAssertEqual(e1.value.text, "斗破苍穹", "result. 的根别名语义要能用")

        // ② 顶层 result 字段（纵横中文的真实形态）
        let j2 = JSONValue(json: #"{"code":0,"result":{"resultList":[{"bookName":"庆余年"}]}}"#)
        let e2 = ev.evalOne("result.resultList", base: .json(j2),
                            ctx: EvalContext(base: .json(j2), isJSON: true))
        XCTAssertEqual(e2.value.items.count, 1, "result. 命中不到根时 ⇒ 兜底试顶层 result 字段")
        // ⚠️ 命中的是**数组** ⇒ `text` 是空串（数组没有标量文本）⇒ 要看元素
        if case .json(let item) = e2.value.items[0] {
            XCTAssertEqual(item["bookName"]?.scalarString, "庆余年",
                           "兜底命中的是顶层 result 下的 resultList")
        } else {
            XCTFail("兜底结果不是 JSON 对象")
        }
    }

    // MARK: - ⑥ 数组形式的规则字段

    /// ⭐⭐ **规则字段写成数组** ⇒ 要能解出来（以前整条规则**静默丢失**）
    func testArrayRuleFieldIsDecodedAsMultiLine() throws {
        let listJSON = """
        {"code":0,"data":{"books":[{"a":"","b":"命中的是第二条","c":"第三条"}]}}
        """
        let sourceJSON = """
        {"bookSourceName":"JSON源","bookSourceUrl":"https://json.example.com",
         "searchUrl":"https://json.example.com/s?k={{key}}",
         "ruleSearch":{"bookList":"$.data.books","name":["a","b","c"]}}
        """
        let engine = try makeEngine(sourceJSON, responses: [
            "https://json.example.com/s?k=x": listJSON,
        ])
        let books = try engine.search("x", page: 1)
        XCTAssertEqual(books.count, 1)
        // ⭐ 字段出口 = **第一个非空**（Legado 语义）
        XCTAssertEqual(books[0].name, "命中的是第二条")
    }

    // MARK: - ⑥ 宿主对象

    /// ⭐⭐⭐ **`book` 宿主对象要带得上书籍变量**（站方 `book.getVariable('custom')`）
    func testBookHostObjectCarriesVariables() throws {
        let book = Book(name: "书名", author: "作者", bookUrl: "https://x.example.com/1",
                        raw: ["book_id": "77"])
        let obj = SourceEngine.makeBookObject(book, variables: ["custom": "站方要的变量"])
        XCTAssertEqual(obj.call("getVariable", [.string("custom")])?.scalarString, "站方要的变量")
        XCTAssertEqual(obj.property("name")?.scalarString, "书名")
        // ⭐ 原始字段也要挂上去（站方 `book.book_id`）
        XCTAssertEqual(obj.property("book_id")?.scalarString, "77")
    }

    /// ⭐⭐⭐ **书源对象**：`getVariable()` / `get` / `put` / `getKey` / 登录信息
    ///
    /// ⚠️ **语义照抄老引擎 `source-api.js`**（事实标准）：
    /// - `source.getVariable()` ⇒ **整份变量串**（**无参**！185 处真实用法）
    /// - `source.get(key)` ⇒ **变量的某一项**（**127 处**真实用法 ⇒ 少了就静默失效 + 假成功）⭐
    /// - `source.put(key, value)` ⇒ 写某一项
    /// - `source.getKey()` ⇒ 稳定的源标识（42 处真实用法）
    func testSourceHostObjectReadsVarBox() throws {
        let source = try JSONDecoder().decode(BookSource.self, from: Data("""
        {"bookSourceName":"某源","bookSourceUrl":"https://src.example.com"}
        """.utf8))
        let box = VarBox()
        box.set("server", "https://fast.example.com")
        let obj = SourceEngine.makeSourceObject(source, varBox: box,
                                                loginInfo: ["uid": "42"])

        // ① `getVariable()` = **整份**（无参）
        let whole = obj.call("getVariable", [])?.scalarString ?? ""
        XCTAssertTrue(whole.contains("server"), "getVariable() 要返回整份变量串：\(whole)")
        XCTAssertTrue(whole.contains("fast.example.com"))

        // ② ⭐ `get(key)` = **某一项**（没有 ⇒ 空串）
        XCTAssertEqual(obj.call("get", [.string("server")])?.scalarString,
                       "https://fast.example.com")
        XCTAssertEqual(obj.call("get", [.string("没设置")])?.scalarString, "",
                       "没这一项要返回空串（站方按「空串=没设置」处理）")

        // ③ ⭐ `put(key, value)` = 写一项（**不能**返回整份 ⇒ 站方哈希对不上）
        _ = obj.call("put", [.string("nhAuthed"), .string("HASH-1")])
        XCTAssertEqual(box.get("nhAuthed"), "HASH-1", "put 要写进共享存储")
        XCTAssertEqual(obj.call("get", [.string("nhAuthed")])?.scalarString, "HASH-1")

        // ④ `getKey()` = 稳定的源标识
        XCTAssertEqual(obj.call("getKey", [])?.scalarString, "https://src.example.com")

        XCTAssertEqual(obj.property("bookSourceUrl")?.scalarString, "https://src.example.com")
        let info = obj.call("getLoginInfoMap", [])
        XCTAssertEqual(info?["uid"]?.scalarString, "42")
    }

    /// ⭐⭐ **cookie 宿主对象**（站方 `cookie.*` —— 真实语料 **205 处**）
    func testCookieHostObjectDelegatesToService() {
        let service = MemoryCookieService()
        let obj = SourceEngine.makeCookieObject(service)
        XCTAssertEqual(obj.call("getCookie", [.string("https://x.example.com/")])?.scalarString, "")
        _ = obj.call("setCookie", [.string("https://x.example.com/"), .string("a=1")])
        XCTAssertEqual(obj.call("getCookie", [.string("https://x.example.com/")])?.scalarString, "a=1")
        _ = obj.call("replaceCookie", [.string("https://x.example.com/"), .string("b=2")])
        XCTAssertEqual(obj.call("getCookie", [.string("https://x.example.com/")])?.scalarString, "b=2")
        _ = obj.call("removeCookie", [.string("https://x.example.com/")])
        XCTAssertEqual(obj.call("getCookie", [.string("https://x.example.com/")])?.scalarString, "")
    }

    /// ⭐ **书籍对象**：`book.getVariable('custom')` = 书籍变量的某一项（30 处真实用法）
    func testBookHostObjectGetVariableSingleItem() {
        let book = Book(name: "书名", bookUrl: "https://x.example.com/1")
        let obj = SourceEngine.makeBookObject(book, variables: ["custom": "站方要的变量"])
        XCTAssertEqual(obj.call("getVariable", [.string("custom")])?.scalarString, "站方要的变量")
        XCTAssertEqual(obj.call("getVariable", [.string("没有")])?.scalarString, "")
    }
}
