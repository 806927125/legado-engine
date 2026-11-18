import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **整链对拍台（第一环：exploreKinds）** —— Swift 引擎 vs 老 WebView 引擎
///
/// ⭐ 为什么要它：
///   轻阅有两套引擎（自研 Swift 引擎 / 老 WebView 引擎）⇒ **同一份书源在两边可能给出不同结果**
///   ⇒ 而「新引擎比老引擎强」这个说法**从来没有被逐 op 证明过**⭐⭐⭐
///   ⇒ 本测试用**同输入（同一份真实响应 fixture）**跑两套引擎 ⇒
///     **差集 = 纯解析/求值差异**（不含网络波动、不含站方变动）⭐⭐⭐⭐⭐
///
/// ⭐ 三份 fixture 的来历（都可复现）：
///   · `novelhub-aggregate-source.json` = 轻阅仓库里的 NovelHub 聚合源（站方真实源）
///   · `novelhub-menu.json`             = **真实网络录下**的站方分类接口响应
///   · `novelhub-kinds-oracle.json`     = **老 WebView 引擎**（jsdom + 同一份 fixture）跑出来的结果
///     ⇒ 它就是「基准/事实标准」（老引擎是 Legado 语义最全的那个）⭐⭐⭐
///
/// ⚠️ 本测试**只报差集**（先把差集打出来给人看）⇒ **不硬断言「必须完全一致」**
///   ⇒ 因为老引擎不是栖阅（栖阅闭源）⇒ 差异里可能有一部分是「老引擎对、栖阅错」
///   ⇒ ⇒ 差集是**待查清单**，不是「错误」⭐⭐⭐（硬断言会挡住正确的差异）
final class NovelHubAggregateExploreParityTests: XCTestCase {

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("fixtures")
    }

    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixturesDir.appendingPathComponent(name))
    }

    /// ⭐⭐⭐ **手工构造**（不整体解码）：引擎的 `BookSource` 模型对整份书源 JSON 解码偏严
    ///   ⇒ 而对拍这一环**只需要** `exploreUrl`（顶层）+ `header` + 站方地址 ⭐
    private func loadSource() throws -> BookSource {
        let raw = try JSONSerialization.jsonObject(with: try load("novelhub-aggregate-source.json"))
        let obj = (raw as? [Any])?.first as? [String: Any] ?? (raw as? [String: Any] ?? [:])
        var src = BookSource(bookSourceName: obj["bookSourceName"] as? String ?? "NovelHub",
                             bookSourceUrl: obj["bookSourceUrl"] as? String ?? "")
        src.exploreUrl = obj["exploreUrl"] as? String
        src.header = obj["header"] as? String
        return src
    }

    /// ⭐ 引擎的 `BookSource` 模型**不带 jsLib**（jsLib 单独灌）⇒ 从原始 JSON 取
    private func loadJsLib() throws -> String {
        let raw = try JSONSerialization.jsonObject(with: try load("novelhub-aggregate-source.json"))
        let obj = (raw as? [Any])?.first as? [String: Any] ?? (raw as? [String: Any] ?? [:])
        return obj["jsLib"] as? String ?? ""
    }

    /// ⭐ 只认这一条路由 ⇒ 站方若要别的接口 ⇒ 立刻暴露（不静默喂错数据）⭐⭐⭐
    private struct FixtureTransport: HTTPTransport, @unchecked Sendable {
        let body: String
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            let url = request.url
            guard url.contains("/legado/explore/menu") else {
                throw SourceError.requestFailed(url, "fixture 里没有这条路由（⇒ 差集可能来自站方多打的接口）")
            }
            return HTTPResponse(statusCode: 200,
                                headers: ["Content-Type": "application/json"],
                                body: Data(body.utf8), finalURL: url)
        }
    }

    private struct OracleKind: Decodable { let title: String; let url: String }

    func testExploreKindsParityReport() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 跑不了（显式 SKIP，不许假绿）")

        let src = try loadSource()
        let fixture = try String(data: try load("novelhub-menu.json"), encoding: .utf8) ?? ""
        let oracle = try JSONDecoder().decode([OracleKind].self, from: try load("novelhub-kinds-oracle.json"))

        let js = try NodeJSExecutor()
        let engine = SourceEngine(source: src,
                                  fetcher: PageFetcher(transport: FixtureTransport(body: fixture)),
                                  js: js)
        try engine.loadJsLib(try loadJsLib())

        let got = try engine.exploreKinds()
        let gotTitles = got.kinds.map { $0.title }
        let oracleTitles = oracle.map { $0.title }

        let gotSet = Set(gotTitles)
        let oracleSet = Set(oracleTitles)
        let onlyOracle = oracleTitles.filter { !gotSet.contains($0) }   // ⭐ 老引擎有、Swift 引擎没有
        let onlyGot = gotTitles.filter { !oracleSet.contains($0) }      // ⭐ Swift 引擎有、老引擎没有

        print("=== 🟰 NovelHub 聚合源 · exploreKinds 对拍（Swift 引擎 vs 老 WebView 引擎，同一份真实 fixture）===")
        print("老引擎 kinds：\(oracleTitles.count) 个")
        print("Swift 引擎 kinds：\(gotTitles.count) 个")
        print("⭐ 只在老引擎有（Swift 引擎**缺**）：\(onlyOracle.count)")
        for t in onlyOracle.prefix(20) { print("   ⭕ 缺：\(t)") }
        print("⭐ 只在 Swift 引擎有（老引擎**缺**）：\(onlyGot.count)")
        for t in onlyGot.prefix(20) { print("   ➕ 多：\(t)") }

        // ⭐⭐⭐ 硬断言只钉「不能两边都空」⇒ 防止对拍台自己坏了（假绿）
        XCTAssertFalse(gotTitles.isEmpty, "Swift 引擎连一个分类都没出 ⇒ 对拍台/引擎有问题")
        XCTAssertFalse(oracleTitles.isEmpty, "oracle 是空的 ⇒ fixture 录错了")
    }
}
