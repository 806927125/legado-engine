import Foundation
import XCTest
@testable import LegadoCore

#if canImport(JavaScriptCore)
import JavaScriptCore

/// ⭐⭐ **发现页分类的 JS 形态门禁**（macOS CI 跑）
///
/// 活体验证暴露的两个缺口，**Linux 沙盒验不了**（没有 JavaScriptCore）：
/// ① `exploreUrl` 本身是 JS（`@js:` / `<js>…</js>`）
/// ② 分类项的 url 是 `@js:` 脚本 ⇒ 要跑 JS 才拿得到真实 URL
///
/// ⇒ 这里用**构造的假源 + 假 JS** 验（不需要网络）⭐
final class JSExploreKindsTests: XCTestCase {

    final class FakeAPI: JSHostAPIProvider, @unchecked Sendable {
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
            .string("host:" + method)
        }
    }

    private func makeEngine(exploreUrl: String) throws -> SourceEngine {
        let json = """
        { "bookSourceName": "JS分类源", "bookSourceUrl": "https://x.example",
          "exploreUrl": \(Self.jsLiteral(exploreUrl)) }
        """
        let src = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        return SourceEngine(source: src, fetcher: PageFetcher(transport: T()), js: JSCExecutor(api: FakeAPI()))
    }

    private static func jsLiteral(_ code: String) -> String {
        // ⚠️⚠️⚠️ 2026-10-24：**必须返回【带引号的 JSON 文本】**
        //   ⇒ 以前返回的是**解码后的原文** ⇒ 嵌进 JSON 模板 ⇒ **不是合法 JSON** ⇒ 解码必炸
        //   ⇒ 而且 macOS/新 Foundation 上 `as! [String]` 还会先崩 ⇒ **这些用例从没通过过** ⭐
        // ⇒ 正确做法：把**单个字符串**序列化成 JSON 文本（自带引号 + 转义）⇒ 直接嵌进模板
        // ⚠️⚠️ **必须用 JSONEncoder**（不是 JSONSerialization.data(withJSONObject:)）
        //   ⇒ **macOS 上 `data(withJSONObject:)` 不接受 Swift String**（要 NSString）
        //   ⇒ Linux 能过、macOS 直接抛 ⇒ 又一个「沙盒过了真机炸」的坑 ⭐
        let data = try! JSONEncoder().encode(code)
        return String(data: data, encoding: .utf8)!
    }

    final class T: HTTPTransport, @unchecked Sendable {
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data(), finalURL: request.url)
        }
    }

    // MARK: - ① `exploreUrl` 是 `@js:` ⇒ 返回 JSON 数组

    func testExploreUrlAsJSReturningArray() throws {
        let engine = try makeEngine(exploreUrl: """
        @js: JSON.stringify([{title:'推荐',url:'/list/rec'},{title:'热门',url:'/list/hot'}])
        """)
        let r = try engine.exploreKinds()
        XCTAssertEqual(r.kinds.count, 2, "⭐ JS 返回的数组要变成分类")
        XCTAssertEqual(r.kinds[0].title, "推荐")
        XCTAssertEqual(r.kinds[0].url, "https://x.example/list/rec", "相对 URL 要绝对化")
    }

    // MARK: - ② `exploreUrl` 是 `<js>` 块 ⇒ 返回纯文本 `标题::URL`

    func testExploreUrlAsJSBlockReturningPlainText() throws {
        let engine = try makeEngine(exploreUrl: """
        <js>JSON.stringify('玄幻::/type/xh&&仙侠::/type/xx')</js>
        """)
        let r = try engine.exploreKinds()
        XCTAssertEqual(r.kinds.count, 2, "⭐ 纯文本形态（&& 分隔）也要认")
        XCTAssertEqual(r.kinds[0].title, "玄幻")
        XCTAssertEqual(r.kinds[1].title, "仙侠")
    }

    // MARK: - ③ 分类项的 url 是 `@js:` ⇒ 跑 JS 得真实 URL ⭐⭐

    func testCategoryURLAsJSIsResolved() throws {
        let engine = try makeEngine(exploreUrl: """
        @js: JSON.stringify([{title:'推荐',url:"@js: 'https://real.example/list?page=1'"}])
        """)
        let r = try engine.exploreKinds()
        XCTAssertEqual(r.kinds.count, 1)
        // ⭐⭐ **分类 URL 里的 @js: 被求值成真实 URL**
        XCTAssertEqual(r.kinds[0].url, "https://real.example/list?page=1",
                       "⭐⭐ 分类项的 @js: URL 要跑 JS 求值")
        XCTAssertFalse(r.kinds[0].url.contains("@js:"), "⭐ @js: 前缀不该残留")
    }

    // MARK: - ④ `@js:` 里不做 `{{}}` 插值（Legado 语义）

    /// ⚠️⚠️ **`{{...}}` 是 JS 的展开语法** ⇒ 插值会吃成空串 ⇒ **整个 JS 语法坏掉**
    func testJSKeepsDoubleBracesIntact() throws {
        let engine = try makeEngine(exploreUrl: """
        @js: JSON.stringify([{title:'A'+'{{x}}',url:'/a'}])
        """)
        let r = try engine.exploreKinds()
        // ⭐ 站方 JS 里的 {{x}} 必须**原样保留**（不被插值吃成空串）
        XCTAssertEqual(r.kinds.first?.title, "A{{x}}",
                       "⭐ @js: 里的 {{}} 必须原样保留（否则 JS 语法坏掉）")
    }
}
#endif
