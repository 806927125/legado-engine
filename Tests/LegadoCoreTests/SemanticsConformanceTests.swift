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
