import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **真书源门禁（分类拆分）** —— 🍅大灰狼聚合
///
/// ⚠️ **为什么用真语料**：
///   2026-10-23 真机栽过 —— 发现页冒出「**未分组**」假分类 ⇒ 整本书打不开。
///   根因在**引擎**（不是站方规则的锅）：Java 兼容层没注入 / 宿主通道没先于 jsLib 注入
///   ⇒ **jsLib 整个加载失败** ⇒ 站方 JS 走兜底分支 ⇒ 分类变成假分类 ⭐
///
/// ⇒ 这条门禁用**站方 exploreUrl 的真实输出**（`dahulang-explore-result.json`
///   = Node 端到端跑真 jsLib + 真 exploreUrl 捕获的原文）⇒ 验「引擎能正确拆」
///   ⇒ **沙盒可跑**（不依赖 JSC）⇒ 分类拆分一改就红 ⭐
///
/// ⚠️ **期望值的来路**（不是拍脑袋）：
///   - Node 端到端实测：9 项（线路/模式/频道/平台/字数/状态/排序/登录大灰狼书源/登录番茄）
///   - 真机观测一致（轻阅交接文档：「发现页分类 ✅ 9 个（线路/模式/频道/平台/字数/状态/排序/登录）」）
///   - 其中前 7 项是站方的**筛选栏**（`type:"select"` ⇒ 栖阅契约）⇒ 引擎要拆成 filters
///   - 后 2 项才是**分类**（带 url）
final class StationDahulangTests: XCTestCase {

    private static let fixtureDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/station")
    }()

    private func loadFixture(_ name: String) throws -> String {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent(name))
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - ① 站方输出能被拆成 9 项

    func testStationResultParsesIntoNineItems() throws {
        let text = try loadFixture("dahulang-explore-result.json")
        let items = SourceEngine.exploreItems(from: .string(text))
        XCTAssertEqual(items.count, 9, "⭐ 站方 exploreUrl 的输出必须是 9 项（真语料）")
        XCTAssertEqual(items.map { $0["title"]?.scalarString ?? "" },
                       ["线路", "模式", "频道", "平台", "字数", "状态", "排序",
                        "登录大灰狼书源", "登录番茄"],
                       "⭐ 9 项的标题要逐字一致")
    }

    // MARK: - ② 拆成「7 个筛选栏 + 2 个分类」（⭐ 栖阅契约）

    func testStationResultSplitsIntoFiltersAndKinds() throws {
        let text = try loadFixture("dahulang-explore-result.json")
        let items = SourceEngine.exploreItems(from: .string(text))
        let (kinds, filters) = SourceEngine.splitExploreItems(items, base: "https://v5.langge.uk")
        // ⭐ 前 7 项是 `type:"select"` 的**筛选栏**（不是分类！）
        XCTAssertEqual(filters.map(\.title),
                       ["线路", "模式", "频道", "平台", "字数", "状态", "排序"],
                       "⭐ 站方的筛选栏要拆进 filters（不是分类）")
        // 后 2 项才是分类
        XCTAssertEqual(kinds.map(\.title), ["登录大灰狼书源", "登录番茄"],
                       "⭐ 带 url 的两项才是分类")
        // 筛选栏的可选项也要在（站方 UI 要靠它渲染下拉）
        XCTAssertEqual(filters.first?.chars.first, "https://v5.langge.uk",
                       "⭐ 筛选栏的选项要原样保留")
        XCTAssertEqual(filters.first?.defaultValue, "https://v5.langge.uk",
                       "⭐ 筛选栏的默认值要保留")
    }

    // MARK: - ③ ⭐⭐ 绝不能出现「未分组」（那正是真机上的假分类症状）

    func testNoFakeUngroupedCategory() throws {
        let text = try loadFixture("dahulang-explore-result.json")
        let items = SourceEngine.exploreItems(from: .string(text))
        let (kinds, filters) = SourceEngine.splitExploreItems(items, base: "https://v5.langge.uk")
        let allTitles = kinds.map(\.title) + filters.map(\.title)
        XCTAssertFalse(allTitles.contains("未分组"),
                       "⭐⭐ 真机症状：jsLib 半残 ⇒ 分类变成「未分组」假分类")
        XCTAssertFalse(allTitles.contains { $0.isEmpty },
                       "⭐ 不许有空标题的分类（站方 UI 会显示成一坨）")
    }
}
