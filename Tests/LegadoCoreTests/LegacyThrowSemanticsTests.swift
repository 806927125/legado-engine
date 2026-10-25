import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **「宿主没实现 ⇒ 抛不抛 TypeError」的门禁**（2026-10-25 真机实证）
///
/// **事故**：`java.longToast is not a function` ⇒ **站方 JS 第一句就炸** ⇒ 整条规则死定
/// ⇒ 真机测书源：🍅大灰狼的「发现功能」直接挂（build247）⭐⭐⭐
///
/// **根因**：契约里 `longToast` **早就登记了**，但**宿主没实现**
/// ⇒ 包装函数 `if (__qrNotImplemented) throw new TypeError(...)` ⇒ 炸 ⭐
///
/// ⭐⭐⭐ **关键认知（这次最大的收获）**：
///   「抛不抛」**不能一刀切**，要由「**老引擎上存不存在**」决定：
///   · 老引擎上**压根没这个方法** ⇒ 站方 `try/catch` 探测平台 ⇒ **必须抛**（抛了站方才走对分支）⭐
///   · 老引擎上**有**这个方法（宿主 op 缺失 ⇒ `nativeCall` 只 resolve `{ok:false}` ⇒ **不抛**）
///     ⇒ 新引擎也**不许抛** ⇒ 否则站方脚本直接死 = **回归** ⭐⭐⭐
///
/// ⇒ 名单 = 「老引擎上调用**不抛异常**」的方法 ⇒ **实测**得出（`tools/probe_legacy_java_nothrow.js`）
final class LegacyThrowSemanticsTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadNoThrowList() throws -> [String] {
        let url = repoRoot().appendingPathComponent("conformance/fixtures/legacy-java-nothrow.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["noThrow"] as? [String])
    }

    // MARK: - ① 名单与源码不许漂移

    func testLegacyPresentKeysMatchFixture() throws {
        let list = try loadNoThrowList()
        let expected = Set(list.map { "java.\($0)" })
        XCTAssertEqual(JSHostAPI.legacyPresentKeys, expected,
                       "legacyPresentKeys 与 `legacy-java-nothrow.json` 不一致 ⇒ "
                       + "重新跑 tools/probe_legacy_java_nothrow.js + tools/gen_legacy_nothrow.py ⭐")
    }

    // MARK: - ② 名单内的 API **必须**在契约里（否则包装函数不生成 ⇒ 站方 TypeError）

    func testEveryLegacyPresentAPIIsInContract() throws {
        let list = try loadNoThrowList()
        let missing = list.filter { JSHostAPI.index["java.\($0)"] == nil }
        XCTAssertTrue(missing.isEmpty,
                      """
                      这些 API **老引擎上有**（调用不抛）但**契约没登记** ⇒
                      JS 侧**不生成包装函数** ⇒ 站方 `java.xxx()` 报 TypeError ⇒ 站方 JS 直接死 ⭐⭐⭐
                      补进契约：\(missing)
                      """)
    }

    // MARK: - ③ ⭐⭐⭐ **行为门禁**：名单内的**不许抛**、名单外的**要抛**

    func testWrapperThrowsOnlyForAPIsAbsentInLegacyEngine() throws {
        let wrappers = JSScopeBuilder.hostWrappers()
        XCTAssertGreaterThan(wrappers.count, 20, "包装函数太少 ⇒ 路径没走到")

        func wrapper(of key: String) -> String? {
            let obj = key.split(separator: ".").first.map(String.init) ?? ""
            let name = key.split(separator: ".").dropFirst().joined(separator: ".")
            return wrappers.first { $0.contains("\(obj).\(name) = function") }
        }

        // ① 名单内的 ⇒ **不抛**（老引擎上不抛 ⇒ 新引擎也不许抛）
        for key in JSHostAPI.legacyPresentKeys.sorted() {
            guard let w = wrapper(of: key) else { continue }   // 不在契约里 ⇒ 另有一条门禁在查
            XCTAssertFalse(w.contains("throw new TypeError"),
                           """
                           \(key) 在**老引擎上调用不抛异常** ⇒ 新引擎也**不许抛** ⭐⭐⭐
                           （抛了 ⇒ 站方 JS 第一句就炸 ⇒ 整条规则死定）
                           """)
        }

        // ② 名单外的（且**老引擎上确实没有**）⇒ **要抛**（站方 try/catch 探测平台 ⇒ 抛了才走对分支）
        let legacyPresent = try loadNoThrowList().map { "java.\($0)" }
        let legacyFile = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: repoRoot().appendingPathComponent("conformance/fixtures/legacy-host-api.json"))) as? [String: Any])
        let legacyAll = Set(((legacyFile["java"] as? [String]) ?? []).map { "java.\($0)" })
        for e in JSHostAPI.all where e.object == "java" && e.kind == .method {
            // 老引擎 java 对象上**压根没有**它 ⇒ 新引擎必须抛
            guard !legacyAll.contains(e.key) else { continue }
            guard let w = wrapper(of: e.key) else { continue }
            XCTAssertTrue(w.contains("throw new TypeError"),
                          """
                          \(e.key) 在**老引擎上压根不存在** ⇒ 站方 `try/catch` 探测平台 ⇒
                          新引擎**必须抛 TypeError**（抛了站方才走对分支）⭐
                          （以前这里返回 undefined 不抛 ⇒ 站方以为「有这个能力」⇒ 走错分支）
                          """)
        }
    }

    // MARK: - ④ 站方真在用的 API ⇒ 必须**在契约里**（已有门禁的加强：含 noThrow 名单）

    func testStationUsedAPIsAreAllInContract() throws {
        let url = repoRoot().appendingPathComponent("conformance/fixtures/js-api-usage.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let usage = try XCTUnwrap(root["methods"] as? [String])
        let missing = usage.filter { JSHostAPI.index[$0] == nil }
        XCTAssertTrue(missing.isEmpty,
                      "站方真在用、但契约没登记 ⇒ 站方调用报 undefined is not a function ⇒ 静默失效：\(missing)")
    }
}
