import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **字段覆盖门禁**（2026-11-18 · 照 legado-E 源码移植的那批）
///
/// 判据：**语义逐条对齐 legado-E 的实现**（不是「字段存在」，是「行为一致」）。
final class LegadoFieldCoverageTests: XCTestCase {

    // MARK: ① `isTrue()` 口径（legado-E `StringExtensions.isTrue`）

    func testIsTrueSemantics() {
        // 空 / null / false / no / not / 0 / 0.0 ⇒ 假
        for s in ["", " ", "null", "false", "FALSE", "False", "no", "NOT", "0", "0.0", " 0 "] {
            XCTAssertFalse(SourceEngine.isTrue(s), "「\(s)」必须算假（legado-E isTrue 口径）")
        }
        // 其余非空 ⇒ 真
        for s in ["true", "1", "yes", "vip", "非Vip", "0.1"] {
            XCTAssertTrue(SourceEngine.isTrue(s), "「\(s)」必须算真")
        }
        XCTAssertFalse(SourceEngine.isTrue(nil))
    }

    // MARK: ② `replaceRegex` = **当规则求值**（legado-E `BookContent.kt`）

    func testReplaceRegexDeletesMatchedLines() {
        // `##正则##` 形态 ⇒ **删除**匹配的部分（57 个真源的最常见写法）
        // ⚠️ 以前只认「`正则=>替换` 每行一条」的老格式 ⇒ 站方标准写法**完全没生效** ⭐⭐⭐
        let evaluator = Evaluator()
        let text = "正文第一行\n广告行\n正文第二行"
        let out = evaluator.applyContentProcess(text, ruleText: "##广告行##")
        XCTAssertFalse(out.contains("广告行"), "⭐⭐⭐ `##…##` 必须删掉匹配的部分")
        XCTAssertTrue(out.contains("正文第一行"))
        XCTAssertTrue(out.contains("正文第二行"))
    }

    func testReplaceRegexSupportsReplacementAndCaptureGroups() {
        let evaluator = Evaluator()
        // `##正则##替换` ⇒ 替换，且 `$1` 要展开成捕获组
        let out = evaluator.applyContentProcess("书名：某某书", ruleText: "##书名：(.*)##书名=$1（改）")
        XCTAssertTrue(out.contains("书名=某某书（改）"), "⭐ `##…##替换` 要替换，且 `$1` 展开")
        // 多条正则（`|` 分隔）⇒ 都要删
        let out2 = evaluator.applyContentProcess("甲\n广告乙\n丙", ruleText: "##广告乙|甲##")
        XCTAssertFalse(out2.contains("甲"))
        XCTAssertFalse(out2.contains("广告乙"))
        XCTAssertTrue(out2.contains("丙"))
    }

    func testReplaceRegexSupportsJsForm() throws {
        // `@js:` 形态（晋江文学在用）⇒ **当脚本跑**，正文当 `result`
        // ⚠️ JS 形态要真跑 ⇒ evaluator 必须带 JS 后端（沙盒用 Node）⭐⭐⭐
        let evaluator = Evaluator(js: try NodeJSExecutor())
        let out = evaluator.applyContentProcess("◎简介◎\n正文", ruleText: "@js: result.replace(/◎[^◎]*◎/g,'')")
        XCTAssertFalse(out.contains("◎"), "⭐ `@js:` 形态：正文当 result ⇒ 脚本能改正文")
        XCTAssertTrue(out.contains("正文"))
    }

    func testReplaceRegexKeepsLegacyArrowFormat() {
        // 老格式（`正则=>替换` 每行一条）仍要能用（旧书源还在用）⇒ 不许回归
        let text = "标题：某某书\n正文内容"
        let out = SourceEngine.clean(text, using: "标题：.*=>书名：")
        XCTAssertTrue(out.contains("书名："))
        XCTAssertFalse(out.contains("标题："))
    }

    // MARK: ③ 模型字段齐了（legado-E 的 BookSource 字段清单）

    func testRuleFieldsCoverLegadoSource() throws {
        let json = """
        {
          "name": "n", "author": "a", "kind": "k", "intro": "i", "coverUrl": "c",
          "lastChapter": "l", "bookUrl": "b", "wordCount": "w", "updateTime": "u",
          "tocUrl": "t", "chapterList": "cl", "chapterName": "cn", "chapterUrl": "cu",
          "isVolume": "iv", "isVip": "vip", "isPay": "pay", "formatJs": "fj",
          "nextTocUrl": "nt", "content": "co", "nextContentUrl": "nc",
          "subContent": "sc", "replaceRegex": "rr", "sourceRegex": "sr"
        }
        """
        let f = try JSONDecoder().decode(RuleFields.self, from: Data(json.utf8))
        XCTAssertEqual(f.updateTime, "u", "⭐ ruleBookInfo/ruleToc.updateTime")
        XCTAssertEqual(f.isPay, "pay", "⭐ ruleToc.isPay")
        XCTAssertEqual(f.formatJs, "fj", "⭐ ruleToc.formatJs")
        XCTAssertEqual(f.subContent, "sc", "⭐ ruleContent.subContent")
        XCTAssertEqual(f.replaceRegex, "rr")
        XCTAssertEqual(f.sourceRegex, "sr")
    }

    // MARK: ④ Chapter / BookInfo 的新字段

    func testChapterAndBookInfoCarryNewFields() {
        let ch = Chapter(name: "第1章", url: "u", isVolume: false, isVip: true,
                         isPay: true, updateTime: "2026-01-01", index: 0)
        XCTAssertTrue(ch.isVip)
        XCTAssertTrue(ch.isPay, "⭐ ruleToc.isPay ⇒ Chapter 要带")
        XCTAssertEqual(ch.updateTime, "2026-01-01")
        let bi = BookInfo(name: "n", updateTime: "2026-01-02")
        XCTAssertEqual(bi.updateTime, "2026-01-02", "⭐ ruleBookInfo.updateTime ⇒ BookInfo 要带")
    }
}
