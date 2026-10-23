import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **性能优化的门禁**（每条都验「优化真的生效」）
///
/// 这轮的优化（都是**先量后做**，数据见 `swift run conformance --bench-e2e`）：
/// ① **DOM 缓存** —— 同一页只解析一次（实测省 ~20ms）
/// ② **正则缓存** —— `NSRegularExpression` 不用每次重新编译
/// ③ **`VarStore.apply` 快速路径** —— 规则里没有 `@put:`/`@get:` 时直接返回
/// ④ **HTTP 缓存装饰器** —— 宿主可选启用（网络才是真实场景的大头）
final class PerformanceGatesTests: XCTestCase {

    // MARK: - ① DOM 缓存

    func testDOMCacheReturnsSameNode() throws {
        let cache = DOMCache()
        XCTAssertNil(cache.node(for: "u1"))
        let doc = try SwiftSoupDocument(html: "<html><body><p>x</p></body></html>",
                                        baseURL: "https://x.example/").document
        cache.put(doc, for: "u1")
        let got = cache.node(for: "u1")
        XCTAssertNotNil(got)
        // ⭐ 必须是**同一个对象**（复用，不是重新解析）
        XCTAssertTrue(got === doc, "⭐ DOM 缓存必须复用同一个节点对象")
        XCTAssertEqual(cache.count, 1)
        cache.clear()
        XCTAssertNil(cache.node(for: "u1"))
    }

    /// ⭐ **容量上限**（LRU）
    func testDOMCacheRespectsCapacity() {
        let cache = DOMCache(capacity: 2)
        let d1 = try? SwiftSoupDocument(html: "<p>1</p>", baseURL: "").document
        let d2 = try? SwiftSoupDocument(html: "<p>2</p>", baseURL: "").document
        let d3 = try? SwiftSoupDocument(html: "<p>3</p>", baseURL: "").document
        guard let d1, let d2, let d3 else { return XCTFail("造不出 DOM") }
        cache.put(d1, for: "a"); cache.put(d2, for: "b"); cache.put(d3, for: "c")
        XCTAssertEqual(cache.count, 2, "⭐ 容量上限要生效")
        XCTAssertNil(cache.node(for: "a"), "最旧的应被淘汰")
        XCTAssertNotNil(cache.node(for: "c"))
    }

    // MARK: - ② 正则缓存

    /// ⭐⭐ **正则只编译一次**（`NSRegularExpression` 编译很贵）
    func testRegexCacheReusesCompiledRegex() {
        RegexCache.shared.clear()
        let a = RegexCache.shared.regex("^第(\\d+)章$")
        let b = RegexCache.shared.regex("^第(\\d+)章$")
        XCTAssertNotNil(a)
        // ⭐ 同一个 pattern ⇒ 同一个实例（没重新编译）
        XCTAssertTrue(a === b, "⭐ 同一 pattern 必须复用编译好的正则")
        XCTAssertEqual(RegexCache.shared.count, 1)
        // ⚠️ 非法 pattern ⇒ nil（明确失败）
        XCTAssertNil(RegexCache.shared.regex("["))
    }

    // MARK: - ③ `VarStore.apply` 快速路径

    /// ⭐ **不含 `@put:`/`@get:` 的规则 ⇒ 什么都不做**（不跑正则）
    func testVarStoreFastPathLeavesRuleUntouched() {
        var ctx = EvalContext(base: .page("<html/>"))
        let rule = "tag.a@text"
        XCTAssertEqual(VarStore.apply(rule, ctx: &ctx), rule, "⭐ 快速路径应原样返回")
        // ⚠️ 但含 `@get:` 的规则**要**处理
        ctx.vars["k"] = "V"
        XCTAssertEqual(VarStore.apply("@get:{k}", ctx: &ctx), "V")
    }

    /// ⭐ **含 `@text`（取值模式）但不含变量取值 ⇒ 仍原样返回**
    func testVarStoreFastPathDoesNotConfuseAtText() {
        var ctx = EvalContext(base: .page("<html/>"))
        XCTAssertEqual(VarStore.apply("a@text", ctx: &ctx), "a@text")
    }

    // MARK: - ④ HTTP 缓存装饰器

