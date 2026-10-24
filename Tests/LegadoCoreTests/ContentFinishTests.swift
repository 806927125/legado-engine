import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **正文收尾加工**（照抄老引擎 `reference/js/engine.js` 的 content op）
///
/// ⚠️⚠️ **2026-10-24 整链对拍挖出来的最后一条**：
///   老引擎拿完站方的 content 规则结果后，**还做两步**：
///   ① 正文里带 HTML 标签 ⇒ **转成纯文本**（`br`/`p` 变换行）
///   ② **清洗**：去掉「上一章/下一章/返回目录/加入书架/推荐本书/txt下载/请记住本站/www./广告」这类短行
///   ⇒ 新引擎以前**都没做** ⇒ **同一个源的新旧引擎正文不一样**（HTML vs 纯文本）⭐⭐⭐
///   ⇒ 站方很多源的 content 规则写的是 `@html` ⇒ 不转的话**正文里会露出 `<div id=...>` 标签** ⭐
///
/// ⇒ 这两条是**纯文本处理** ⇒ Linux 就能验 ⇒ 3 秒反馈 ⭐
final class ContentFinishTests: XCTestCase {

    // MARK: - HTML ⇒ 纯文本

    /// ⭐⭐⭐ **段落各占一行**（`<p>` 末尾追加换行）
    func testHTMLToTextKeepsParagraphsOnSeparateLines() {
        let out = SourceEngine.htmlToText("<p>第一段</p><p>第二段</p>")
        XCTAssertEqual(out, "第一段\n第二段",
                       "⭐⭐⭐ `<p>` 没有各占一行 ⇒ 正文排版跟老引擎不一样")
    }

    /// ⭐⭐ **`<br>` ⇒ 换行**
    func testHTMLToTextTurnsBrIntoNewline() {
        XCTAssertEqual(SourceEngine.htmlToText("上<br>下"), "上\n下")
    }

    /// ⭐⭐⭐ **不该进正文的标签要删掉**（script/style/iframe/svg…）
    func testHTMLToTextDropsScriptStyleAndFriends() {
        let out = SourceEngine.htmlToText("<p>正文</p><script>alert(1)</script><style>p{}</style><iframe src=x></iframe>")
        XCTAssertFalse(out.contains("alert"), "⭐⭐⭐ script 没删掉 ⇒ 正文里混进代码")
        XCTAssertFalse(out.contains("iframe"), "⭐⭐⭐ iframe 没删掉")
        XCTAssertTrue(out.contains("正文"))
    }

    /// ⭐ **空白归一**（不间断空格 / 全角空格 / 多余空格）
    func testHTMLToTextNormalizesWhitespace() {
        let out = SourceEngine.htmlToText("<p>甲\u{00a0}乙　丙</p>")
        XCTAssertFalse(out.contains("\u{00a0}"), "⭐⭐⭐ 不间断空格没归一")
        XCTAssertFalse(out.contains("\u{3000}"), "⭐⭐⭐ 全角空格没归一")
    }

    /// ⭐⭐ **纯文本原样返回**（不该乱动）
    func testHTMLToTextLeavesPlainTextAlone() {
        XCTAssertEqual(SourceEngine.htmlToText("就是一段话"), "就是一段话")
    }

    // MARK: - 清洗

    /// ⭐⭐⭐ **广告行要删掉**（上一章/下一章/返回目录/…）
    func testCleanContentDropsAdLines() {
        let out = SourceEngine.cleanContent("第一段正文\n上一章\n下一章\n返回目录\n加入书架")
        XCTAssertEqual(out, "第一段正文", "⭐⭐⭐ 广告行没删掉（老引擎会删）")
    }

    /// ⭐⭐⭐ **长行不误伤**（含「广告」但长度 ≥ 40 ⇒ 保留）
    func testCleanContentKeepsLongLines() {
        let long = "这一行很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长含广告两个字"
        XCTAssertGreaterThanOrEqual(long.count, 40)
        let out = SourceEngine.cleanContent("正文\n" + long)
        XCTAssertTrue(out.contains(long), "⭐⭐⭐ 长行被误删了（老引擎只删 < 40 字的短行）")
    }

    /// ⭐⭐ **三个以上连续换行 ⇒ 两个**
    func testCleanContentCollapsesExtraNewlines() {
        XCTAssertEqual(SourceEngine.cleanContent("甲\n\n\n\n乙"), "甲\n\n乙")
    }

    /// ⭐⭐ **首尾空白去掉**
    func testCleanContentTrimsEdges() {
        XCTAssertEqual(SourceEngine.cleanContent("\n\n  正文  \n\n"), "正文")
    }

    /// ⭐⭐⭐ **空行要留着**（段落之间的空行是排版）
    func testCleanContentKeepsBlankLines() {
        XCTAssertEqual(SourceEngine.cleanContent("甲\n\n乙"), "甲\n\n乙")
    }
}
