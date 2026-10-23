import Foundation
import LegadoCore

/// **规则覆盖体检** —— 用 125 源包（真实书源语料）量一遍「引擎到底支持到哪」。
///
/// ⭐ **为什么要做这个**：
/// 之前的推进都是「照着规格写」⇒ 规格覆盖了**我们想到的**语义，
/// 但**没覆盖站方真的在用的**写法。
/// ⇒ 拿 125 个真书源当语料 ⇒ **用真引擎逐条解析** ⇒ 解析不了的 = 真缺口。
///
/// ⭐ **体检用的是真引擎**（`RuleParser` / `XPathEngine` / `JSONPath`），
/// 不是正则扫描 ⇒ 结论是**实证**的，不是猜的。
///
/// 跑法：`swift run conformance --audit <pack125.json> [--out report.json]`
enum RuleAudit {

    // MARK: - 缺口类型

    struct Gap {
        enum Kind: String, CaseIterable {
            /// 需要 JS 后端（`@js:` / `<js>…</js>`）—— 引擎能解析，但**跑不了**
            case jsBackendNeeded = "需要 JS 后端"
            /// XPath 语法引擎不支持
            case xpathUnsupported = "XPath 语法不支持"
            /// JSONPath 语法引擎不支持
            case jsonPathUnsupported = "JSONPath 语法不支持"
            /// 规则非空，但解析结果是空的（引擎读不懂）
            case parseEmpty = "规则解析不出内容"
            /// 整条像取值模式，但取值模式不认识
            case unknownValueMode = "未知取值模式"
            /// **路径 + 尾部 `<js>` 块**的复合形态（引擎不认）
            case jsBlockTail = "路径 + <js> 块（复合形态）"
        }
        var kind: Kind
        var source: String
        var field: String
        var rule: String
        var detail: String = ""
    }

    struct SourceReport {
        var name: String
        var group: String
        var ruleCount: Int = 0
        var jsRules: Int = 0
        var gaps: [Gap] = []
    }

    struct Report {
        var sources: Int = 0
        var totalRules: Int = 0
        var byMode: [String: Int] = [:]
        var byAST: [String: Int] = [:]
        /// 子语法分布（一条规则可命中多个）
        var byFeature: [String: Int] = [:]
        var gaps: [Gap] = []
        var perSource: [SourceReport] = []
        /// 「这个源的全部规则都能被引擎读懂」吗
        var cleanSources: Int = 0
        var jsOnlySources: Int = 0
    }

    // MARK: - 入口

    static func run(packPath: String, outPath: String?) {
        guard let data = FileManager.default.contents(atPath: packPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            FileHandle.standardError.write("读不了书源包: \(packPath)\n".data(using: .utf8)!)
            exit(2)
        }

        let parser = RuleParser()
        var report = Report()
        report.sources = root.count

        // 测 XPath 语法用的最小 DOM（只关心「语法能不能解析」，不关心命中什么）
        let probeDOM: DOMNode? = {
            let html = "<html><body><div class='c' id='i'><p>1</p><span>2</span></div>"
                + "<ul><li>a</li><li>b</li></ul><table><tr><td>c</td></tr></table></body></html>"
            return try? SwiftSoupDocument(html: html, baseURL: "https://x/").document
        }()

        for src in root {
            let name = src["bookSourceName"] as? String ?? "(未命名)"
            let group = src["bookSourceGroup"] as? String ?? ""
            var sr = SourceReport(name: name, group: group)

            // 遍历所有 rule* 块里的字符串值
            for (block, value) in src {
                guard block.hasPrefix("rule"), let fields = value as? [String: Any] else { continue }
                for (field, raw) in fields {
                    guard let rule = raw as? String else { continue }
                    let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    sr.ruleCount += 1
                    report.totalRules += 1

                    // ① 模式分布（引擎自己的判定）
                    let mode = RuleClassifier.classify(trimmed, isJSON: false)
                    report.byMode[mode.rawValue, default: 0] += 1

                    // ② AST 顶层形态
                    //    ⚠️ **先剥 `@put:` / `@get:`**（引擎 evalOne 的第一步）⇒
                    //    否则 `$.bookName@put:{xid:x_id}` 会被当整串 JSONPath ⇒ **误报**
                    var probeCtx = EvalContext(base: .page(""))
                    let cleaned = VarStore.apply(trimmed, ctx: &probeCtx)
                    let ast = parser.parse(cleaned, isJSON: false)
                    report.byAST[astKind(ast), default: 0] += 1

                    // ③ 子语法分布
                    for (feature, hit) in features(in: trimmed) where hit {
                        report.byFeature[feature, default: 0] += 1
                    }

                    // ④ 缺口判定（**用真引擎跑**）
                    for gap in gaps(ast: ast, mode: mode, rule: cleaned,
                                    source: name, field: "\(block).\(field)",
                                    probeDOM: probeDOM) {
                        report.gaps.append(gap)
                        sr.gaps.append(gap)
                        if gap.kind == .jsBackendNeeded { sr.jsRules += 1 }
                    }
                }
            }
            if sr.gaps.isEmpty { report.cleanSources += 1 }
            if !sr.gaps.isEmpty && sr.gaps.allSatisfy({ $0.kind == .jsBackendNeeded }) {
                report.jsOnlySources += 1
            }
            report.perSource.append(sr)
        }

        // 输出
        printSummary(report)
        if let outPath {
            if let json = encode(report) {
                try? json.write(to: URL(fileURLWithPath: outPath), options: .atomic)
                print("\n报告已写: \(outPath)")
            }
        }
    }

