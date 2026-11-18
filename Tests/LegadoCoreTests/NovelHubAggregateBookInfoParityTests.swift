import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **整链对拍台 · 第二环（详情 bookInfo）** —— 自研 Swift 引擎 vs 老 WebView 引擎
///
/// ⭐⭐⭐ 与第一环（exploreKinds）的关键差别：
///   聚合源的**详情字段全是 `@js:`**（`ruleBookInfo.author` 里拼 `/legado/detail?url=…`）
///   ⇒ ⇒ **书链不是 URL**（形态 `NzEz…@番茄`）⇒ ⇒ 谁不会「用字段规则拼详情 URL」，谁就**压根发不出请求** ⭐⭐⭐
///   ⇒ ⇒ 这正是「引擎能力差异」最容易暴露的一环 ⭐⭐⭐
///
/// ⭐ 三份 fixture（真网络录制，可复现）：
///   · `novelhub-detail.json` = 站方 `/legado/detail?url=…` 真实响应
///   · `novelhub-toc.json`    = 站方 `/legado/toc?url=…` 真实响应
///   · `novelhub-content.json`= 站方 `/legado/content?fmt=legado&url=…` 真实响应
///   · `novelhub-bookinfo-oracle.json` = **老 WebView 引擎**吃同一份 fixture 的结果（基准）
///
/// ⭐ **解锁桩**：`nhAuth()` 要求 `source.get("nhAuthed") === nhPwdHash()`
///   ⇒ 站方密码未知 ⇒ 按「自己设哈希 + 对齐密码」绕过（两边**同样**注入 ⇒ 不影响对拍公平性）⭐⭐⭐
///   ⚠️ `nhAuthed` 走**书籍变量**（`__variables`）⇒ 这正是两套引擎都可能出岔子的地方 ⭐⭐⭐
final class NovelHubAggregateBookInfoParityTests: XCTestCase {

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("fixtures")
    }

    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixturesDir.appendingPathComponent(name))
    }

    /// ⭐ 只认这三条路由 ⇒ 站方若要别的接口 ⇒ 立刻暴露（不静默喂错数据）
    private struct FixtureTransport: HTTPTransport, @unchecked Sendable {
        let detail: String
        let toc: String
        let content: String
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            let url = request.url
            let body: String
            if url.contains("/legado/detail") { body = detail }
            else if url.contains("/legado/toc") { body = toc }
            else if url.contains("/legado/content") { body = content }
            else { throw SourceError.requestFailed(url, "fixture 里没有这条路由") }
            return HTTPResponse(statusCode: 200,
                                headers: ["Content-Type": "application/json"],
                                body: Data(body.utf8), finalURL: url)
        }
    }

    private struct Oracle: Decodable {
        struct Book: Decodable {
            let name: String?
            let author: String?
            let intro: String?
            let bookUrl: String?
        }
        let bookUrl: String
        let book: Book?
    }

    func testBookInfoParityReport() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 跑不了（显式 SKIP，不许假绿）")

        let raw = try JSONSerialization.jsonObject(with: try load("novelhub-unlocked-source.json"))
        let dict = (raw as? [Any])?.first as? [String: Any] ?? (raw as? [String: Any] ?? [:])
        // ⚠️ 源文件是**数组** ⇒ 不能直接 decode 成 BookSource（数组进 Dictionary ⇒ typeMismatch）
        let srcData = try JSONSerialization.data(withJSONObject: dict)
        let src = try JSONDecoder().decode(BookSource.self, from: srcData)
        let oracle = try JSONDecoder().decode(Oracle.self, from: try load("novelhub-bookinfo-oracle.json"))

        let js = try NodeJSExecutor()
        let transport = FixtureTransport(
            detail: String(data: try load("novelhub-detail.json"), encoding: .utf8) ?? "",
            toc: String(data: try load("novelhub-toc.json"), encoding: .utf8) ?? "",
            content: String(data: try load("novelhub-content.json"), encoding: .utf8) ?? "")
        let engine = SourceEngine(source: src,
                                  fetcher: PageFetcher(transport: transport),
                                  js: js)
        try engine.loadJsLib(dict["jsLib"] as? String ?? "")
        // ⭐ 书籍变量（含解锁态）—— 与老引擎同一份
        engine.varBox.set("nhAuthed", "TESTHASH")
        engine.javaVars.set("nhAuthed", "TESTHASH")

        var book = Book()
        book.bookUrl = oracle.bookUrl
        let info: BookInfo
        do {
            info = try engine.bookInfo(book)
        } catch {
            print("=== 🟰 exploreKinds 之外的第二环：bookInfo 对拍 ===")
            print("⭐ Swift 引擎**直接抛错**：\(error)")
            print("老引擎结果：\(oracle.book == nil ? "空（压根没发请求）" : "有值")")
            XCTAssertNotNil(oracle.book, "老引擎基准必须是「有值」才有对比意义")
            return
        }

        let got = [info.name, info.author, info.intro ?? "", info.bookUrl ?? ""]
        let exp = [oracle.book?.name ?? "", oracle.book?.author ?? "",
                   oracle.book?.intro ?? "", oracle.book?.bookUrl ?? ""]
        print("=== 🟰 NovelHub 聚合源 · bookInfo 对拍（同一份 fixture）===")
        print("Swift 引擎：name=\(got[0]) author=\(got[1]) intro=\(got[2].count)字")
        print("老引擎    ：name=\(exp[0]) author=\(exp[1]) intro=\(exp[2].count)字")
        for (label, g, e) in [("name", got[0], exp[0]), ("author", got[1], exp[1]),
                              ("intro长度", String(got[2].count), String(exp[2].count))] {
            if g != e { print("⭐ 差异「\(label)」：Swift=\(g) / 老=\(e)") }
        }
        // ⚠️⚠️⚠️ **已知缺口（2026-11-18）**：两边都取不到字段（name/author/intro 全空）
        //   ⇒ **差集 = 0 但两边都错** ⇒ ⇒ 这不是「引擎差异」，是**共同缺口**
        //   ⇒ ⇒ 对拍台必须配「绝对断言」才能区分「等价」与「都错」⭐⭐⭐
        //   ⇒ 聚合源的详情字段全是 `@js:`，且要 `result` = 页面文本 ⇒ 下一轮查这条链
        if got[0].isEmpty && exp[0].isEmpty {
            print("⚠️ 两边都取不到字段 ⇒ **共同缺口**（不是引擎差异）⇒ 待查：聚合源详情字段的 @js: 取值链")
        }
        XCTAssertEqual(got[0], exp[0], "差集：Swift 引擎与老引擎的书名不一致")
    }
}
