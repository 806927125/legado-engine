import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **已知差异门禁**：老引擎（JS 参考实现）与新引擎的差异**必须在白名单里**。
///
/// ⚠️ **为什么要有这条**（2026-10-25 实证）：
///   「把老引擎的规则转移到新引擎」⇒ 最怕的是**默默变行为**。
///   ⇒ 差异分两种：**债**（老引擎错，新引擎对 ⇒ 有意不一致，白名单登记）
///   与 **回归**（老引擎对，新引擎错 ⇒ 必须修）⭐⭐⭐
///   ⇒ 白名单外的差异 = 回归 ⇒ 门禁红 ⭐
///
/// ⇒ 白名单：`conformance/fixtures/known-legacy-divergences.json`
/// ⇒ 裁决记录：`docs/legacy-divergences.md`
///
/// ⚠️ **跑不动 JS 侧时必须显式 skip，且不许说成「全绿」**（记忆里的门禁纪律）⭐⭐⭐
final class LegacyDivergenceGuardTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// ① 白名单本身要**自洽**：id 唯一、有理由、verdict 是已知取值
    func testKnownDivergenceListIsSelfConsistent() throws {
        let url = repoRoot().appendingPathComponent("conformance/fixtures/known-legacy-divergences.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try XCTUnwrap(root["divergences"] as? [[String: Any]])
        XCTAssertGreaterThan(list.count, 0, "白名单空了 ⇒ 是不是把差异都修好了？那该删掉这条门禁")
        let ids = list.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids.count, Set(ids).count, "白名单里有重复 id")
        for item in list {
            let id = item["id"] as? String ?? "?"
            XCTAssertNotNil(item["reason"] as? String, "差异 \(id) 没写理由 ⇒ 不许『以后再说』")
            XCTAssertNotNil(item["semantic"] as? String, "差异 \(id) 没写语义编号")
            let verdict = item["verdict"] as? String ?? ""
            XCTAssertTrue(verdict.contains("老引擎") || verdict.contains("有意"),
                          "差异 \(id) 的判定写得不明确：\(verdict)")
        }
    }

    /// ② ⭐ **白名单里的 id 必须真的存在于 fixture**（否则白名单会腐烂，掩盖真差异）
    func testKnownDivergenceIdsExistInFixture() throws {
        let fixtureURL = repoRoot().appendingPathComponent("conformance/fixtures/semantics-cases.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let caseIDs = Set(cases.compactMap { $0["id"] as? String })

        let listURL = repoRoot().appendingPathComponent("conformance/fixtures/known-legacy-divergences.json")
        let listData = try Data(contentsOf: listURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: listData) as? [String: Any])
        let list = try XCTUnwrap(root["divergences"] as? [[String: Any]])
        let ids = list.compactMap { $0["id"] as? String }
        let missing = ids.filter { !caseIDs.contains($0) }
        XCTAssertTrue(missing.isEmpty,
                      "白名单里的这些 id 在 fixture 里已经不存在了 ⇒ 该清掉：\(missing)")
    }

    /// ③ ⭐⭐ **真跑 JS 参考侧**：失败 id 必须全在白名单里（白名单外的失败 = 回归 ⇒ 红）
    ///
    /// ⚠️ 跑不动（缺 node / jsdom / 缺参考实现）⇒ **显式 skip**，并在输出里说清楚
    func testJavaScriptReferenceDivergencesAreAllKnown() throws {
        let root = repoRoot()
        let runner = root.appendingPathComponent("conformance/js-runner.js")
        let engineDir = root.appendingPathComponent("reference/js")
        guard FileManager.default.fileExists(atPath: runner.path),
              FileManager.default.fileExists(atPath: engineDir.path) else {
            throw XCTSkip("⚠️【SKIP】缺参考实现（reference/js 或 js-runner.js）⇒ 本次没验「老引擎差异是否都在白名单」")
        }
        // 找 node + jsdom（jsdom 常常装在**兄弟仓库**里 ⇒ 一起探）⭐
        let nodePath = "/usr/bin/env"
        // 候选 node_modules：自己仓库 → 兄弟仓库（App 仓库装了 jsdom）
        var candidatePaths: [String] = []
        if let e = ProcessInfo.processInfo.environment["NODE_PATH"], !e.isEmpty { candidatePaths.append(e) }
        let siblings = ["qireaderlite", "qireader", "app"]
        for s in siblings {
            candidatePaths.append(root.deletingLastPathComponent()
                .appendingPathComponent(s).appendingPathComponent("node_modules").path)
        }
        candidatePaths.append(root.appendingPathComponent("node_modules").path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = ["node", "-e", "require.resolve('jsdom')"]
        var env = ProcessInfo.processInfo.environment
        env["NODE_PATH"] = candidatePaths.joined(separator: ":")
        proc.environment = env
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = pipe
        do {
            try proc.run()
        } catch {
            throw XCTSkip("⚠️【SKIP】本机跑不了 node ⇒ 本次没验「老引擎差异是否都在白名单」")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw XCTSkip("⚠️【SKIP】缺 jsdom（npm i jsdom）⇒ 本次没验「老引擎差异是否都在白名单」")
        }

        // 跑 JS 参考侧
        let run = Process()
        run.executableURL = URL(fileURLWithPath: nodePath)
        run.arguments = ["node", runner.path]
        var env2 = ProcessInfo.processInfo.environment
        env2["LEGADO_ENGINE_DIR"] = engineDir.path
        run.environment = env2
        let outPipe = Pipe()
        run.standardOutput = outPipe
        run.standardError = FileHandle.nullDevice
        try run.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""

        var failed: [String] = []
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ok = obj["ok"] as? Bool, ok == false,
                  let id = obj["id"] as? String else { continue }
            failed.append(id)
        }
        XCTAssertFalse(failed.isEmpty, "JS 参考侧一条都没跑 ⇒ 这次对比没有意义（别把它当成『全绿』）⭐")

        let listURL = root.appendingPathComponent("conformance/fixtures/known-legacy-divergences.json")
        let listData = try Data(contentsOf: listURL)
        let listRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: listData) as? [String: Any])
        let known = Set((listRoot["divergences"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })

        let unknown = failed.filter { !known.contains($0) }
        XCTAssertTrue(unknown.isEmpty,
                      """
                      ⭐⭐⭐ **白名单外的差异 = 回归**（新引擎相对老引擎默默变了行为）：
                      \(unknown)
                      ⇒ 两种可能：① 新引擎改错了 ⇒ 修回去；② 确实是「有意不一致」⇒ 登记进
                         conformance/fixtures/known-legacy-divergences.json + docs/legacy-divergences.md
                      ⭐
                      """)

        // 反向：白名单里不该再有「已经一致」的 id（修好了就要清白名单）
        let stillFailing = Set(failed)
        let stale = known.filter { !stillFailing.contains($0) }
        XCTAssertTrue(stale.isEmpty,
                      "白名单里这些 id 已经和老引擎一致了 ⇒ 清掉（白名单会腐烂）⭐：\(stale.sorted())")
    }
}