    // MARK: - AST 形态

    static func astKind(_ n: RuleNode) -> String {
        switch n {
        case .empty: return "empty"
        case .literal: return "literal"
        case .css: return "css"
        case .xpath: return "xpath"
        case .jsonPath: return "jsonPath"
        case .regex: return "regex"
        case .js: return "js"
        case .jsWithTail(_, let tail): return tail == nil ? "js" : "jsWithTail"
        case .reparse: return "reparse"
        case .template: return "template"
        case .fallback: return "fallback(||)"
        case .concat: return "concat(&&)"
        case .alternatives: return "alternatives(,)"
        case .chain: return "chain"
        case .post: return "post"
        case .value: return "value(取值模式)"
        }
    }

    // MARK: - 子语法

    /// 规则里出现过的**子语法**（一条规则可命中多个）
    static func features(in rule: String) -> [(String, Bool)] {
        [
            ("@put: 变量写入", rule.contains("@put:")),
            ("@get: 变量读取", rule.contains("@get:")),
            ("{{}} 模板插值", rule.contains("{{")),
            ("## 正则", rule.contains("##")),
            ("|| 择一", rule.contains("||")),
            ("&& 串接", rule.contains("&&")),
            (", 多规则", rule.contains(",")),
            ("换行多规则", rule.contains("\n")),
            ("!N 排除", rule.contains("!")),
            ("text. 文本相等", rule.contains("text.")),
            ("@css: 显式CSS", rule.lowercased().contains("@css:")),
            ("@json: 显式JSON", rule.lowercased().contains("@json:")),
            ("@xpath: 显式XPath", rule.lowercased().contains("@xpath:")),
            ("@js: 站方JS", rule.lowercased().hasPrefix("@js:")),
            ("<js> 块", rule.contains("<js>") || rule.contains("<JS>")),
            ("整条=取值模式", RuleParser.valueMode(of: rule) != nil),
        ]
    }

    // MARK: - 缺口判定

    /// **选择器类字段** —— 只有这些字段的规则才可能是 XPath / JSONPath。
    ///
    /// ⚠️ `bookUrl` / `tocUrl` / `chapterUrl` / `coverUrl` / `nextTocUrl` … 是 **URL 字段**
    ///    （站方可能写 `/books?bookId={$.bookId}` 这种 URL 模板）
    ///    ⇒ 拿 XPath/JSONPath 语法去套它们 ⇒ **全是误报** ⭐
    static let selectorFields: Set<String> = [
        "name", "author", "kind", "intro", "lastChapter", "wordCount",
        "bookList", "chapterList", "chapterName", "content",
        "isVolume", "isVip", "updateTime",
    ]

