import Foundation
import XCTest
@testable import LegadoCore

/// **JS 宿主 API 契约门禁** —— 三条：
/// ① **契约清单必须覆盖真实书源用到的 API**（从大灰狼 + 125 源扫出来的实证清单）
/// ② **scope 变量构造正确**（`result` / `baseUrl` / `key` / `page`）
/// ③ **求值形态正确**（末行表达式能取到「完成值」）—— 用 **Node 真跑**验
final class JSHostAPITests: XCTestCase {

    // MARK: - ① 契约 ⊇ 真实用量（⭐ 实证驱动）

    /// ⭐⭐ **契约不能漏**：站方真实用到的每个宿主 API 都必须在契约清单里。
    ///
    /// 清单来自 `conformance/fixtures/js-api-usage.json`
    /// （扫 🍅大灰狼聚合vip完全版 的 jsLib/loginUrl/9 处规则级 JS + 125 源包 ⇒ 实证）
    func testContractCoversRealUsage() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures")
        let data = try Data(contentsOf: dir.appendingPathComponent("js-api-usage.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let usage = try XCTUnwrap(root["methods"] as? [String])
        let props = try XCTUnwrap(root["properties"] as? [String])

        var missing: [String] = []
        for key in usage {
            if JSHostAPI.index[key] == nil { missing.append("方法 \(key)") }
        }
        for key in props {
            if JSHostAPI.index[key] == nil { missing.append("属性 \(key)") }
        }
        XCTAssertTrue(missing.isEmpty,
                      "契约漏了这些真实用到的 API（站方会报 undefined is not a function）：\(missing)")
    }

    /// 契约**自身的完整性**：不能有重复 key、每个条目都要能查到
    func testContractIsSelfConsistent() throws {
        let keys = JSHostAPI.all.map { $0.key }
        XCTAssertEqual(keys.count, Set(keys).count, "契约里有重复 key")
        for e in JSHostAPI.all {
            XCTAssertNotNil(JSHostAPI.index[e.key], "查不到自己：\(e.key)")
        }
        // ⭐ 数量下界**从实测清单读**（不写死）⇒ 站方加了新 API 时这条会红
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures")
        let data = try? Data(contentsOf: dir.appendingPathComponent("js-api-usage.json"))
        if let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = root["methods"] as? [String], let pr = root["properties"] as? [String] {
            // ⚠️ 一个 key 可能**既是方法又是属性**（站方写法不统一）⇒ 按**总数**比
            XCTAssertGreaterThanOrEqual(JSHostAPI.all.count, m.count + pr.count,
                                        "契约条目不该少于实测的 \(m.count + pr.count) 个")
        }
    }

    // MARK: - ② scope 构造

    func testScopeBuilderInjectsVariables() {
        let ctx = JSRunContext(base: .page("<html>原始内容</html>"), baseUrl: "https://x.example/p/a.html",
                            raw: "<html>原始内容</html>", key: "关键词", page: 3)
        let src = JSScopeBuilder.build(ctx)
        XCTAssertTrue(src.contains("var result ="), "要有 result：\n\(src)")
        XCTAssertTrue(src.contains("var baseUrl = \"https://x.example/p/a.html\""), "要有 baseUrl：\n\(src)")
        XCTAssertTrue(src.contains("var key = \"关键词\""), "要有 key：\n\(src)")
        XCTAssertTrue(src.contains("var page = 3"), "要有 page：\n\(src)")
        // ⭐ `result` 的值按**基准**分层（§S-RES）：页面级 ⇒ 页原文
        XCTAssertTrue(src.contains("原始内容"), "页面级基准 ⇒ result 是页原文：\n\(src)")
    }

    /// ⭐ `result` 在**条目级**基准 ⇒ 是那个对象，不是页原文
    func testResultFollowsBase() throws {
        let html = "<html><body><a href=\"/b\">书名</a></body></html>"
        let doc = try SwiftSoupDocument(html: html, baseURL: "https://x.example/")
        let node = DOMNodeRef(doc.document.queryAll("a")[0])
        let ctx = JSRunContext(base: .element(node), baseUrl: "https://x.example/", raw: html)
        let src = JSScopeBuilder.build(ctx)
        XCTAssertTrue(src.contains("书名"), "条目级基准 ⇒ result 是那个对象：\n\(src)")
        XCTAssertFalse(src.contains("原始"), "不该是页原文：\n\(src)")
    }

    // MARK: - ③ 求值形态（⭐ 用 Node 真跑）

    /// ⭐⭐ **末行表达式能取到「完成值」** —— 这是站方 JS 能不能出值的要害。
    ///
    /// ⚠️ 直接 eval 成 Script 拿不到完成值 ⇒ 必须包成函数体 + 追加 `return result`。
    /// ⇒ 这条用 **Node 真跑**验（沙盒 Linux 可跑）⇒ JSC 与 Node 共用同一份 scope 源码。
    func testCompletionValueViaNode() throws {
        let ctx = JSRunContext(base: .page("<html>x</html>"), baseUrl: "https://x.example/",
                            raw: "<html>x</html>", key: "kw", page: 1)
        // ① 末行表达式（站方主流写法）
        let src1 = JSScopeBuilder.build(ctx) + "\n" + JSScopeBuilder.program("1 + 2")
        XCTAssertEqual(try runNode(src1), "3", "末行表达式应取到完成值")

        // ② 站方给 `result` 赋过值（大灰狼 `ruleContent.content` 就是这么写的）
        let src2 = JSScopeBuilder.build(ctx) + "\n" + JSScopeBuilder.program("result = '赋值后';")
        XCTAssertEqual(try runNode(src2), "赋值后", "站方赋值过的 result 应被取到")

        // ③ 顶层 return ⇒ **语法错**（与 Legado/Rhino 一致：两边都是 eval Script）
        //    ⭐ 这条是**契约**：万一以后有人改成包函数体，就与安卓端不一致了 ⇒ 门禁要拦住
        let src3 = JSScopeBuilder.build(ctx) + "\n" + JSScopeBuilder.program("return 'x';")
        XCTAssertThrowsError(try runNode(src3), "顶层 return 应是语法错（与 Legado/Rhino 一致）")
    }

    /// ⭐ **scope 变量在站方代码里可见**（站方 jsLib 大量读 `baseUrl` / `key` / `result`）
    func testScopeVariablesVisibleToScript() throws {
        let ctx = JSRunContext(base: .page(""), baseUrl: "https://x.example/base.html",
                            raw: "", key: "我的关键词", page: 7)
        let src = JSScopeBuilder.build(ctx) + "\n" + JSScopeBuilder.program("baseUrl + '|' + key + '|' + page")
        XCTAssertEqual(try runNode(src), "https://x.example/base.html|我的关键词|7")
    }

    // MARK: - 工具

    /// 用 **Node** 跑一段 JS 源码，返回「完成值」的字符串形式
    private func runNode(_ source: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legado-js-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jsURL = dir.appendingPathComponent("scope.js")
        // 追加一行把完成值写进 __out
        try source.write(to: jsURL, atomically: true, encoding: .utf8)
        let runner = dir.appendingPathComponent("run.js")
        try """
        const fs = require('fs');
        const vm = require('vm');
        const src = fs.readFileSync(process.argv[2], 'utf8');
        const ctx = { __out: '', console: console };
        vm.createContext(ctx);
        const out = vm.runInContext(src, ctx);
        process.stdout.write(String(out === undefined ? '' : out));
        """.write(to: runner, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", runner.path, jsURL.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "node", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Node 跑失败" ])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
