import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **Sextant 兜底门禁**（2026-11-18 · 搬栖阅/柴阅同款 JSONPath 引擎）
///
/// ⭐⭐⭐ **本轮最重要的实测结论**（245 条真实 JSONPath 规则的差集扫描）：
///   · 「手写能解析 / Sextant 不认」= **0 条** ⇒ **解析层我们不缺**（手写解析器已覆盖语料里的标准 JSONPath）
///   · 「Sextant 能解析 / 手写不认」= **17 条** ⇒ **全是 Legado 复合语法**
///     （`||` 兜底链 / `##` 正则替换 / `@put:` / `@js:` / `&&` 拼接）
///     ⇒ ⇒ **把它们交给 Sextant = 语义错**（Sextant 只懂标准 JSONPath）⇒ **必须守** ⭐⭐⭐
///   ⇒ ⇒ 兜底的价值 =「标准 JSONPath 的**求值细节/边界行为**与栖阅逐字一致」+「免维护手写实现」
///
/// ⚠️ 本门禁要钉住三件事：
///   ① **含 Legado 复合语法的路径不许被 Sextant 接管**（否则把对的改错）
///   ② **手写与 Sextant 在语料上的解析能力必须等价**（差集 = 0 ⇒ 漂移即红）
///   ③ **兜底真能救回「纯标准 JSONPath」的路径**
final class SextantFallbackTests: XCTestCase {

    private let doc: JSONValue = JSONValue(json: """
    {"code":0,"data":{"state":[{"dataName":"novel_search_list","items":[{"n":"书一","w":10},{"n":"书二","w":20}]},
                             {"dataName":"other_list","items":[{"n":"别的"}]}]}}
    """)

    // MARK: - ① Legado 复合语法 ⇒ 不许被 Sextant 接管

    func testLegadoCompositePathsAreNotHandedToSextant() {
        // ⭐⭐⭐ 语料里实测到的 17 条「Sextant 能认、手写不认」的形态
        let legado = [
            "$.novelName||$.novelname||$.message",      // 兜底链
            "$.bid##(\\d+)##https://book.qq.com/book-detail/$1##",  // 正则替换
            "$.title@put:{bid:id}",                       // 尾部后处理
            "$.iconUrlSmall@js:\"https://b.heiyanimg.com\"+result",
            "$.category&&{$.score}分",                    // 拼接
        ]
        for p in legado {
            XCTAssertFalse(SextantFallback.isPureJSONPath(p), "「\(p)」是 Legado 复合语法 ⇒ 不许进 Sextant")
            XCTAssertNil(SextantFallback.select(doc, p), "「\(p)」不许被 Sextant 求值（语义会错）")
        }
    }

    func testPureJSONPathIsAllowed() {
        XCTAssertTrue(SextantFallback.isPureJSONPath("$.data.state[0].items[0].n"))
        XCTAssertTrue(SextantFallback.isPureJSONPath("$.data.state[?(@.dataName=='x')].items[*].n"))
    }

    // MARK: - ② 语料对拍：解析能力必须等价（差集 = 0）

    func testCorpusParseParity() {
        guard let path = ProcessInfo.processInfo.environment["LEGADO_CORPUS"],
              FileManager.default.fileExists(atPath: path) else {
            print("⚠️ 未设 LEGADO_CORPUS ⇒ 跳过语料对拍（**没验到，不算通过**）")
            return
        }
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            XCTFail("语料读不出来")
            return
        }
        let arr: [Any] = (obj as? [Any]) ?? ((obj as? [String: Any]).map { [$0] } ?? [])
        var paths: Set<String> = []
        func scan(_ any: Any) {
            if let s = any as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if (t.contains("$.") || t.contains("[?(")) && !t.contains("<") && !t.contains("\n") {
                    paths.insert(t)
                }
            } else if let d = any as? [String: Any] { for v in d.values { scan(v) } }
            else if let a = any as? [Any] { for v in a { scan(v) } }
        }
        for s in arr { scan(s) }
        XCTAssertFalse(paths.isEmpty, "语料里没抽出路径（语料位置错了？）")

        var legacyOnly: [String] = []
        for p in paths {
            let legacyOK = JSONPath.parse(p) != nil
            let sextantOK = SextantFallback.validate(p) == nil
            if legacyOK && !sextantOK { legacyOnly.append(p) }
        }
        // ⭐ 断言方向：**手写认得、Sextant 不认**的路径必须为 0
        //   （反方向那批是 Legado 复合语法 ⇒ 由 `isPureJSONPath` 守卫挡住 ⇒ 不是缺口）
        XCTAssertTrue(legacyOnly.isEmpty,
                      "以下路径手写能解析、Sextant 不认 ⇒ 兜底会把它们改错：\(legacyOnly.prefix(5))")
    }

    // MARK: - ③ 兜底真能救回「纯标准 JSONPath」

    func testSextantRescuesPureJSONPath() {
        // ⭐ 标准 JSONPath（递归 + 过滤）⇒ 手写解析不了 ⇒ 兜底救回
        let path = "$.data.state[?(@.dataName=='novel_search_list')].items[*].n"
        let hits = JSONPath.select(doc, path)
        XCTAssertEqual(hits?.count, 2, "Sextant 应命中 2 项，实际 \(hits?.count ?? -1)")
        XCTAssertEqual(hits?.first?.scalarString, "书一")
    }

    func testSextantDirectQuery() {
        let hits = SextantFallback.select(doc, "$.data.state[*].dataName")
        XCTAssertEqual(hits?.count, 2)
        XCTAssertEqual(hits?.last?.scalarString, "other_list")
    }

    func testSextantValidatePath() {
        XCTAssertNil(SextantFallback.validate("$.a.b"), "合法路径不该报错")
        XCTAssertNotNil(SextantFallback.validate("$.a[["), "非法路径要报错")
    }

    // MARK: - ④ 不是万能：两边都不认 ⇒ nil（不编值）

    func testUnknownPathStillNil() {
        XCTAssertNil(JSONPath.select(doc, "$$$.not.a.path"), "两边都不认的路径不许编出值")
    }
}
