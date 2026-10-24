import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **宿主通道的「完整性」门禁** —— 沙盒可跑（不依赖 JSC）
///
/// ⚠️⚠️ **2026-10-24 真机栽的**：
///   症状 = 发现页冒出「**未分组**」假分类 ⇒ 整本书打不开。
///   根因 = 引擎的 `sourceObject`（站方 `source.*` 的载体）**只在 bookInfo / toc / content
///   里才被创建** ⇒ **发现页 + jsLib 加载阶段它是 nil**
///   ⇒ 宿主拿到的 `source` 是空对象 ⇒ 站方 `source.setVariable(...)` = **undefined**
///   ⇒ 站方 JS **抛异常** ⇒ 走兜底分支 ⇒ 假分类 ⭐
///
/// ⇒ 这条门禁钉死：**引擎刚建好，`source` 宿主通道就必须已经能用**
///   （⇒ 宿主只要拿到引擎就有完整的 `source` ⇒ 不用等第一次 bookInfo）
///
/// ⭐ **为什么这条能放沙盒**：它只验「宿主对象建好了、方法是活的」⇒ 纯 Swift ⇒ Linux 也能跑
///   （**别**把这种门禁塞进 `#if canImport(JavaScriptCore)` ⇒ 沙盒里就等于没有）
final class SourceHostChannelTests: XCTestCase {

    private func makeSource() throws -> BookSource {
        let data = Data(#"{"bookSourceName":"宿主通道门禁源","bookSourceUrl":"https://x.example.com"}"#.utf8)
        return try JSONDecoder().decode(BookSource.self, from: data)
    }

    private func makeEngine() throws -> SourceEngine {
        final class T: HTTPTransport, @unchecked Sendable {
            func send(_ request: HTTPRequest) throws -> HTTPResponse {
                HTTPResponse(statusCode: 200, headers: [:], body: Data(), finalURL: request.url)
            }
        }
        return SourceEngine(source: try makeSource(),
                            fetcher: PageFetcher(transport: T()))
    }

    // MARK: - ①⭐⭐ 引擎一建好，`source` 就必须已经在了

    func testSourceObjectExistsRightAfterInit() throws {
        let engine = try makeEngine()
        XCTAssertNotNil(engine.sourceObject,
                        "⭐⭐ 宿主通道必须在【第一次求值】之前就完整 ⇒ 发现页/jsLib 阶段也要有")
    }

    // MARK: - ②⭐⭐ 站方最常用的两个方法必须是活的

    func testSourceGetAndSetVariableWork() throws {
        let engine = try makeEngine()
        let obj = try XCTUnwrap(engine.sourceObject)
        // 写
        _ = obj.call("setVariable", [.string(#"{"tab":"小说","server":"https://v5.langge.uk"}"#)])
        // 读 ⇒ 必须能读回刚写的（站方 `source.getVariable()` 拿它拼请求）
        let got = obj.call("getVariable", [])
        let text = got?.scalarString ?? ""
        XCTAssertTrue(text.contains("tab"), "⭐⭐ `source.getVariable()` 必须读得到 ⇒ 实际：\(text)")
        XCTAssertTrue(text.contains("v5.langge.uk"), "⭐⭐ 变量内容要原样 ⇒ 实际：\(text)")
    }

    // MARK: - ③ 单项变量（站方 127 处用法）

    func testSourceSingleItemVariableWork() throws {
        let engine = try makeEngine()
        let obj = try XCTUnwrap(engine.sourceObject)
        _ = obj.call("put", [.string("book_id"), .string("7412345678901234567")])
        let got = obj.call("get", [.string("book_id")])?.scalarString ?? ""
        XCTAssertEqual(got, "7412345678901234567", "⭐ 单项变量要能写能读")
    }

    // MARK: - ④⭐ `loginInfo` 也要能读（站方 `source.getLoginInfoMap()`）

    func testSourceLoginInfoMapIsAvailable() throws {
        let engine = try makeEngine()
        let obj = try XCTUnwrap(engine.sourceObject)
        XCTAssertNotNil(obj.call("getLoginInfoMap", []),
                        "⭐ `source.getLoginInfoMap()` 必须存在（站方登录态要用）")
    }
}
