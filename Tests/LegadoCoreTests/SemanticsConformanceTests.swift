import XCTest
@testable import LegadoCore

/// 假的 DOM 节点（测试用，不依赖 SwiftSoup）
final class FakeNode: DOMNode {
    let domID: String
    let textContent: String
    let ownTextContent: String
    let outerHTML: String
    let tagName: String
    init(id: String, text: String) {
        self.domID = id; self.textContent = text; self.ownTextContent = text
        self.outerHTML = "<x>\(text)</x>"; self.tagName = "x"
    }
    func attribute(_ name: String) -> String? { nil }
    func queryAll(_ css: String) -> [DOMNode] { [] }
    func matchesCSS(_ css: String) -> Bool { false }
    func descendants() -> [DOMNode] { [] }
}

/// 语义规格的**可执行**版本。
///
/// ⭐ **这份测试的断言对象是「从 fixture 解析出来的规则」，不是复述实现意图。**
/// （轻阅的教训：断言写在源码里、复述实现 ⇒ 测了个寂寞）
///
/// 跑法：`swift test`
final class SemanticsConformanceTests: XCTestCase {

    // MARK: - 模式判定（§S-CLS）

    func testClassifyAllFixtureCases() throws {
        let cases = try loadFixture()["cases"] as? [[String: Any]] ?? []
        let parser = RuleParser()
        var checked = 0

        for c in cases {
            guard let kind = c["kind"] as? String, kind == "classify",
                  let rule = c["rule"] as? String,
                  let expect = (c["expect"] as? [String: Any])?["kind"] as? String else { continue }
            let ctx = c["ctx"] as? [String: Any] ?? [:]
            let isJSON = (ctx["isJSON"] as? Bool) ?? false
            XCTAssertEqual(RuleClassifier.classify(rule, isJSON: isJSON).rawValue, expect,
                           "规则「\(rule)」的模式判定")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10, "fixture 里的 classify 用例太少，路径可能没走到")
    }

    // MARK: - 链段分类（§S-SEL-03~06）⭐ 本项目最关键的一条判定

    func testChainSegmentFixtureCases() throws {
        let cases = try loadFixture()["cases"] as? [[String: Any]] ?? []
        let parser = RuleParser()
        var checked = 0

        for c in cases {
            guard let kind = c["kind"] as? String, kind == "chainSegment",
                  let rule = c["rule"] as? String,
                  let expect = (c["expect"] as? [String: Any])?["steps"] as? String else { continue }
            let node = parser.parse(rule)
            var steps: [String] = []
            if case .chain(_, _, let cs) = node {
                steps = cs.map { s in
                    if case .sub = s { return "sub" } else { return "attr" }
                }
            }
            XCTAssertEqual(steps.joined(separator: ","), expect, "链「\(rule)」的链段分类")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 5, "fixture 里的链段用例太少")
    }

    /// ⭐ **回归锁**：裸标签名必须当子选择器。
    ///
    /// 轻阅在这里是错的（`jsoup-compat.js:218` 要求「必须有 `kw.` 前缀」）
    /// ⇒ 125 源里 279 处、60 个源的链断掉。
    func testBareTagNameIsChildSelector() {
        XCTAssertEqual(ChainSegmentClassifier.classify(segment: "li"),
                       .sub(selector: "tag:li", index: nil, exclusion: []),
                       "裸标签名 li ⇒ 子选择器（不是属性）")
        XCTAssertEqual(ChainSegmentClassifier.classify(segment: "a"),
                       .sub(selector: "tag:a", index: nil, exclusion: []))
        XCTAssertEqual(ChainSegmentClassifier.classify(segment: "img"),
                       .sub(selector: "tag:img", index: nil, exclusion: []))
    }

    /// ⭐ **反向锁**：属性白名单**必须还是**属性后缀（别把 S-SEL-06 的修复做过头）。
    func testAttributeWhitelistStaysAttribute() {
        for name in ["text", "html", "href", "src", "content", "owntext", "outerhtml", "all"] {
            guard case .attr(let got) = ChainSegmentClassifier.classify(segment: name) else {
                XCTFail("「\(name)」应该是属性后缀")
                continue
            }
            XCTAssertEqual(got, name)
        }
    }

    // MARK: - result 分层（§S-RES）⭐⭐⭐

    func testResultSemanticsByBase() {
        // 页面级 ⇒ 页原文（不是纯文本）
        XCTAssertEqual(RuleBase.page("<html><body>x</body></html>").resultValue,
                       .string("<html><body>x</body></html>"))
        // 条目级 / init 输出级 ⇒ 对象本身
        let obj = JSONValue.object(["book_id": .string("MTgzNTEy")])
        XCTAssertEqual(RuleBase.json(obj).resultValue, .json(obj))
        // 元素级 ⇒ 节点
        let node = DOMNodeRef(FakeNode(id: "n1", text: "查看目录"))
        XCTAssertEqual(RuleBase.element(node).resultValue, .node(node))
    }

    // MARK: - 顶层切分（§S-FBK）

