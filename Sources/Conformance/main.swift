import Foundation
import LegadoCore
import Foundation

// ===============================================================
// **双实现对拍运行器**（Swift 侧）
//
// 跑法：swift run conformance <fixture.json>
//
// 输出：每行一个 JSON —— `{"id":…,"kind":…,"expected":…,"actual":…,"ok":…}`
// ⇒ 与 `conformance/js-runner.js` 输出**同构** ⇒ 可以直接 diff。
//
// ⭐ 这是本项目的工作流核心：
//   同一份 fixture ⇒ Swift 新实现 与 JS 参考实现 各跑一遍 ⇒ **差异 = 债**。
//   （规范见 docs/legado-semantics.md）
// ===============================================================

let fixturePath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "conformance/fixtures/semantics-cases.json"

guard let data = FileManager.default.contents(atPath: fixturePath),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let cases = root["cases"] as? [[String: Any]] else {
    FileHandle.standardError.write("读不了 fixture: \(fixturePath)\n".data(using: .utf8)!)
    exit(2)
}

let parser = RuleParser()
var out: [String] = []
var pass = 0, fail = 0

func emit(_ id: String, _ kind: String, _ expected: Any, _ actual: Any) {
    let ok = String(describing: expected) == String(describing: actual)
    ok ? (pass += 1) : (fail += 1)
    let obj: [String: Any] = ["id": id, "kind": kind, "expected": expected, "actual": actual, "ok": ok]
    let enc = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    out.append(String(decoding: enc, as: UTF8.self))
}

for c in cases {
    guard let id = c["id"] as? String else { continue }
    let kind = c["kind"] as? String ?? ""
    let expect = (c["expect"] as? [String: Any]) ?? [:]
    let ctx = (c["ctx"] as? [String: Any]) ?? [:]
    let isJSON = (ctx["isJSON"] as? Bool) ?? false

    switch kind {
    case "classify":
        let rule = c["rule"] as? String ?? ""
        let actual = RuleClassifier.classify(rule, isJSON: isJSON).rawValue
        emit(id, kind, expect["kind"] as? String ?? "", actual)

    case "chainSegment":
        // 链段分类（§S-SEL-03~06）—— 本项目最关键的一条判定
        // 输出：每段是 "sub"（子选择器）还是 "attr"（属性后缀），逗号分隔
        let rule = c["rule"] as? String ?? ""
        let node = parser.parse(rule, isJSON: isJSON)
        var steps: [String] = []
        if case .chain(_, let cs) = node {
            steps = cs.map { s -> String in
                if case .sub = s { return "sub" } else { return "attr" }
            }
        }
        emit(id, kind, expect["steps"] as? String ?? "", steps.joined(separator: ","))

    case "headCss":
        // 头段翻译结果（prefixToCss 语义）
        let rule = c["rule"] as? String ?? ""
        let (spec, _) = HeadTranslator.translate(rule)
        emit(id, kind, expect["css"] as? String ?? "", spec.cssLike)

    case "parse":
        // 整条规则解析成什么 AST（快照式比对）
        let rule = c["rule"] as? String ?? ""
        let node = parser.parse(rule, isJSON: isJSON)
        emit(id, kind, expect["ast"] as? String ?? "", describe(node))

    case "domSelect":
        // 行为对拍：HTML + 规则 ⇒ 节点数 + 每个节点的文本
        let html = c["html"] as? String ?? ""
        let rule = c["rule"] as? String ?? ""
        let baseUrl = (c["baseUrl"] as? String) ?? "https://book.example.com/"
        var texts: [String] = []
        if let doc = try? SwiftSoupDocument(html: html, baseURL: baseUrl) {
            let nodes = LegadoSelector.select(root: doc.document, rule: rule)
            texts = nodes.map { $0.textContent }
        }
        let expObj: [String: Any] = [
            "count": expect["count"] ?? NSNull(),
            "texts": expect["texts"] as? [String] ?? [],
        ]
        let actObj: [String: Any] = ["count": texts.count, "texts": texts]
        emit(id, kind, jsonString(expObj), jsonString(actObj))

    default:
        // 其余 kind（evalOne / getElements / jsScope / parse）需要 DOM / JS 后端，
        // 属于后续切片 —— 两边都标 SKIPPED（保持对拍同构）。
        emit(id, kind, "SKIPPED", "SKIPPED")
    }
}

out.forEach { print($0) }
FileHandle.standardError.write("Swift 侧：通过 \(pass) / 不符合 \(fail)\n".data(using: .utf8)!)

// MARK: - AST 描述（给对拍用的稳定文本形式）

func describe(_ n: RuleNode) -> String {
    switch n {
    case .empty: return "empty"
    case .literal(let s): return "literal(\(s))"
    case .css(let s): return "css(\(s))"
    case .xpath(let s): return "xpath(\(s))"
    case .jsonPath(let s): return "jsonpath(\(s))"
    case .regex(let p, let r): return "regex(\(p)|\(r.count))"
    case .js(let s): return "js(\(s))"
    case .jsWithTail(let c, let t): return "jsWithTail(\(c)|\(t ?? "-"))"
    case .reparse(let inner): return "reparse(\(describe(inner)))"
    case .template(let s): return "template(\(s))"
    case .fallback(let xs): return "fallback[\(xs.map(describe).joined(separator: ","))]"
    case .concat(let xs): return "concat[\(xs.map(describe).joined(separator: ","))]"
    case .alternatives(let xs): return "alternatives[\(xs.map(describe).joined(separator: ","))]"
    case .chain(let head, let steps): return "chain[" + head + "|" + steps.map(describeStep).joined(separator: ",") + "]"
    case .post(let inner, let pst): return "post(\(describe(inner))|\(pst))"
    }
}


/// 单个链步的稳定描述（⚠️ 抽成独立函数 —— 字符串插值里放不了 `switch` 语句）
func describeStep(_ s: ChainStep) -> String {
    switch s {
    case .sub(let sel, let idx, let excl):
        return "sub:" + sel + ":idx=" + (idx.map(String.init) ?? "-") + ":excl=" + String(excl.count)
    case .attr(let n):
        return "attr:" + n
    }
}


// MARK: - 极简 JSON 序列化（Swift on Linux 没有 `JSON`）

/// 把 `[String: Any]`（值只可能是 Int / String / [String] / NSNull）序列化成 JSON 文本。
/// ⚠️ **只给对拍用** —— 键按字典序输出，保证两边逐字节可比。
func jsonString(_ obj: [String: Any]) -> String {
    let keys = obj.keys.sorted()
    let body = keys.map { "\"\($0)\":" + jsonValue(obj[$0]!) }.joined(separator: ",")
    return "{" + body + "}"
}

private func jsonValue(_ v: Any) -> String {
    switch v {
    case let n as Int: return String(n)
    case let s as String: return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    case let a as [String]: return "[" + a.map { jsonValue($0) }.joined(separator: ",") + "]"
    case is NSNull: return "null"
    default: return "\"\"\""
    }
}
