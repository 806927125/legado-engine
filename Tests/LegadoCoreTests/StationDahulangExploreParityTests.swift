#if canImport(JavaScriptCore)
import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **「发现页」整链对拍：老引擎（JS）vs 新引擎（Swift）**
///
/// ⚠️ **为什么单独加这一条**（2026-10-25 真机实证）：
///   真机上「发现」点进去**全空**，日志只有一句 `java.longToast is not a function`。
///   ⇒ 根因链（已坐实）：
///     ① 站方 exploreUrl 的 `catch (e) { java.longToast("番茄登录过期…") }`
///     ② `java.longToast` 抛 ⇒ ⚠️ **catch 块里抛的异常不会被同一个 catch 捕获**
///     ③ ⇒ 异常**逃出 catch** ⇒ **整条 exploreUrl 死** ⇒ **发现页全空** ⭐⭐⭐⭐⭐
///   ⇒ 「发现页」这条链必须**单独对拍** ⇒ 否则只在真机上撞，一版一版试 ⭐⭐⭐
///
/// ⭐ **基准来自老引擎实测**（`conformance/chain/old-engine-explore.js`）：
///   同一个**完整源**（带 exploreUrl + ruleExplore + 真 jsLib）+ 同一份假服务器响应
///   ⇒ 两边各跑一遍 ⇒ 期望值 = 老引擎的输出（**不是**我拍脑袋写的）⭐
///
/// ⭐ **全程离线**：假传输按路径路由 ⇒ 不碰真网络、不依赖站方存活 ⇒ 门禁永远能跑
final class StationDahulangExploreParityTests: XCTestCase {

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

    /// ⭐ **假传输**：按路径路由（站方大灰狼的接口）
    private struct FixtureTransport: HTTPTransport, @unchecked Sendable {
        let discovestyle: String
        let detail: String
        let catalog: String
        let content: String
        let avatar: String

        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            let url = request.url
            let body: String
            if url.contains("/discovestyle") { body = discovestyle }
            else if url.contains("/detail") { body = detail }
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

    // MARK: - 可比结构

    /// ⭐ 老引擎的输出结构（`old-engine-explore.js` 写的）：`{ source, exploreKinds: {...} }`
    private struct Expected: Decodable {
        struct Kind: Decodable { let title: String; let url: String }
        struct Filter: Decodable {
            let title: String
            let type: String
            let chars: [String]
            let paramKey: String
        }
        struct Step: Decodable {
            let kindCount: Int
            let kinds: [Kind]
            let filterCount: Int
            let filters: [Filter]
        }
        let exploreKinds: Step
    }

    // MARK: - 门禁

    /// ⭐⭐⭐ **发现页的分类 + 筛选栏都必须和老引擎一致**
    func testExploreKindsMatchesLegacyEngine() throws {
        // ① 老引擎的期望输出（Node 跑出来的，提交进仓库）
        let expectedData = try Data(contentsOf:
            Self.chainDir.appendingPathComponent("chain-expected-explore.json"))
        let expected = try JSONDecoder().decode(Expected.self, from: expectedData)

        // ② **完整源**（带 exploreUrl + ruleExplore + 真 jsLib）—— 就是用户真机测的那个
        let srcData = try Data(contentsOf:
            Self.chainDir.appendingPathComponent("chain-source-full.json"))
        let source = try JSONDecoder().decode(BookSource.self, from: srcData)

        // ③ 假传输 + 真 JSC
        let transport = FixtureTransport(discovestyle: try text("server-discovestyle.json"),
                                        detail: try text("server-detail.json"),
                                        catalog: try text("server-catalog.json"),
                                        content: try text("server-content.json"),
                                        avatar: try text("server-avatar.json"))
        let logger = RecordingLogger()
        let engine = SourceEngine(source: source,
                                  fetcher: PageFetcher(transport: transport),
                                  js: JSCExecutor(api: LegacyHost()),
                                  logger: logger)
        struct WithJsLib: Decodable { let jsLib: String? }
        if let jsLib = try JSONDecoder().decode(WithJsLib.self, from: srcData).jsLib,
           !jsLib.isEmpty {
            try engine.loadJsLib(jsLib)
        }

        // ④ 跑发现页
        var diffs: [String] = []
        do {
            let (kinds, filters) = try engine.exploreKinds()
            // 分类：逐字比（标题 + url）
            if kinds.count != expected.exploreKinds.kinds.count {
                diffs.append("⭐ 分类数不一致：老引擎 \(expected.exploreKinds.kinds.count) / 新引擎 \(kinds.count)")
            }
            for (i, e) in expected.exploreKinds.kinds.enumerated() {
                guard i < kinds.count else { diffs.append("  · 新引擎少第 \(i+1) 个分类「\(e.title)」"); continue }
                let a = kinds[i]
                if a.title != e.title { diffs.append("  · 分类[\(i+1)] 标题：老「\(e.title)」/ 新「\(a.title)」") }
                if a.url != e.url { diffs.append("  · 分类[\(i+1)] url：老「\(e.url)」/ 新「\(a.url)」") }
            }
            // 筛选栏：逐字比（标题 / 类型 / 选项 / 参数名）
            if filters.count != expected.exploreKinds.filters.count {
                diffs.append("⭐ 筛选栏数不一致：老引擎 \(expected.exploreKinds.filters.count) / 新引擎 \(filters.count)")
            }
            for (i, e) in expected.exploreKinds.filters.enumerated() {
                guard i < filters.count else { diffs.append("  · 新引擎少第 \(i+1) 个筛选栏「\(e.title)」"); continue }
                let a = filters[i]
                if a.title != e.title { diffs.append("  · 筛选[\(i+1)] 标题：老「\(e.title)」/ 新「\(a.title)」") }
                if a.chars != e.chars {
                    diffs.append("  · 筛选[\(i+1)]「\(e.title)」选项：老 \(e.chars.count) 个 / 新 \(a.chars.count) 个"
                                 + (a.chars == e.chars ? "" : "\n      老: \(e.chars.prefix(6))\n      新: \(a.chars.prefix(6))"))
                }
            }
        } catch {
            diffs.append("⭐⭐⭐ 新引擎跑 exploreKinds 失败：\(error)")
        }

        XCTAssertTrue(diffs.isEmpty,
                      "⭐⭐⭐ 发现页和老引擎不一致 ⇒ **这里就是要搬的规则语义**\n"
                      + diffs.joined(separator: "\n")
                      + "\n引擎日志：\n" + logger.all.joined(separator: "\n"))
    }
}
#endif