    final class CountingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            lock.lock(); _count += 1; lock.unlock()
            return HTTPResponse(statusCode: 200, headers: [:],
                                body: Data("body".utf8), finalURL: request.url)
        }
    }

    /// ⭐⭐ **同一 URL 两次 ⇒ 底层只请求一次**
    func testCachedTransportCachesByURL() throws {
        let inner = CountingTransport()
        let cached = CachedTransport(inner: inner, ttl: 60)
        let req = HTTPRequest(url: "https://x.example/a", method: "GET")
        _ = try cached.send(req)
        _ = try cached.send(req)
        XCTAssertEqual(inner.count, 1, "⭐ 同一 URL 不该重复请求")
        // ⚠️ 不同 URL ⇒ 各自请求
        _ = try cached.send(HTTPRequest(url: "https://x.example/b", method: "GET"))
        XCTAssertEqual(inner.count, 2)
        // ⚠️ 不同 method ⇒ 不同缓存键
        _ = try cached.send(HTTPRequest(url: "https://x.example/a", method: "POST"))
        XCTAssertEqual(inner.count, 3, "⭐ method 不同不该命中缓存")
    }

    /// ⭐ **TTL 过期 ⇒ 重新请求**
    func testCachedTransportExpires() throws {
        let inner = CountingTransport()
        let cached = CachedTransport(inner: inner, ttl: 0.05)
        let req = HTTPRequest(url: "https://x.example/a", method: "GET")
        _ = try cached.send(req)
        _ = try cached.send(req)
        XCTAssertEqual(inner.count, 1)
        Thread.sleep(forTimeInterval: 0.12)
        _ = try cached.send(req)
        XCTAssertEqual(inner.count, 2, "⭐ TTL 过期后要重新请求")
    }

    /// ⭐ **ttl = 0 ⇒ 等于不缓存**
    func testCachedTransportZeroTTLDisablesCache() throws {
        let inner = CountingTransport()
        let cached = CachedTransport(inner: inner, ttl: 0)
        let req = HTTPRequest(url: "https://x.example/a", method: "GET")
        _ = try cached.send(req)
        _ = try cached.send(req)
        XCTAssertEqual(inner.count, 2, "⭐ ttl=0 不该缓存")
    }
}

// MARK: - ⑤ ⭐⭐ AST 缓存**默认必须生效**

/// ⭐⭐⭐ **「规格/文档写了 ≠ 实际生效」的最强案例**
///
/// ⚠️ 以前 `Evaluator.init(js:cache:)` 的 `cache` **默认 nil**
///   ⇒ **AST 缓存默认根本没开** ⇒ 每次求值都重新解析（36~80 µs）
///   ⇒ 而「显式传 cache」的 bench 测出「加速 85 倍」⇒ **测的路径和生产路径不一致** ⭐
///
/// ⇒ 这条门禁钉死「**默认就要有缓存**」。
final class ASTCacheDefaultTests: XCTestCase {

    /// ⭐ **`Evaluator` 默认就带缓存** ⇒ 同一条规则解析两次 ⇒ 第二次**命中**
    func testEvaluatorHasASTCacheByDefault() throws {
        let ev = Evaluator()
        let html = "<html><body><a href='/x'>书名</a></body></html>"
        let doc = try SwiftSoupDocument(html: html, baseURL: "https://x.example/").document
        let ctx = EvalContext(base: .page(html), baseUrl: "https://x.example/", document: doc)

        _ = ev.evalOne("a@text", base: .page(html), ctx: ctx)
        _ = ev.evalOne("a@text", base: .page(html), ctx: ctx)
        _ = ev.evalOne("a@text", base: .page(html), ctx: ctx)

        let stats = ev.parser.cacheStats
        XCTAssertGreaterThan(stats.hits, 0,
                             "⭐⭐ Evaluator 默认必须带 AST 缓存（以前默认 nil ⇒ 缓存根本没开）")
        XCTAssertGreaterThan(stats.hitRate, 0.5,
                             "⭐ 同一条规则重复求值 ⇒ 命中率应 > 50%（实际 \(stats.hitRate)）")
    }

    /// ⭐ **缓存不改变行为**：命中缓存的 AST 与现算的**逐字相同**（§S-EVAL-11）
    func testCachedASTMatchesFreshAST() throws {
        let rules = ["class.book@tag.a@text", "class.booklist@tag.li@text", "$.data.bookList",
                     "//div[@class='x']/p", "tag.h1@ownText", "##(\\d+)##$1##", "a@text"]
        let cached = RuleParser(cache: RuleCache())
        let fresh = RuleParser()
        for r in rules {
            let a = cached.parse(r, isJSON: false)
            let b = fresh.parse(r, isJSON: false)
            XCTAssertEqual(String(describing: a), String(describing: b),
                           "⭐ 缓存不能改变 AST（规则 \(r)）")
        }
    }
}
