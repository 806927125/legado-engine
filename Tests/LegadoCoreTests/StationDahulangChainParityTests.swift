#if canImport(JavaScriptCore)
import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **整条链对拍：老引擎（JS）vs 新引擎（Swift）—— 详情 → 目录 → 正文**
///
/// ⚠️ 为什么要有它：
///   规则级 fixture 对拍（`conformance/`）验的是「零件」；
///   而「**老引擎有的、新引擎没有的语义**」往往藏在**整条链**里
///   （🍅大灰狼的 `init` / `chapterList` / `content` 三个规则**同一套写法**：
///   `JSON.parse(java.hexDecodeToString(result))` ⇒ 站方自己解载荷）⭐
///   ⇒ 一处错就是**详情/目录/正文三条链一起空** ⇒ 只验详情会漏 ⭐⭐⭐
///
/// ⭐ **基准来自老引擎实测**（`conformance/chain/old-engine-chain.js`）：
///   同一个源 + 同一套真规则 + **同一份假服务器响应** ⇒ 两边各跑一遍
///   ⇒ 期望值 = 老引擎的输出（**不是**我拍脑袋写的）⭐
///
/// ⭐ **全程离线**：假传输按路径路由 ⇒ 不碰真网络、不依赖站方存活 ⇒ 门禁永远能跑
final class StationDahulangChainParityTests: XCTestCase {

    // MARK: - fixture