    /// ⚠️ **站方 JS 里本来就有 `||`**（`result.tab || '小说'`）⇒ 切错就整条规则废。
    func testTopLevelSplitRespectsQuotesAndBrackets() {
        XCTAssertEqual(RuleParser.splitTopLevel("a || b", separators: ["||"]), ["a ", " b"])
        XCTAssertEqual(RuleParser.splitTopLevel("result.tab || '小说'", separators: ["||"]),
                       ["result.tab ", " '小说'"])
        XCTAssertEqual(RuleParser.splitTopLevel("f(a || b) || c", separators: ["||"]),
                       ["f(a || b) ", " c"])
        XCTAssertEqual(RuleParser.splitTopLevel("x[1 || 2] || y", separators: ["||"]),
                       ["x[1 || 2] ", " y"])
    }

    // MARK: - 排除语法（§S-EXCL）

    func testExclusionIsIndexNotCount() {
        // `!0` = 排除**第 0 个**（不是「排除前 0 个」）
        let node = RuleParser().parse("id.list@tag.li!0:1")
        guard case .chain(_, _, let steps) = node else { return XCTFail("应是链") }
        guard case .sub(_, _, let excl) = steps.last! else { return XCTFail("最后一段应是子选择器") }
        XCTAssertEqual(excl, [0, 1], "`!0:1` = 排除第 0、1 个")
    }

    // MARK: - 诊断（§S-DIA-07）——「真错误」vs「规则没命中」必须能区分

    /// ⭐ **这是整个项目最要紧的一条**：静默失效是轻阅最贵的病根。
    /// 「规则没命中」是正常结果；「响应类型不对 / 后端没接 / 语法不支持」是真错误。
    /// ⇒ 宿主 UI 必须能显示不同的提示。
    func testDiagnosisDistinguishesHardFailureFromNoMatch() throws {
        let ev = Evaluator()

        // ① 响应是 HTML，规则却是 JSONPath ⇒ **基准类型不符**（真错误）
        let htmlDoc = try SwiftSoupDocument(html: "<html><body><h1>标题</h1></body></html>",
                                           baseURL: "https://x/")
        let htmlBase = RuleBase.page("<html><body><h1>标题</h1></body></html>")
        var ctx = EvalContext(base: htmlBase, baseUrl: "https://x/")
        ctx.document = htmlDoc.document
        let e1 = ev.evalOne("$.title", base: htmlBase, ctx: ctx)
        XCTAssertTrue(e1.isHardFailure, "HTML 基准走 JSONPath 必须是真错误")
        XCTAssertEqual(e1.conclusion, .unsupported)

        // ② XPath 尚未实现 ⇒ 真错误（不支持）
        let e2 = ev.evalOne("@XPath://div", base: htmlBase, ctx: ctx)
        XCTAssertTrue(e2.isHardFailure)
        XCTAssertEqual(e2.conclusion, .unsupported)

        // ③ 选择器没匹配上 ⇒ **不是**真错误
        let e3 = ev.evalOne("div.nope", base: htmlBase, ctx: ctx)
        XCTAssertFalse(e3.isHardFailure, "没命中是正常结果，不是真错误")
        XCTAssertEqual(e3.conclusion, .ruleNotMatched)

        // ④ JS 后端未接 ⇒ 真错误
        let e4 = ev.evalOne("@js:result.a", base: .json(.object(["a": .int(1)])), ctx: ctx)
        XCTAssertTrue(e4.isHardFailure)
        XCTAssertEqual(e4.conclusion, .unsupported)

        // ⑤ 正则语法错 ⇒ 真错误
        let e5 = ev.evalOne("##([unclosed##", base: .page("abc"), ctx: ctx)
        XCTAssertTrue(e5.isHardFailure)
    }

    /// ⭐ 诊断**永远在**（不是可选附件）⇒ 不可能「静默」
    func testDiagnosticIsAlwaysPresent() throws {
        let ev = Evaluator()
        let base = RuleBase.page("<html><body><p>x</p></body></html>")
        let ctx = EvalContext(base: base, baseUrl: "https://x/")
        let e = ev.evalOne("div.nope", base: base, ctx: ctx)
        XCTAssertNotNil(e.diagnostic.failure, "失败必须带原因")
        XCTAssertFalse(e.diagnostic.summary.isEmpty, "诊断必须能说清发生了什么")
    }

    /// 成功的求值 ⇒ 诊断里**没有** failure
    func testSuccessfulEvaluationHasNoFailure() throws {
        let ev = Evaluator()
        let doc = try SwiftSoupDocument(html: "<html><body><h1>标题</h1></body></html>",
                                       baseURL: "https://x/")
        var ctx = EvalContext(base: .page("<html><body><h1>标题</h1></body></html>"), baseUrl: "https://x/")
        ctx.document = doc.document
        let e = ev.evalOne("tag.h1@text", base: ctx.base, ctx: ctx)
        XCTAssertNil(e.diagnostic.failure, "成功不该有 failure")
        XCTAssertEqual(e.value.text, "标题")
        XCTAssertEqual(e.conclusion, .ok)
    }

    // MARK: - fixture

    private func loadFixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LegadoCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 项目根
            .appendingPathComponent("conformance/fixtures/semantics-cases.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }
}
