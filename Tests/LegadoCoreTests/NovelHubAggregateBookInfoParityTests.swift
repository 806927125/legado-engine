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

    /// ⭐⭐⭐⭐⭐ **详情环探针（自证版）** —— 2026-11-18
    ///
    /// ⚠️ **上一版对拍台两边都空 ⇒ 但那不是「引擎差异」** ⇒ 探针没自证 ⇒ 三处坑：
    ///   ① fixture 的 jsLib 末尾带对拍桩 `function nhPwdHash(){ return "TESTHASH"; }`
    ///      ⇒ 解锁态 = `nhAuthed === "TESTHASH"`（不是出厂哈希！）
    ///   ② 原生桥响应形态 = `{ok, code, body}`（`{value, status}` ⇒ 正文恒空）
    ///   ③ ⭐⭐⭐ **`result` 的语义**：站方 `JSON.parse(String(result))` 要的是**页面原文**，
    ///      而引擎把 init 的输出**强制 parse 成对象** ⇒ `String(result)` = `[object Object]`
    ///      ⇒ 栖阅的做法 = 给 JSON 对象覆写 `toString/valueOf` ⇒ 回到原始文本 ⭐⭐⭐
    ///
    /// ⇒ 本探针把「引擎内部到底发生了什么」原样打出来（**不猜**）。
    func testBookInfoProbe() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 跑不了（显式 SKIP，不许假绿）")

        let probe = #"""
        @js: (function(){
          var o = [];
          function add(k, f) { try { o.push(k + '=' + String(f())); } catch (e) { o.push(k + '!=' + String(e).slice(0,60)); } }
          add('auth', function(){ return nhAuth(); });
          add('getType', function(){ return typeof source.get; });
          add('got', function(){ return String(source.get('nhAuthed')).slice(0,12); });
          add('pwd', function(){ return String(nhPwdHash()).slice(0,12); });
          add('resType', function(){ return (typeof result); });
          add('resLen', function(){ return (typeof result !== 'undefined' && result != null) ? String(result).length : -1; });
          add('resHead', function(){ return String(result).slice(0,50).replace(/\n/g,' '); });
          add('bu', function(){ return String(book && book.bookUrl).slice(0,26); });
          add('baseUrl', function(){ return String(baseUrl).slice(0,40); });
          add('jsonName', function(){ return String(JSON.parse(String(result)).name); });
          return o.join(' | ');
        })()
        """#

        let raw = try JSONSerialization.jsonObject(with: try load("novelhub-unlocked-source.json"))
        var dict = (raw as? [Any])?.first as? [String: Any] ?? (raw as? [String: Any] ?? [:])
        // ⭐ 探针塞进 wordCount（不污染基准）⇒ 回读就能看到引擎内部状态
        var bi = (dict["ruleBookInfo"] as? [String: Any]) ?? [:]
        bi["wordCount"] = probe
        dict["ruleBookInfo"] = bi

        let srcData = try JSONSerialization.data(withJSONObject: dict)
        let src = try JSONDecoder().decode(BookSource.self, from: srcData)

        let transport = FixtureTransport(
            detail: String(data: try load("novelhub-detail.json"), encoding: .utf8) ?? "",
            toc: String(data: try load("novelhub-toc.json"), encoding: .utf8) ?? "",
            content: String(data: try load("novelhub-content.json"), encoding: .utf8) ?? "")
        let js = try NodeJSExecutor()
        let engine = SourceEngine(source: src,
                                  fetcher: PageFetcher(transport: transport),
                                  js: js)
        try engine.loadJsLib(dict["jsLib"] as? String ?? "")
        engine.varBox.set("nhAuthed", "TESTHASH")
        engine.javaVars.set("nhAuthed", "TESTHASH")
        // ⭐⭐⭐⭐⭐ **书籍变量必须灌进【宿主状态快照】**（2026-11-18 整链对拍实证）
        //
        // ⚠️ **为什么**：Node 后端的 `source.get(k)` 读的是宿主状态里的 `source.vars`
        //   （`HOST_OBJECT_SHIM` 的本地实现，**不走 `__hostJSON`**）⇒ 不灌 ⇒ 恒空
        //   ⇒ 站方的**解锁态读不到** ⇒ `nhAuth()` 恒 false ⇒ 详情字段全空
        //   ⇒ ⇒ **沙盒后端 ≠ 真机后端**（JSC 后端是活的 `currentHostObjects`）⭐⭐⭐⭐⭐
        //
        // ⚠️ 这与老引擎侧「把 `__variables` 塞进 source」是**同一件事的两面**
        //   ⇒ 两边必须灌**同一份** ⇒ 对拍才公平 ⭐⭐⭐
        if let node = js as? NodeJSExecutor {
            js.setHostState([
                "source": [
                    "url": src.bookSourceUrl,
                    "name": src.bookSourceName,
                    "vars": ["nhAuthed": "TESTHASH"],
                ],
            ])
        }

        var book = Book()
        book.bookUrl = "https://moyue.app/legado/detail?url=NzEzODI0OTMxODkwOTA4NjcyNw%40%E7%95%AA%E8%8C%84"
        let info = try engine.bookInfo(book)

        print("=== 🟰 Swift 引擎 · 详情环探针 ===")
        print("探针 :", info.wordCount)
        print("name :", info.name)
        print("author:", info.author)
        print("intro :", info.intro.count, "字")
        print("kind  :", info.kind, "| lastChapter:", info.lastChapter)
        print("tocUrl:", String(info.tocUrl).prefix(120))
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
        // ⭐⭐⭐⭐⭐ **书籍变量必须灌进【宿主状态快照】**（2026-11-18）
        //   ⇒ Node 后端的 `source.get(k)` 读的是宿主状态里的 `source.vars`
        //   ⇒ 不灌 ⇒ 恒空 ⇒ `nhAuth()` 恒 false ⇒ 详情字段全空（**假绿的坑**）⭐⭐⭐
        //   ⇒ 与老引擎侧「把 `__variables` 塞进 source」是同一件事的两面
        js.setHostState([
            "source": [
                "url": src.bookSourceUrl,
                "name": src.bookSourceName,
                "vars": ["nhAuthed": "TESTHASH"],
            ],
        ])

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
        // ⭐⭐⭐⭐⭐ **绝对断言：两边【不能都空】**（2026-11-18）
        //
        // ⚠️ **为什么必须有**：「差集 = 0」有两种含义 —— **等价** / **两边都错**
        //   ⇒ 详情环曾经两边都空（差集 0）⇒ 差点被当成「两套实现等价」⭐⭐⭐
        //   ⇒ ⇒ 差集只**报告**，另配一条「不能都空」的绝对断言 ⭐⭐⭐
        XCTAssertFalse(exp[0].isEmpty, "⭐ **老引擎基准必须是「有值」**（基准空 ⇒ 对拍没有意义）")
        XCTAssertFalse(got[0].isEmpty, "⭐ **Swift 引擎必须能取到书名**（两边都空 ⇒ 共同缺口，不是等价）")
        XCTAssertFalse(got[1].isEmpty, "⭐ **Swift 引擎必须能取到作者**")
        XCTAssertFalse(got[2].isEmpty, "⭐ **Swift 引擎必须能取到简介**")
        // 差集（只报告，不因「老引擎可能对」而硬断言每一项）
        XCTAssertEqual(got[0], exp[0], "差集：Swift 引擎与老引擎的书名不一致")
        XCTAssertEqual(got[1], exp[1], "差集：Swift 引擎与老引擎的作者不一致")
        XCTAssertEqual(got[2], exp[2], "差集：Swift 引擎与老引擎的简介不一致")
    }
}
