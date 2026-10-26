import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **`org.jsoup` 兼容层的门禁**（2026-10-26）
///
/// ──────────────────────────────────────────────────────────────
/// **为什么要有它**（老引擎有、新引擎缺 ⇒ 7 个源的目录/正文/搜索全废）
/// ──────────────────────────────────────────────────────────────
///   · 站方 `jsLib` / 规则代码里 **`org.jsoup.Jsoup.parse` 43 处 / 7 个源**
///     （125 源语料，**剥注释后**统计 ⇒ 注释里的不算）
///   · 老引擎（轻阅 WKWebView）有 ⇒ 站方规则在老引擎上是跑通的
///   ⇒ ⇒ 新引擎必须补上（用户规矩：「老引擎有的、新引擎没有的 ⇒ 吸收进新的」）⭐⭐⭐
///
/// ──────────────────────────────────────────────────────────────
/// **为什么是【纯 JS】**（不是「Swift 解析 + 桥回 JS」）
/// ──────────────────────────────────────────────────────────────
///   · JSC（真机）**没有 DOM**；Node（沙盒）**也没有 DOM**
///   · 而 **Node 后端不回调 Swift**（`__hostJSON` 是纯 JS 实现 + 预置缓存）
///   ⇒ ⇒ 任何能力只要「**沙盒能验**」⇒ 就必须写在 JS 里
///   ⇒ ⇒ **一份 JS ⇒ 两端一模一样** ⇒ 沙盒绿 = 真机绿 ⭐⭐⭐
///
/// ──────────────────────────────────────────────────────────────
/// **三条门禁**
/// ──────────────────────────────────────────────────────────────
///   ① **产物 == 源**（`OrgJsoupCompat.swift` 是 `org-jsoup.js` 的产物 ⇒ 过期就红）
///   ② **JS 语法有效**（`node --check` ⇒ 生成代码必须验语法，老规矩）
///   ③ **行为**（走真 Node 后端 ⇒ 沙盒 3 秒出反馈）
final class OrgJsoupCompatTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - ① 产物 == 源（防止两份拷贝漂移）

    func testEmbeddedCopyMatchesSourceFile() throws {
        let src = repoRoot().appendingPathComponent("Resources/org-jsoup.js")
        let data = try Data(contentsOf: src)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertGreaterThan(text.count, 5000, "源文件太短 ⇒ 路径没走到")
        XCTAssertTrue(
            OrgJsoupCompat.source.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)),
            "⭐⭐⭐ 内嵌的 JS 与 `org-jsoup.js` 对不上 ⇒ **产物过期** ⇒ 跑 `python3 Scripts/embed_js.py` 重新生成")
        // ⭐⭐⭐ 逐字比对（头部 + 尾部都锚住 ⇒ 中间被改也会红）
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(OrgJsoupCompat.source.contains(trimmed),
                      "⭐⭐⭐ 内嵌的 JS 与 `org-jsoup.js` **不是同一份** ⇒ 跑 `python3 Scripts/embed_js.py`")
    }

    // MARK: - ② JS 语法必须有效（`node --check`）

    func testGeneratedJsPassesNodeSyntaxCheck() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 本次没验 JS 语法（**不等于通过**）")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("org-jsoup-\(UUID().uuidString).js")
        try OrgJsoupCompat.source.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["node", "--check", tmp.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0,
                       "⭐⭐⭐ `node --check` 没过 ⇒ 内嵌的 JS 语法坏（老规矩：生成代码必须验语法）：\n\(out.prefix(600))")
    }

    // MARK: - ③ 行为（走真 Node 后端）

    func testOrgJsoupIsAvailableInBothScopes() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 本次没验（**不等于通过**）")
        let js = try NodeJSExecutor()
        let ctx = JSRunContext(base: .page("<html>x</html>"), baseUrl: "https://x.example/")

        // 规则求值路径（scope）
        XCTAssertEqual(try js.run("typeof org.jsoup.Jsoup.parse", context: ctx).scalarString, "function",
                       "⭐⭐⭐ 规则求值里必须有 `org.jsoup.Jsoup.parse`（站方 43 处在用）")
        // 全局路径（jsLib / loginUrl 走 runGlobal ⇒ 站方会这么用）
        XCTAssertEqual(try js.runGlobal("typeof org.jsoup.Jsoup.parse", context: ctx).scalarString, "function",
                       "⭐⭐⭐ 全局里也必须有（jsLib 走 runGlobal ⇒ 只放 scope 不够）")
    }

    /// ⭐⭐⭐ **站方真实用法的形状**（选择器 + 方法都照抄语料统计）
    func testStationJsoupUsageShapes() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 本次没验（**不等于通过**）")
        let js = try NodeJSExecutor()
        let ctx = JSRunContext(base: .page("<html>x</html>"), baseUrl: "https://x.example/")

        let html = """
        <html><body>
        <div class="articleHide">广告<script>var x = '</div>';alert(1)</script></div>
        <div class="muludiv"><a href="/b/1">书名一</a><a href="/b/2">书名二</a></div>
        <ul class="stui-content__playlist"><li><a href="/c/1">第一章</a></li><li><a href="/c/2">第二章</a></li></ul>
        <ul class="nav nav-pills"><li><a href="/p/1">平台一</a></li><li><a href="/p/2">平台二</a></li></ul>
        <ul class="topul"><li>甲<ul><li>甲-子</li></ul></li><li>乙</li></ul>
        <table id="jieqi_page_contents"><tr><td class="c_row">章节一</td></tr><tr><td class="c_row">章节二</td></tr></table>
        <p class="xs-show">正文段落</p>
        <div class="noveldefaultimage">封面</div>
        <div>内容未加载完成</div>
        </body></html>
        """
        // 用 jsLib 载入 HTML ⇒ 模拟站方「先 ajax 再 parse」的真实链
        _ = try js.runGlobal("var __html = " + Self.jsStringLiteral(html) + ";", context: ctx)

        func run(_ code: String) throws -> String {
            try js.run(code, context: ctx).scalarString
        }

        // ① 基础选择器
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).select('a').size()"), "6",
                       "⭐⭐⭐ `select('a').size()` 不对")
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).select('a').first().text()"), "书名一",
                       "⭐⭐⭐ `first().text()` 不对")
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).select('a').first().attr('href')"), "/b/1",
                       "⭐⭐⭐ `attr('href')` 不对")
        // ② 组合器
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).select('ul.nav.nav-pills li a').size()"), "2",
                       "⭐⭐⭐ 后代 + 多 class 组合不对")
        // ⚠️⭐⭐⭐ **必须有一层嵌套**（否则「子代」和「后代」结果一样 ⇒ 这条断言是【平凡通过】）
        //   ⇒ 上面 HTML 里 `ul.topul` 的第一个 `li` 里还有一个 `ul > li` ⇒
        //   ⇒ `>` ⇒ 2 个（只有直接子 `li`）／后代 ⇒ 3 个 ⇒ **两者能区分** ⭐⭐⭐
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).select('ul.topul > li').size()"), "2",
                       "⭐⭐⭐ 子代组合器 `>` 不对（**要能区分后代** ⇒ 否则是平凡通过）")
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).select('ul.topul li').size()"), "3",
                       "⭐⭐⭐ 后代组合器（空格）不对")
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).select('#jieqi_page_contents .c_row').size()"), "2",
                       "⭐⭐⭐ `#id` + 后代 不对")
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).select('#jieqi_page_contents tr').size()"), "2",
                       "⭐⭐⭐ `#id` + 标签 不对")
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).select('ul.stui-content__playlist li a').first().text()"), "第一章",
                       "⭐⭐⭐ 站方那条 `ul.stui-content__playlist` 链不对")
        // ③ ⭐⭐⭐ `Array.from(els).reverse()`（站方真写法 ⇒ Elements 必须是**真数组**）
        XCTAssertEqual(try run("Array.from(org.jsoup.Jsoup.parse(__html).select('a')).reverse().map(function(e){return e.text();})[0]"),
                       "平台二",
                       "⭐⭐⭐ `Array.from(els).reverse()` 不对 ⇒ Elements 必须是真数组（老引擎同款）")
        // ④ `body()` / `html()` / `outerHtml()` / `toString()`
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).body().tagName()"), "body",
                       "⭐⭐⭐ `body()` 不对")
        let bodyHtml = try run("org.jsoup.Jsoup.parse(__html).body().html()")
        XCTAssertTrue(bodyHtml.contains("articleHide"), "⭐⭐⭐ `html()` 不对")
        let outer = try run("org.jsoup.Jsoup.parse(__html).select('.muludiv').first().outerHtml()")
        XCTAssertTrue(outer.contains("书名一"), "⭐⭐⭐ `outerHtml()` 不对")
        // ⑤ ⭐⭐⭐ `remove()`（八叉的正文净化：`doc.select('.articleHide').remove()`）
        XCTAssertEqual(try run("var d2 = org.jsoup.Jsoup.parse(__html); d2.select('.articleHide').remove(); d2.select('.articleHide').size()"),
                       "0",
                       "⭐⭐⭐ `remove()` 不对（站方用它净化正文广告）")
        // ⑥ ⭐⭐⭐ jsoup 专有的 `:matchesOwn(正则|带括号)`（站方真写法）
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse(__html).select(':matchesOwn(内容未加载完成|关闭(阅读|小说)模式)').size()"),
                       "1",
                       "⭐⭐⭐ `:matchesOwn(...)` 不对（**参数里有嵌套括号** ⇒ 不能只找第一个 ')'）")
        // ⑦ 实体解码
        XCTAssertEqual(try run("org.jsoup.Jsoup.parse('<p>a&nbsp;b</p>').select('p').text()"), "a b",
                       "⭐⭐⭐ 实体没解码（nbsp 要归一成空格）")
    }

    /// ⭐⭐⭐ **老引擎的 API 面不许少**（站方可能用到清单里的任何一个）
    func testApiSurfaceMatchesLegacyEngine() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "没装 node ⇒ 本次没验（**不等于通过**）")
        let js = try NodeJSExecutor()
        let ctx = JSRunContext(base: .page("<html>x</html>"), baseUrl: "https://x.example/")
        let names = [
            "org.jsoup.Jsoup.parse", "org.jsoup.Jsoup.parseBodyFragment", "org.jsoup.Jsoup.clean",
            "org.jsoup.Jsoup.isBlank", "org.jsoup.nodes.Element", "org.jsoup.nodes.Document",
            "org.jsoup.select.Elements", "org.jsoup.parser.Parser.parseHTML",
            "org.jsoup.Connection", "org.jsoup.Jsoup.Method.GET"
        ]
        for n in names {
            let v = try js.run("typeof " + n, context: ctx).scalarString
            XCTAssertNotEqual(v, "undefined", "⭐⭐⭐ 老引擎有 `\(n)` ⇒ 新引擎必须有（老实现是事实标准）")
        }
    }

    /// JS 字符串字面量（把 Swift 字符串变成 JS 里的字符串字面量）
    private static func jsStringLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }
}
