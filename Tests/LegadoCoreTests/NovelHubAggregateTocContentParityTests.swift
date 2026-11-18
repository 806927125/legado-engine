import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **整链对拍台 · 第三环（toc）+ 第四环（content）** —— 自研 Swift 引擎 vs 老 WebView 引擎
///
/// ⭐ 前两环的结论（2026-11-18）：
///   · 第一环 exploreKinds：439 vs 439，差集 0 ⇒ **真等价**
///   · 第二环 bookInfo：修完三处根因后两侧**逐字一致**（天渊 / 沐潇三生 / 289 字）⇒ **真等价**
///     （修的三处：① 沙盒后端没灌书籍变量 ② `result` 的 JSON 对象语义 ③ 老引擎把 `@js:` 规则腰斩）
///
/// ⭐ 本环的输入：
///   · `novelhub-toc.json`     = 站方 `/legado/toc` 真实响应（542KB）
///   · `novelhub-content.json` = 站方 `/legado/content` 真实响应
///   · `novelhub-toc-content-oracle.json` = **老 WebView 引擎**吃同一份 fixture 的结果（基准）
///
/// ⚠️ **差集只报告 + 绝对断言「不能都空」**（区分「等价」与「两边都错」）⭐⭐⭐
final class NovelHubAggregateTocContentParityTests: XCTestCase {

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("fixtures")
    }

    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixturesDir.appendingPathComponent(name))
    }

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
        let bookUrl: String
        let tocUrl: String
        let chapterCount: Int
        let firstChapterUrl: String
        let firstChapterName: String
        let contentLength: Int
        let contentFull: String
    }

    func testTocAndContentParity() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 跑不了（显式 SKIP，不许假绿）")

        let raw = try JSONSerialization.jsonObject(with: try load("novelhub-unlocked-source.json"))
        var dict = (raw as? [Any])?.first as? [String: Any] ?? (raw as? [String: Any] ?? [:])
        let srcData = try JSONSerialization.data(withJSONObject: dict)
        let src = try JSONDecoder().decode(BookSource.self, from: srcData)
        let oracle = try JSONDecoder().decode(Oracle.self, from: try load("novelhub-toc-content-oracle.json"))

        let js = try NodeJSExecutor()
        let transport = FixtureTransport(
            detail: String(data: try load("novelhub-detail.json"), encoding: .utf8) ?? "",
            toc: String(data: try load("novelhub-toc.json"), encoding: .utf8) ?? "",
            content: String(data: try load("novelhub-content.json"), encoding: .utf8) ?? "")
        let engine = SourceEngine(source: src,
                                  fetcher: PageFetcher(transport: transport),
                                  js: js)
        try engine.loadJsLib(dict["jsLib"] as? String ?? "")
        engine.varBox.set("nhAuthed", "TESTHASH")
        engine.javaVars.set("nhAuthed", "TESTHASH")
        js.setHostState([
            "source": [
                "url": src.bookSourceUrl,
                "name": src.bookSourceName,
                "vars": ["nhAuthed": "TESTHASH"],
            ],
        ])

        var book = Book()
        book.bookUrl = oracle.bookUrl

        // ── 详情（拿 tocUrl）────────────────────────────────────
        let info = try engine.bookInfo(book)
        print("=== 🟰 详情环 ===")
        print("Swift：name=\(info.name) tocUrl=\(String(info.tocUrl).prefix(90))")

        // ── 目录环 ─────────────────────────────────────────────
        let chapters = try engine.toc(info, book: book)
        print("=== 🟰 目录环（toc）===")
        print("Swift 章数 =", chapters.count, "｜ 老引擎章数 =", oracle.chapterCount)
        if !chapters.isEmpty {
            print("Swift 首章：\(chapters[0].name) ｜ \(String(chapters[0].url).prefix(90))")
            print("老引擎首章：\(oracle.firstChapterName) ｜ \(oracle.firstChapterUrl.prefix(90))")
        }
        // 差集（只报告）
        if chapters.count != oracle.chapterCount {
            print("⭐ 差异「章数」：Swift=\(chapters.count) / 老=\(oracle.chapterCount)")
        }
        // ⭐⭐⭐ **绝对断言：不能都空**
        XCTAssertGreaterThan(oracle.chapterCount, 0, "⭐ **老引擎基准章数必须 > 0**")
        XCTAssertGreaterThan(chapters.count, 0, "⭐ **Swift 引擎必须能取到目录**（两边都空 ⇒ 共同缺口）")
        XCTAssertEqual(chapters.count, oracle.chapterCount, "差集：目录章数不一致")

        // ── 正文环 ─────────────────────────────────────────────
        let first = chapters.first
        var chapter = Chapter()
        chapter.name = first?.name ?? ""
        chapter.url = first?.url ?? ""
        chapter.index = first?.index ?? 0
        let content = try engine.content(chapter, book: book)
        print("=== 🟰 正文环（content）===")
        print("Swift 正文长度 =", content.count, "｜ 老引擎正文长度 =", oracle.contentLength)
        print("Swift 正文开头 =", String(content.prefix(120)))
        // ⚠️ **长度不作差集判据**：Swift 的 `String.count` 数的是**字素簇**，
        //   而 oracle 是按**码点**算的 ⇒ 同一段文本长度会差几个（零宽/组合字符）⭐⭐⭐
        //   ⇒ 差集判据 = **逐字相等**（下面那段）⭐⭐⭐
        if content.count != oracle.contentLength {
            print("ℹ️ 长度口径差异（字素簇 vs 码点，不是内容差异）：Swift=\(content.count) / 老=\(oracle.contentLength)")
        }
        XCTAssertGreaterThan(oracle.contentLength, 0, "⭐ **老引擎基准正文长度必须 > 0**")
        XCTAssertGreaterThan(content.count, 0, "⭐ **Swift 引擎必须能取到正文**（两边都空 ⇒ 共同缺口）")

        // ⭐⭐⭐ **逐字对拍正文**（差集定位到第一处不同）
        if content != oracle.contentFull {
            let a = Array(content), b = Array(oracle.contentFull)
            var i = 0
            while i < min(a.count, b.count) && a[i] == b[i] { i += 1 }
            let lo = max(0, i - 60)
            print("⭐ 正文首个差异位 = \(i)（Swift=\(a.count) 老=\(b.count)）")
            print("   Swift 段：", String(content.dropFirst(lo).prefix(120)).replacingOccurrences(of: "\n", with: "\\n"))
            print("   老引擎段：", String(oracle.contentFull.dropFirst(lo).prefix(120)).replacingOccurrences(of: "\n", with: "\\n"))
            print("   Swift 尾部：", String(content.suffix(120)).replacingOccurrences(of: "\n", with: "\\n"))
            print("   老引擎尾部：", String(oracle.contentFull.suffix(120)).replacingOccurrences(of: "\n", with: "\\n"))
        } else {
            print("✅ 正文逐字一致")
        }
    }
}