    private static var chainDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/chain")
    }

    private func text(_ name: String) throws -> String {
        let url = Self.chainDir.appendingPathComponent(name)
        return try String(data: Data(contentsOf: url), encoding: .utf8) ?? ""
    }

    /// ⭐ **假传输**：按路径路由（站方大灰狼的四个接口）
    private struct FixtureTransport: HTTPTransport, @unchecked Sendable {
        let detail: String
        let catalog: String
        let content: String
        let avatar: String

        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            let url = request.url
            let body: String
            if url.contains("/detail") { body = detail }
            else if url.contains("/catalog") { body = catalog }
            else if url.contains("/content") { body = content }
            else if url.contains("/get_avatar") { body = avatar }
            else {
                throw SourceError.requestFailed(url, "假服务器没有这条路由")
            }
            return HTTPResponse(statusCode: 200,
                                headers: ["Content-Type": "application/json"],
                                body: Data(body.utf8), finalURL: url)
        }
    }

    // MARK: - 门禁

    /// ⭐⭐⭐ **详情 / 目录 / 正文 三步都必须和老引擎一致**
    func testChainMatchesLegacyEngine() throws {
        // ① 老引擎的期望输出（Node 跑出来的，提交进仓库）
        let expectedData = try Data(contentsOf:
            Self.chainDir.appendingPathComponent("chain-expected.json"))
        let expected = try JSONDecoder().decode(ChainOutput.self, from: expectedData)

        // ② 源（真规则 + 真 jsLib）
        let srcData = try Data(contentsOf:
            Self.chainDir.appendingPathComponent("chain-source.json"))
        let source = try JSONDecoder().decode(BookSource.self, from: srcData)
        let bookUrl = try text("chain-bookurl.txt").trimmingCharacters(in: .whitespacesAndNewlines)

        // ③ 假传输 + 真 JSC
        let transport = FixtureTransport(detail: try text("server-detail.json"),
                                        catalog: try text("server-catalog.json"),
                                        content: try text("server-content.json"),
                                        avatar: try text("server-avatar.json"))
        let logger = RecordingLogger()
        let engine = SourceEngine(source: source,
                                  fetcher: PageFetcher(transport: transport),
                                  js: JSCExecutor(api: LegacyHost()),
                                  logger: logger)

        // ④ 详情
        var book = Book()
        book.bookUrl = bookUrl
        book.name = "测试书名"
        let info = try engine.bookInfo(book)

        // ⑤ 目录（用详情算出来的 tocUrl ⇒ 走的是同一条真路径）
        let chapters = (try? engine.toc(info, book: book)) ?? []

        // ⑥ 正文（第一册非卷章节）—— ⭐ **不许在这里 bail**（bail 了就看不到别的差异）
        let ch = chapters.first { !$0.isVolume && !$0.url.isEmpty }
        var content = ""
        if let ch {
            content = (try? engine.content(ch, book: book)) ?? ""
        }

        // ⑦ 逐项比对（**指名道姓**，不许只说「不一致」）
        let actual = ChainOutput(
            bookInfo: ChainBookInfo(name: info.name, author: info.author,
                                    introLen: info.intro.count,
                                    tocUrl: info.tocUrl, coverUrl: info.coverUrl),
            toc: ChainToc(count: chapters.count,
                          chapters: chapters.map {
                              ChainChapter(title: $0.name, url: $0.url, isVolume: $0.isVolume)
                          }),
            content: ChainContent(len: content.count, head: String(content.prefix(60)))
        )
        var diff = Self.diff(expected: expected, actual: actual)
        if ch == nil {
            diff.insert("  · ⭐ **目录里没有可用章节**（章节数=\(chapters.count)）", at: 0)
        }
        XCTAssertTrue(diff.isEmpty,
                      "⭐⭐⭐ 整条链和老引擎不一致 ⇒ **这里就是要搬的规则语义**\n"
                      + diff.joined(separator: "\n")
                      + "\n引擎日志：\n" + logger.all.joined(separator: "\n"))
    }

    /// ⭐ **差异清单**（哪一项不一样，写清楚）
    private static func diff(expected: ChainOutput, actual: ChainOutput) -> [String] {
        var out: [String] = []
        func cmp(_ label: String, _ e: String, _ a: String) {
            if e != a { out.append("  · \(label)：老引擎=\(e) ｜ 新引擎=\(a)") }
        }
        cmp("详情.书名", expected.bookInfo.name, actual.bookInfo.name)
        cmp("详情.作者", expected.bookInfo.author, actual.bookInfo.author)
        cmp("详情.简介长度", String(expected.bookInfo.introLen), String(actual.bookInfo.introLen))
        cmp("详情.tocUrl", expected.bookInfo.tocUrl, actual.bookInfo.tocUrl)
        cmp("详情.封面", expected.bookInfo.coverUrl, actual.bookInfo.coverUrl)
        cmp("目录.章数", String(expected.toc.count), String(actual.toc.count))
        let n = max(expected.toc.chapters.count, actual.toc.chapters.count)
        for i in 0..<n {
            let e = expected.toc.chapters.indices.contains(i) ? expected.toc.chapters[i] : nil
            let a = actual.toc.chapters.indices.contains(i) ? actual.toc.chapters[i] : nil
            cmp("目录[\(i)].章名", e?.title ?? "（无）", a?.title ?? "（无）")
            cmp("目录[\(i)].URL", e?.url ?? "（无）", a?.url ?? "（无）")
            cmp("目录[\(i)].是否卷", String(e?.isVolume ?? false), String(a?.isVolume ?? false))
        }
        cmp("正文.长度", String(expected.content.len), String(actual.content.len))
        cmp("正文.开头", expected.content.head, actual.content.head)
        return out
    }

    // MARK: - 输出形状

    struct ChainOutput: Codable {
        var bookInfo: ChainBookInfo
        var toc: ChainToc
        var content: ChainContent
    }
    struct ChainBookInfo: Codable {
        var name: String
        var author: String
        var introLen: Int
        var tocUrl: String
        var coverUrl: String
    }
    struct ChainToc: Codable {
        var count: Int
        var chapters: [ChainChapter]
    }
    struct ChainChapter: Codable {
        var title: String
        var url: String
        var isVolume: Bool
    }
    struct ChainContent: Codable {
        var len: Int
        var head: String
    }

    // MARK: - 宿主（与老引擎那侧对齐的能力集）

    /// ⭐ 宿主 API：**只提供这条链用到的**（source / cookie / java 几个）
    /// ⇒ 两边拿到的能力一致 ⇒ 差异才只来自规则语义 ⭐
    private final class LegacyHost: JSHostAPIProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var vars = ""
        func hostObject(named name: String) -> HostObject? {
            switch name {
            case "source":
                return HostObject(name: "source", methods: [
                    "getVariable": { [self] _ in .string(readVars()) },
                    "setVariable": { [self] args in
                        writeVars(args.first?.scalarString ?? ""); return .string("")
                    },
                    "getLoginInfoMap": { _ in .object([:]) },
                    "header": { _ in .string("") },
                ])
            case "cookie":
                return HostObject(name: "cookie", methods: [
                    "getCookie": { _ in .string("") },
                    "setCookie": { _ in .string("") },
                    "removeCookie": { _ in .string("") },
                ])
            case "book":
                return HostObject(name: "book", methods: [
                    "getVariable": { _ in .string("") },
                ])
            default: return nil
            }
        }

        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
            switch method {
            case "deviceID": return .string("GT-DEVICE")
            case "androidId": return .string("GT-ANDROID")
            case "getWebViewUA": return .string("UA/1.0")
            default: return .string("")
            }
        }

        private func readVars() -> String { lock.lock(); defer { lock.unlock() }; return vars }
        private func writeVars(_ v: String) { lock.lock(); vars = v; lock.unlock() }
    }
}
#endif
