import Foundation
import XCTest
@testable import LegadoCore

/// **规则语义门禁** —— 专治「断言看着有、其实验不到」。
///
/// ⭐ **为什么单独一份**：
/// 端到端门禁（`EndToEndSourceTests`）验的是「整条流水线跑不跑得通」，
/// 但它**验不到某些引擎语义** —— 比如站方的净化词在 fixture 里压根不存在，
/// 那「删掉它」和不删**结果一样** ⇒ 断言平凡通过 ⇒ 门禁是假的。
/// ⇒ 这里用**构造出来的**规则，把每条语义单独钉死。
final class RuleSemanticsTests: XCTestCase {

    private func makeCtx(_ html: String) -> EvalContext {
        var ctx = EvalContext(base: .page(html), baseUrl: "https://x.example/")
        ctx.raw = html
        if let doc = try? SwiftSoupDocument(html: html, baseURL: "https://x.example/") {
            ctx.document = doc.document
        }
        return ctx
    }

    private let page = "<html><body><h1>主标题</h1><h2>副标题</h2><p>正文段落</p></body></html>"

    // MARK: - ① 逗号是 CSS 并集，不是兜底链

    /// ⭐⭐ **`a,b` 是 CSS 选择器并集** —— 不是「多规则回退」。
    ///
    /// 真书源踩出来的：`.catalog-section-title,.article-title a`
    /// 一旦按逗号拆成兜底链 ⇒ 第一段命中就停 ⇒ **16 个章节全丢**。
    func testCommaIsCSSUnionNotFallback() {
        let ev = Evaluator()
        let ctx = makeCtx(page)
        let e = ev.getElements("tag.h1, tag.h2", base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.items.count, 2, "逗号两侧都该命中（CSS 并集）")
        XCTAssertEqual(e.value.text, "主标题\n副标题")
    }

    /// ⭐ 逗号并集 + `||` 兜底要能同时用（真书源的 chapterList 就是这个形状）
    func testCommaUnionWithOrFallback() {
        let ev = Evaluator()
        let ctx = makeCtx(page)
        // 第一段命中 ⇒ `||` 后半段不再求值
        let e = ev.getElements("tag.h1, tag.h2 || tag.p", base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.items.count, 2, "逗号并集先命中，`||` 后半段不参与")
    }

    // MARK: - ② 换行多规则 = 合并

    /// ⭐⭐ **换行分隔的多条规则 ⇒ 结果合并**（不是只跑第一行）。
    ///
    /// 站方的多规则写法是**换行**。轻阅只返回第一行（实测）⇒ 那是**轻阅的债**。
    func testNewlineSeparatedRulesAreMerged() {
        let ev = Evaluator()
        let ctx = makeCtx(page)
        let e = ev.getElements("tag.h1@text\ntag.h2@text", base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.items.count, 2, "两行都该在结果里")
        XCTAssertEqual(e.value.text, "主标题\n副标题")
    }

    /// 字符串出口（字段规则）⇒ 多行时取**第一个非空**
    func testNewlineSeparatedFieldTakesFirstNonEmpty() {
        let ev = Evaluator()
        let ctx = makeCtx(page)
        let e = ev.evalOne("tag.zzz@text\ntag.h2@text", base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.text, "副标题", "第一行没命中 ⇒ 取第二行")
    }

    /// 含整块语法的规则**不按行拆**（`{{…}}` / `<js>` / `@js:`）
    func testBlockRulesAreNotSplitByNewline() {
        XCTAssertEqual(Evaluator.splitRuleLines("{{baseUrl}}/a\n{{baseUrl}}/b").count, 1,
                       "含模板的整条规则不该被拆")
        XCTAssertEqual(Evaluator.splitRuleLines("<js>x</js>\nfoo").count, 1,
                       "含 `<js>` 的整条规则不该被拆")
        XCTAssertEqual(Evaluator.splitRuleLines("a\nb").count, 2)
    }

    // MARK: - ③ 整条规则 = 取值模式