    static func gaps(ast: RuleNode, mode: RuleMode, rule: String, source: String,
                     field: String, probeDOM: DOMNode?) -> [Gap] {
        var out: [Gap] = []

        func add(_ kind: Gap.Kind, _ detail: String = "") {
            out.append(Gap(kind: kind, source: source, field: field, rule: rule, detail: detail))
        }

        switch ast {
        case .js:
            add(.jsBackendNeeded, "站方 JS：引擎能解析，但没有 JS 运行时")
        case .jsWithTail(_, let tail):
            add(.jsBackendNeeded, tail == nil
                ? "站方 JS 块（无尾部选择器）"
                : "站方 JS 块 + 尾部选择器 \(tail!)")
        case .xpath(let expr):
            // ⚠️ 只有**选择器字段**才按 XPath 语法判（URL 字段是 URL 模板，不是选择器）
            if let short = field.split(separator: ".").last, selectorFields.contains(String(short)) {
                if let probeDOM, XPathEngine.select(probeDOM, expr) == nil {
                    add(.xpathUnsupported, expr)
                }
            }
        case .jsonPath(let path):
            if let short = field.split(separator: ".").last, selectorFields.contains(String(short)) {
                if JSONPath.select(.object([:]), path) == nil {
                    // ⭐ 分辨两种情况：
                    // ① 路径后面**接了 `<js>` 块** ⇒ 站方要的复合形态（引擎不认）
                    // ② 路径语法真的不支持
                    if path.contains("<js>") || path.contains("<JS>") {
                        add(.jsBlockTail, "路径 + 尾部 <js> 块")
                    } else {
                        add(.jsonPathUnsupported, path)
                    }
                }
            }
        case .empty:
            // ⚠️ 「纯副作用规则」（整条只有 @put/@get）⇒ **不是缺口**，是站方写法
            //    引擎的诊断已经单独标成「副作用规则（不产出值）」⇒ 这里不报
            if rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            add(.parseEmpty, "mode=\(mode.rawValue)")
        case .value(let m):
            if ValueMode.fromAttributeName(m) == nil {
                add(.unknownValueMode, m)
            }
        default:
            break
        }
        return out
    }

    // MARK: - 输出

    static func printSummary(_ r: Report) {
        print("═══ Legado 规则覆盖体检 ═══")
        print("书源数：\(r.sources)   规则条数：\(r.totalRules)")
        print("全部规则都能被引擎读懂的源：\(r.cleanSources) / \(r.sources)")
        print("只差 JS 后端（其它都懂）的源：\(r.jsOnlySources)")

        print("\n【模式分布】（引擎自己的判定）")
        for (k, v) in r.byMode.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-10@ %5d  %5.1f%%", k as NSString, v,
                         Double(v) / Double(max(r.totalRules, 1)) * 100))
        }

        print("\n【AST 顶层形态分布】")
        for (k, v) in r.byAST.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-18@ %5d  %5.1f%%", k as NSString, v,
                         Double(v) / Double(max(r.totalRules, 1)) * 100))
        }

        print("\n【子语法分布】（一条规则可命中多个）")
        for (k, v) in r.byFeature.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-20@ %5d", k as NSString, v))
        }

        print("\n【缺口】")
        var byKind: [Gap.Kind: Int] = [:]
        for g in r.gaps { byKind[g.kind, default: 0] += 1 }
        if r.gaps.isEmpty {
            print("  ✅ 没有缺口")
        } else {
            for (k, v) in byKind.sorted(by: { $0.value > $1.value }) {
                print("  \(k.rawValue)：\(v)")
            }
            // 非 JS 后端的缺口要列细节（那些是「语义没覆盖」）
            let real = r.gaps.filter { $0.kind != .jsBackendNeeded }
            if !real.isEmpty {
                print("\n  ── 需要人工看的缺口明细（最多 40 条）──")
                var seen = Set<String>()
                for g in real where seen.count < 40 {
                    let key = "\(g.kind.rawValue)|\(g.detail)"
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    print("  · [\(g.kind.rawValue)] \(g.source) / \(g.field)")
                    print("      规则：\(g.rule.count > 90 ? String(g.rule.prefix(90)) + "…" : g.rule)")
                    if !g.detail.isEmpty { print("      细节：\(g.detail)") }
                }
                if real.count > seen.count {
                    print("  …（还有 \(real.count - seen.count) 条同类）")
                }
            }
        }
    }

    // MARK: - JSON

    static func encode(_ r: Report) -> Data? {
        var top: [String: Any] = [
            "sources": r.sources,
            "totalRules": r.totalRules,
            "cleanSources": r.cleanSources,
            "jsOnlySources": r.jsOnlySources,
            "byMode": r.byMode,
            "byAST": r.byAST,
            "byFeature": r.byFeature,
        ]
        var gapArr: [[String: Any]] = []
        for g in r.gaps {
            gapArr.append(["kind": g.kind.rawValue, "source": g.source, "field": g.field,
                           "rule": g.rule.count > 400 ? String(g.rule.prefix(400)) + "…" : g.rule,
                           "detail": g.detail])
        }
        top["gaps"] = gapArr
        var srcArr: [[String: Any]] = []
        for s in r.perSource {
            srcArr.append(["name": s.name, "group": s.group, "rules": s.ruleCount,
                           "jsRules": s.jsRules, "gaps": s.gaps.count])
        }
        top["perSource"] = srcArr
        return try? JSONSerialization.data(withJSONObject: top,
                                          options: [.prettyPrinted, .sortedKeys])
    }
}
