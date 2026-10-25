import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **站方没给详情规则 ⇒ 字段要继承【列表页】的值**（2026-10-25 真机实证）
///
/// **症状**：某本书源详情页报「`bookInfo` 结果不可信：书名/书 URL 是空的」
/// ⇒ 但界面上书名明明有（那是从**列表页**来的）⇒ **详情把它清空了** ⭐⭐⭐
///
/// ⭐⭐⭐ **这是通用回归，不是一个源的问题**：
///   **125 个真源里 25 个（20%）的 `ruleBookInfo` 压根没有 `name` 规则**
///   ⇒ 它们的书名**本来就该从列表项继承**（Legado 语义）⭐⭐⭐
///   ⇒ 引擎以前**无条件赋值** ⇒ 站方没给规则时**把列表页带来的书名清空了** ⭐⭐⭐
///
/// ⭐ **权威口径 = 老引擎**（`engine.js` 的 bookInfo）：
///   `name: v[0] || (p.book && p.book.name) || ''`  ⇒ **有 fallback** ⭐⭐⭐
///   ⇒ 新引擎少了这个 fallback ⇒ **行为不一致 = 回归** ⭐⭐⭐
///
/// ⚠️ **判据必须是「规则为空」而不是「求值结果为空」**：
///   规则存在但没命中 ⇒ 那是**站方的问题** ⇒ 应当如实为空，**不该拿列表页的糊弄** ⭐⭐⭐
final class BookInfoInheritsFromListTests: XCTestCase {

    /// ⭐⭐⭐ 内存传输（照抄现成实现）
    final class MemTransport: HTTPTransport, @unchecked Sendable {
        private let body: String
        init(body: String) { self.body = body }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8), finalURL: request.url)
        }
    }

    private func makeSource(ruleBookInfo: [String: Any]) throws -> BookSource {
        let raw: [String: Any] = [
            "bookSourceUrl": "https://example.test",
            "bookSourceName": "继承源",
            "ruleBookInfo": ruleBookInfo,
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(BookSource.self, from: data)
    }

    /// ⭐⭐⭐⭐⭐ **站方没给 `name` 规则 ⇒ 书名要继承列表页的**
    func testNameInheritsFromBookWhenNoRule() throws {
        let src = try makeSource(ruleBookInfo: ["author": "id.a@tag.p@text"])
        let engine = SourceEngine(source: src,
                                  fetcher: PageFetcher(transport: MemTransport(body: "<html><p>x</p></html>")))
        var b = Book()
        b.bookUrl = "https://example.test/book/1"
        b.name = "列表页带来的书名"     // ⭐ 列表页已经有的
        b.author = "列表页作者"
        let info = try engine.bookInfo(b)
        XCTAssertEqual(info.name, "列表页带来的书名", "站方没给 name 规则 ⇒ 该继承列表页的")
    }

    /// ⭐⭐⭐⭐⭐ **其他字段同理**（author / intro / kind / coverUrl / lastChapter / wordCount）
    func testAllFieldsInheritWhenNoRule() throws {
        let src = try makeSource(ruleBookInfo: [:])
        let engine = SourceEngine(source: src,
                                  fetcher: PageFetcher(transport: MemTransport(body: "<html></html>")))
        var b = Book()
        b.bookUrl = "https://example.test/book/1"
        b.name = "书名"; b.author = "作者"; b.intro = "简介"
        b.kind = "类型"; b.coverUrl = "https://example.test/c.jpg"
        b.lastChapter = "第10章"; b.wordCount = "12万字"
        let info = try engine.bookInfo(b)
        XCTAssertEqual(info.name, "书名")
        XCTAssertEqual(info.author, "作者")
        XCTAssertEqual(info.intro, "简介")
        XCTAssertEqual(info.kind, "类型")
        XCTAssertEqual(info.coverUrl, "https://example.test/c.jpg")
        XCTAssertEqual(info.lastChapter, "第10章")
        XCTAssertEqual(info.wordCount, "12万字")
    }

    /// ⭐⭐⭐⭐⭐ **站方**给了**规则** ⇒ 用规则的（**不继承**）
    func testRuleWinsOverBook() throws {
        let src = try makeSource(ruleBookInfo: ["name": "h1@text"])
        let engine = SourceEngine(source: src,
                                  fetcher: PageFetcher(transport: MemTransport(body: "<html><h1>详情书名</h1></html>")))
        var b = Book()
        b.bookUrl = "https://example.test/book/1"
        b.name = "列表页的书名"
        let info = try engine.bookInfo(b)
        XCTAssertTrue(info.name.contains("详情书名"), "站方给了规则 ⇒ 该用规则的：\(info.name)")
    }

    /// ⭐⭐⭐⭐⭐ **失败诊断能被宿主拿到**（⇒ 错误信息能说清「哪条规则失败」）
    ///   2026-10-25 真机教训：App 只说「书名/书 URL 是空的」⇒ 用户**完全不知道该查哪** ⭐⭐⭐
    func testFailureDiagnosticsAreExported() throws {
        let src = try makeSource(ruleBookInfo: ["name": "不存在的选择器@text"])
        let engine = SourceEngine(source: src,
                                  fetcher: PageFetcher(transport: MemTransport(body: "<html><h1>x</h1></html>")))
        var b = Book()
        b.bookUrl = "https://example.test/book/1"
        b.name = "列表页的书名"
        _ = try engine.bookInfo(b)
        let lines = engine.failureDiagnosticLines
        XCTAssertFalse(lines.isEmpty, "失败的诊断行不该是空的")
        XCTAssertTrue(lines.joined().contains("规则["), "诊断行要带规则原文：\(lines)")
    }

    /// ⭐⭐⭐⭐⭐ **规则存在但【没命中】⇒ 如实为空**（不拿列表页的糊弄）
    ///   ⇒ 这是**站方的问题** ⇒ 不该被掩盖 ⭐⭐⭐
    func testRulePresentButNoMatchStaysEmpty() throws {
        let src = try makeSource(ruleBookInfo: ["name": "不存在的选择器@text"])
        let engine = SourceEngine(source: src,
                                  fetcher: PageFetcher(transport: MemTransport(body: "<html><h1>x</h1></html>")))
        var b = Book()
        b.bookUrl = "https://example.test/book/1"
        b.name = "列表页的书名"
        let info = try engine.bookInfo(b)
        XCTAssertTrue(info.name.isEmpty,
                      "规则存在但没命中 ⇒ 应当如实为空（不该用列表页的糊弄）：\(info.name)")
    }
}