    /// ⭐⭐ **整条规则就是一个取值模式** ⇒ 「取当前节点的这个值」。
    ///
    /// 真书源逐字：`"chapterName": "text"` / `"chapterUrl": "href"`。
    /// 以前这类规则被当 CSS 标签名查（`select("text")`）⇒ **永远查不到**。
    func testWholeRuleAsValueMode() {
        let ev = Evaluator()
        let html = "<html><body><div class=\"it\"><a href=\"/x.htm\">链接文字</a></div></body></html>"
        var ctx = makeCtx(html)
        let doc = try! SwiftSoupDocument(html: html, baseURL: "https://x.example/")
        ctx.document = doc.document
        let div = DOMNodeRef(doc.document.queryAll("div.it")[0])
        let node = DOMNodeRef(doc.document.queryAll("a")[0])

        let text = ev.evalOne("text", base: .element(node), ctx: ctx)
        XCTAssertEqual(text.value.text, "链接文字", "`text` ⇒ 取节点文本")
        // ⚠️ 对**没有 href 的节点**求值 ⇒ 空（这才是「取自身属性」的语义）
        let noHref = ev.evalOne("href", base: .element(div), ctx: ctx)
        XCTAssertEqual(noHref.value.text, "", "`href` 取的是【节点自己】的 href，不是后代的")

        // ⚠️ `href` 是 **URL 属性** ⇒ 按 Legado 语义会**绝对化**
        let href = ev.evalOne("href", base: .element(node), ctx: ctx)
        XCTAssertEqual(href.value.text, "https://x.example/x.htm", "`href` ⇒ 取节点 href（并绝对化）")
    }

    /// ⚠️ `text.x`（文本完全相等）**不是**取值模式 —— 两者别混
    func testTextEqualsIsNotValueMode() {
        let ev = Evaluator()
        let ctx = makeCtx(page)
        let e = ev.getElements("text.主标题", base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.text, "主标题", "`text.x` 是筛选，不是取值")
    }

    // MARK: - ④ 尾部正则 = 删除 / 替换

    /// ⭐⭐ **尾部 `##正则`（无替换）⇒ 删除匹配部分**。
    ///
    /// ⚠️ 以前这里把 spec 拆坏 ⇒ pattern 变空 ⇒ **整条规则返回空**。
    /// 真书源 `content = "tag.p@html##我爱读者校园网"` 直接踩中。
    func testTailRegexDeletesMatch() {
        let ev = Evaluator()
        let ctx = makeCtx(page)
        let e = ev.evalOne("tag.p@text##正文", base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.text, "段落", "尾部正则应删掉匹配部分")
    }

    /// 尾部 `##正则##替换` ⇒ 替换
    func testTailRegexReplacesMatch() {
        let ev = Evaluator()
        let ctx = makeCtx(page)
        let e = ev.evalOne("tag.p@text##正文##正文段", base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.text, "正文段段落", "尾部正则应做替换")
    }

    /// ⚠️ **「纯提取」是整条规则为 `##正则##` 时的语义** —— 跟尾部别混
    func testWholeRuleRegexIsExtraction() {
        let ev = Evaluator()
        // ⚠️ 用**不含数字**的页（`<h1>` 里就有 "1"！）
        let clean = "<html><body><p>第12章 开始</p></body></html>"
        let ctx = makeCtx(clean)
        let e = ev.evalOne("##(\\d+)##", base: ctx.base, ctx: ctx)
        XCTAssertEqual(e.value.text, "12", "整条正则规则 ⇒ 取第 1 个捕获组")
    }

    // MARK: - ⑤ 相对求值

    /// ⭐ 字段规则在**条目节点内**相对求值（Legado 语义）
    func testFieldRuleIsRelativeToItem() {
        let ev = Evaluator()
        let html = "<html><body><div class=\"item\"><a href=\"/1.htm\">书名</a></div></body></html>"
        var ctx = makeCtx(html)
        let doc = try! SwiftSoupDocument(html: html, baseURL: "https://x.example/")
        ctx.document = doc.document
        let item = DOMNodeRef(doc.document.queryAll("div.item")[0])

        let name = ev.evalOne("a@text", base: .element(item), ctx: ctx)
        XCTAssertEqual(name.value.text, "书名")
        let url = ev.evalOne("a@href", base: .element(item), ctx: ctx)
        // ⚠️ `href` 是 **URL 属性** ⇒ 按 Legado 语义会**绝对化**
        XCTAssertEqual(url.value.text, "https://x.example/1.htm")
    }

    // MARK: - ⑥ 节点求值走同一条路径

    /// ⭐ `evalNodes` 必须支持组合节点（`||` / `,`）—— 以前只认 `.chain` ⇒ 整条链返回空
    func testEvalNodesSupportsFallback() {
        let ev = Evaluator()
        let ctx = makeCtx(page)
        let nodes = ev.evalNodes("tag.zzz || tag.h1, tag.h2", base: ctx.base, ctx: ctx)
        XCTAssertEqual(nodes.count, 2, "`||` 兜底 + 逗号并集都该生效")
    }
}
