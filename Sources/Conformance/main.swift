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

    // ⭐ **requires 门槛**：需要 JS 后端的用例（Phase 3 才接 JSC）⇒ 两边都跳过，不算差异
    if let req = c["requires"] as? String, req == "js" {
        emit(id, kind, "SKIPPED", "SKIPPED")
        continue
    }

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
        if case .chain(_, _, let cs) = node {
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

    case "diagnose":
        // 诊断对拍：规则 + 基准 ⇒ 结论分级 + 是不是真错误
        let rule = c["rule"] as? String ?? ""
        let base = buildRuleBase(c["base"], ctxSpec: c["ctx"] as? [String: Any] ?? [:])
        let ctx = buildEvalContext(c["ctx"] as? [String: Any] ?? [:], base: base)
        let ev = Evaluator()
        let e = ev.evalOne(rule, base: base, ctx: ctx)
        let expObj: [String: Any] = [
            "conclusion": expect["conclusion"] ?? "",
            "hard": expect["hard"] ?? false,
        ]
        let actObj: [String: Any] = [
            "conclusion": e.conclusion.rawValue,
            "hard": e.isHardFailure ? "1" : "0",
        ]
        emit(id, kind, jsonString(expObj), jsonString(actObj))

    case "evalOne", "getElements":
        // 求值对拍：规则 + 基准 + 上下文 ⇒ 值
        let rule = c["rule"] as? String ?? ""
        let base = buildRuleBase(c["base"], ctxSpec: c["ctx"] as? [String: Any] ?? [:])
        var ctx = buildEvalContext(c["ctx"] as? [String: Any] ?? [:], base: base)
        if let vars = (c["ctx"] as? [String: Any])?["vars"] as? [String: String] {
            ctx.vars = vars
        }
        let ev = Evaluator()
        let items: [RuleValue]
        if kind == "evalOne" {
            items = ev.evalOne(rule, base: base, ctx: ctx).value.items
        } else {
            items = ev.getElements(rule, base: base, ctx: ctx).value.items
        }
        let texts = items.map { describeValue($0) }
        emit(id, kind, comparePayload(expect: expect, texts: texts), actualPayload(expect: expect, texts: texts))

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
    case .chain(let head, let headIndex, let steps):
        return "chain[" + head + "|" + (headIndex.map(String.init) ?? "-") + "|" + steps.map(describeStep).joined(separator: ",") + "]"
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


// MARK: - 求值对拍辅助

/// 基准构造（跟 JS 侧对齐：JSON 基准 = 纯对象；HTML 基准 = DOM 文档）
func buildRuleBase(_ spec: Any?, ctxSpec: [String: Any]) -> RuleBase {
    guard let d = spec as? [String: Any] else { return .page("") }
    let type = d["type"] as? String ?? "json"
    switch type {
    case "json":  return .json(JSONValue.from(d["value"]))
    case "text":  return .page(d["value"] as? String ?? "")
    case "null":  return .json(.null)
    case "html":
        let html = d["value"] as? String ?? ""
        let baseUrl = ctxSpec["baseUrl"] as? String ?? "https://book.example.com/"
        if let doc = try? SwiftSoupDocument(html: html, baseURL: baseUrl) {
            return .page(html)
        }
        return .page(html)
    default: return .json(.null)
    }
}

/// 上下文构造
func buildEvalContext(_ spec: [String: Any], base: RuleBase) -> EvalContext {
    var ctx = EvalContext(base: base,
                          baseUrl: spec["baseUrl"] as? String ?? "https://book.example.com/",
                          raw: spec["raw"] as? String ?? "",
                          page: spec["page"] as? Int ?? 1,
                          key: spec["key"] as? String ?? "",
                          isJSON: spec["isJSON"] as? Bool ?? false)
    // 页面级基准 ⇒ 把 HTML 解析成 DOM 供选择器用
    if case .page(let html) = base {
        let doc = try? SwiftSoupDocument(html: html, baseURL: ctx.baseUrl)
        ctx.document = doc?.document
    }
    return ctx
}

/// 值的 JSON 描述（两边同构：字符串原样 / 对象 JSON 串 / 节点取文本）
func describeValue(_ v: RuleValue) -> String {
    switch v {
    case .void:      return ""
    case .string(let s): return s
    case .list(let items): return "[" + items.map(describeValue).joined(separator: ",") + "]"
    case .json(let j):
        switch j {
        case .object, .array: return jsonValueString(j)
        default: return j.scalarString
        }
    case .node(let n): return n.text
    }
}

/// JSONValue 的 JSON 串（键排序 ⇒ 逐字节可比）
func jsonValueString(_ j: JSONValue) -> String {
    switch j {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .string(let s): return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    case .array(let a): return "[" + a.map(jsonValueString).joined(separator: ",") + "]"
    case .object(let o):
        let keys = o.keys.sorted()
        return "{" + keys.map { "\"\($0)\":" + jsonValueString(o[$0]!) }.joined(separator: ",") + "}"
    }
}


// MARK: - 期望值/实际值同构

/// 期望值：按 expect 里**实际存在的键**挑出来，逐个转 JSON 串
func comparePayload(expect: [String: Any], texts: [String]) -> String {
    var parts: [String] = []
    for key in ["count", "texts", "value", "values", "contains"] {
        guard let v = expect[key] else { continue }
        if key == "contains" {
            // 期望侧固定 "1"（期望成立）⇒ 实际不含该子串时 actual 是 "" ⇒ 不等 ⇒ 失败
            parts.append("\"contains\":\"1\"")
            continue
        }
        parts.append("\(quoted(key)):" + jsonAnyString(v))
    }
    return "{" + parts.joined(separator: ",") + "}"
}

/// 实际值：按 expect 里**实际存在的键**算出来（同构 ⇒ 可逐字比对）
func actualPayload(expect: [String: Any], texts: [String]) -> String {
    var parts: [String] = []
    for key in ["count", "texts", "value", "values", "contains"] {
        guard expect[key] != nil else { continue }
        switch key {
        case "count":   parts.append("\(quoted(key)):" + String(texts.count))
        case "texts":   parts.append("\(quoted(key)):" + "[" + texts.map(quoted).joined(separator: ",") + "]")
        case "value":   parts.append("\(quoted(key)):" + quoted(texts.first ?? ""))
        case "values":  parts.append("\(quoted(key)):" + "[" + texts.map(quoted).joined(separator: ",") + "]")
        case "contains":parts.append("\(quoted(key)):" + quoted(texts.contains { $0.contains(expect[key] as? String ?? "") } ? "1" : ""))
        default: break
        }
    }
    return "{" + parts.joined(separator: ",") + "}"
}

/// 任意 JSON 值的字符串形式
func jsonAnyString(_ v: Any) -> String {
    switch v {
    // ⚠️ **不要在这里加 Bool 分支** —— JSONSerialization 给的是 NSNumber，
    //    它既能 cast 成 Bool 又能 cast 成 Int ⇒ Bool 分支会抢走 Int 的值（count 变成 true）
    case let n as Int:    return String(n)
    case let b as Bool:   return b ? "true" : "false"
    case let s as String: return quoted(s)
    case let a as [Any]:
        return "[" + a.map { jsonAnyString($0) }.joined(separator: ",") + "]"
    case let d as [String: Any]:
        let keys = d.keys.sorted()
        return "{" + keys.map { quoted($0) + ":" + jsonAnyString(d[$0]!) }.joined(separator: ",") + "}"
    default: return quoted(String(describing: v))
    }
}

/// JSON 字符串转义
func quoted(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
}
