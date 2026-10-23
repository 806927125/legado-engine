import Foundation
import LegadoCore
import AnalyzeUrlReference
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

// ⭐ `--bench` 模式：量 AST 缓存的收益（§S-EVAL-11）
if CommandLine.arguments.contains("--bench") {
    let rules = [
        "class.book@tag.a@text", "class.booklist@tag.li@text", "$.data.bookList",
        "//div[@class='x']/p", "tag.h1@ownText", "##(\\d+)##$1##",
    ]
    let n = 20_000
    let plain = RuleParser()
    var t0 = Date()
    var sink = 0
    for _ in 0..<n { for r in rules { sink &+= describeValue2(plain.parse(r)).count } }
    let plainTime = Date().timeIntervalSince(t0)
    let cache = RuleCache()
    let cached = RuleParser(cache: cache)
    t0 = Date()
    for _ in 0..<n { for r in rules { sink &+= describeValue2(cached.parse(r)).count } }
    let cachedTime = Date().timeIntervalSince(t0)
    print(String(format: "无缓存 %.3fs / 有缓存 %.3fs / 加速 %.1fx / 命中率 %.0f%% (sink=%d)",
                 plainTime, cachedTime, plainTime / max(cachedTime, 0.000001),
                 cache.stats.hitRate * 100, sink))
    exit(0)
}

// ⭐ `--bench-e2e` 模式：**端到端**阶段计时（真书源 + 真页面快照）
//
// ⇒ 目的：找性能瓶颈在【哪一段】（DOM 解析 / 规则求值 / 编排）
if CommandLine.arguments.contains("--bench-e2e") {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Conformance
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 根
        .appendingPathComponent("conformance/fixtures/e2e")

    final class FileTransport: HTTPTransport, @unchecked Sendable {
        let dir: URL
        let routes: [(String, String)]
        var requested: [String] = []
        init(dir: URL, routes: [(String, String)]) { self.dir = dir; self.routes = routes }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            requested.append(request.url)
            for (pat, file) in routes where request.url.contains(pat) {
                let data = try Data(contentsOf: dir.appendingPathComponent(file))
                return HTTPResponse(statusCode: 200, headers: [:], body: data, finalURL: request.url)
            }
            throw SourceError.requestFailed(request.url, "没有这个 fixture")
        }
    }

    let sourceData = try Data(contentsOf: root.appendingPathComponent("source-52dzxy.json"))
    let source = try JSONDecoder().decode(BookSource.self, from: sourceData)
    let transport = FileTransport(dir: root, routes: [
        ("/bkzs/all.html", "list.html"),
        ("/articles/", "chapter.html"),
        ("/202614/index.html", "detail.html"),
    ])
    let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))

    // ① ⭐ **DOM 解析单独计时**（HTML 解析通常是大头）
    let listHTML = try String(contentsOf: root.appendingPathComponent("list.html"), encoding: .utf8)
    var t = Date()
    for _ in 0..<20 {
        _ = try SwiftSoupDocument(html: listHTML, baseURL: "https://x.example/")
    }
    let domTime = Date().timeIntervalSince(t) / 20
    print(String(format: "① DOM 解析（list.html %d 字节）= %.3f ms/次", listHTML.utf8.count, domTime * 1000))

    // ①' ⭐ **细分：SwiftSoup 解析 vs 我们的包装 vs DOM 查询**
    do {
        var t1 = Date()
        for _ in 0..<20 { _ = try SwiftSoupDocument(html: listHTML, baseURL: "https://x.example/") }
        let wrapped = Date().timeIntervalSince(t1) / 20
        // ⭐ DOM 查询：一次「取全部 book 节点」的成本
        let doc = try SwiftSoupDocument(html: listHTML, baseURL: "https://x.example/").document
        t1 = Date()
        for _ in 0..<20 { _ = doc.queryAll("div.book") }
        let query = Date().timeIntervalSince(t1) / 20
        print(String(format: "   我们的包装（SwiftSoupDocument）= %.3f ms", wrapped * 1000))
        print(String(format: "   一次 queryAll 遍历 = %.3f ms", query * 1000))
        // ⭐⭐ **一次「相对节点」的字段规则求值**（这才是 480 次的成本）
        // ⭐ 用**这个源真实的选择器**来测
        let nodes = doc.queryAll(".magazine-grid .magazine-item")
        print("     ⇒ 列表节点 \(nodes.count) 个")
        if let n0 = nodes.first { let n = DOMNodeRef(n0)
            let ev = Evaluator()
            let ctx = EvalContext(base: .element(n), baseUrl: "https://x.example/")
            var t2 = Date()
            for _ in 0..<50 { _ = ev.evalOne("a@text", base: .element(n), ctx: ctx) }
            let oneText = Date().timeIntervalSince(t2) / 50
            t2 = Date()
            for _ in 0..<50 { _ = ev.evalOne("a@href", base: .element(n), ctx: ctx) }
            let oneHref = Date().timeIntervalSince(t2) / 50
            t2 = Date()
            for _ in 0..<50 { _ = n.node.queryAll("a") }
            let oneQuery = Date().timeIntervalSince(t2) / 50
            print(String(format: "   一次相对求值 a@text = %.4f ms / a@href = %.4f ms / 只查 a = %.4f ms",
                         oneText * 1000, oneHref * 1000, oneQuery * 1000))
            print(String(format: "   ⇒ 60 本 × 2 字段 = %.1f ms（现状）；若共用选择器 ≈ %.1f ms",
                         (oneText + oneHref) * 60 * 1000, (oneText + oneHref - oneQuery) * 60 * 1000))
            // ⭐⭐ **逐段拆**：parse（缓存命中）/ classify / 链求值 / 取值
            let ast = ev.parser.parse("a@text", isJSON: false)
            var t3 = Date()
            for _ in 0..<200 { _ = ev.parser.parse("a@text", isJSON: false) }
            let parseCost = Date().timeIntervalSince(t3) / 200
            t3 = Date()
            for _ in 0..<200 { _ = RuleClassifier.classify("a@text", isJSON: false) }
            let classifyCost = Date().timeIntervalSince(t3) / 200
            t3 = Date()
            for _ in 0..<200 { _ = ev.parser.parse("a@text", isJSON: false) }
            let parseCost2 = Date().timeIntervalSince(t3) / 200
            print(String(format: "   parse(缓存命中) = %.4f ms / classify = %.4f ms / 再 parse = %.4f ms",
                         parseCost * 1000, classifyCost * 1000, parseCost2 * 1000))
            // ⭐⭐ **textContent 的成本**（SwiftSoup 的 text() 每次都遍历整棵子树）
            if let a0 = n.node.queryAll("a").first {
                var t4 = Date()
                for _ in 0..<200 { _ = a0.textContent }
                let textCost = Date().timeIntervalSince(t4) / 200
                t4 = Date()
                for _ in 0..<200 { _ = a0.outerHTML }
                let htmlCost = Date().timeIntervalSince(t4) / 200
                print(String(format: "   ⭐ textContent = %.4f ms / outerHTML = %.4f ms",
                             textCost * 1000, htmlCost * 1000))
            }
            // ⭐⭐ **逐个测「胶水」**（evalOne 里除 parse/resolve/取值 之外的部分）
            func cost(_ n: Int, _ label: String, _ f: () -> Void) {
                let t = Date()
                for _ in 0..<n { f() }
                print(String(format: "     %@ = %.4f ms", label, Date().timeIntervalSince(t) / Double(n) * 1000))
            }
            var tmpCtx = ctx
            cost(500, "VarStore.apply", { _ = VarStore.apply("a@text", ctx: &tmpCtx) })
            cost(500, "splitRuleLines", { _ = Evaluator.splitRuleLines("a@text") })
            cost(500, "TemplateEngine.render", { _ = TemplateEngine.render("a@text", ctx: ctx) })
            cost(500, "ValueMode.fromAttributeName", { _ = ValueMode.fromAttributeName("text") })
            cost(500, "EngineDiagnostic(rule:)", { _ = EngineDiagnostic(rule: "a@text") })
            let rc = RuleCache()
            _ = rc.cached(for: RuleCache.Key(rule: "a@text", isJSON: false))
            cost(500, "cache.cached(for:)", { _ = rc.cached(for: RuleCache.Key(rule: "a@text", isJSON: false)) })
            let k2 = RuleCache.Key(rule: "a@text", isJSON: false)
            cost(500, "Key 构造 + cached", { _ = rc.cached(for: RuleCache.Key(rule: "a@text", isJSON: false)) })
            // 链求值（不含取值）
            if case .chain(let h, let hi, let steps) = ast {
                t3 = Date()
                for _ in 0..<200 { _ = LegadoSelector.resolve(root: n.node, head: h, headIndex: hi, steps: steps) }
                let chainCost = Date().timeIntervalSince(t3) / 200
                print(String(format: "   链求值 resolve = %.4f ms", chainCost * 1000))
            } else {
                print("   AST 不是 chain：\(ast)")
            }
        }
    }

    // ② 各阶段
    func timed<T>(_ label: String, _ body: () throws -> T) throws -> T {
        let t0 = Date()
        let r = try body()
        print(String(format: "  %@ = %.3f ms", label, Date().timeIntervalSince(t0) * 1000))
        return r
    }

    let cats = try timed("categories（解析 exploreUrl）") { try engine.categories() }
    let target = cats.first { $0.title.contains("百科知识") } ?? cats[0]
    let books = try timed("explore（列表页：fetch+DOM+每本 8 个字段规则）") {
        try engine.explore(target.url)
    }
    print("     ⇒ \(books.count) 本书")
    let info = try timed("bookInfo（详情页）") { try engine.bookInfo(books[0]) }
    let chapters = try timed("toc（目录页 + 每章 3 个规则）") { try engine.toc(info) }
    print("     ⇒ \(chapters.count) 章")
    let article = chapters.first { !$0.isVolume && !$0.url.isEmpty }!
    try timed("content（正文页）") { try engine.content(article) }

    // ③ ⭐ 规则求值次数（推算总开销）
    print("     ⇒ 字段规则求值次数 ≈ \(books.count * 8) + \(chapters.count * 3)")

    // ④ 再跑一遍（热缓存：AST 缓存命中）
    print("--- 第二轮（AST 缓存已热）---")
    _ = try timed("explore") { try engine.explore(target.url) }
    exit(0)
}

// ⭐ `--live <pack.json> [N]` 模式：**真实站点活体验证**（真网络 + 真引擎）
//
// ⇒ 验的是「真书源 + 真实站方页面」能不能跑通「发现 → 详情 → 目录 → 正文」
// ⇒ ⚠️ 站方可能限流/改版 ⇒ 逐个源独立跑、逐阶段记录（不因一个源失败而中断）
if let li = CommandLine.arguments.firstIndex(of: "--live") {
    let packPath = CommandLine.arguments.count > li + 1 ? CommandLine.arguments[li + 1] : ""
    let limit = CommandLine.arguments.count > li + 2 ? (Int(CommandLine.arguments[li + 2]) ?? 5) : 5
    let packData = try Data(contentsOf: URL(fileURLWithPath: packPath))
    let pack = try JSONDecoder().decode([BookSource].self, from: packData)
    let transport = URLSessionTransport()
    var ok = 0, fail = 0
    var tried = 0
    for src in pack {
        guard tried < limit else { break }
        // 只挑「有 exploreUrl 且看起来还活着」的源
        guard let eu = src.exploreUrl, !eu.isEmpty else { continue }
        tried += 1
        let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: transport))
        var line = "【\(src.bookSourceName)】"
        do {
            let cats = try engine.categories()
            guard let cat = cats.first(where: { $0.url.contains("{{page}}") }) ?? cats.first else {
                line += " 分类空"; print(line); fail += 1; continue
            }
            let books = try engine.explore(cat.url)
            line += " 分类\(cats.count)"
            guard let b = books.first else { line += " 书0"; print(line); fail += 1; continue }
            line += " 书\(books.count)"
            let info = try engine.bookInfo(b)
            line += " 详情(\(info.name.prefix(10)))"
            let chapters = try engine.toc(info)
            line += " 章\(chapters.count)"
            if let ch = chapters.first(where: { !$0.isVolume && !$0.url.isEmpty }) {
                let text = try engine.content(ch)
                line += " 正文\(text.count)字"
            }
            line += " ✅"
            ok += 1
        } catch {
            line += " ❌ \(error)"
            fail += 1
        }
        print(line)
        fflush(stdout)
    }
    print("── 活体：成功 \(ok) / 失败 \(fail) / 共试 \(tried)")
    exit(0)
}

// ⭐ `--audit <pack.json>` 模式：125 源规则覆盖体检（用真引擎逐条解析）
if let idx = CommandLine.arguments.firstIndex(of: "--audit") {
    let pack = idx + 1 < CommandLine.arguments.count
        ? CommandLine.arguments[idx + 1]
        : "/workspace/out/pack125.json"
    var out: String? = nil
    if let oi = CommandLine.arguments.firstIndex(of: "--out"), oi + 1 < CommandLine.arguments.count {
        out = CommandLine.arguments[oi + 1]
    }
    RuleAudit.run(packPath: pack, outPath: out)
    exit(0)
}

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

// ⭐ **JS 后端**（有 JSC 的平台 = macOS）⇒ `js-pure` 用例能跟轻阅的 JS 引擎逐字对拍
//    （Linux 上没有 JSC ⇒ nil ⇒ 那类用例跳过）
let jsBackend: JSExecutor? = {
    #if canImport(JavaScriptCore)
    return JSCExecutor(api: MinimalHostAPI())
    #else
    return nil
    #endif
}()

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

    // ⭐ **requires 门槛**
    // ① `requires: "js"` —— 需要**宿主 API**（`java.*` / `source.*`）的 JS 用例
    //    ⇒ 宿主还没实现 ⇒ **两边都跳过**，不算差异
    if let req = c["requires"] as? String, req == "js" {
        emit(id, kind, "SKIPPED", "SKIPPED")
        continue
    }
    // ② ⭐ `requires: "js-pure"` —— **纯 JS 计算**（不碰宿主 API）
    //    ⇒ JS 侧（轻阅引擎）照跑；Swift 侧在**有 JSC 后端**时（macOS）也跑 ⇒ **逐字对拍**
    //    ⇒ Linux 上没有 JSC ⇒ 跳过（记进「只有一边能跑」）
    let isJSPure = (c["requires"] as? String) == "js-pure"
    if isJSPure && jsBackend == nil {
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

    case "urlRule":
        // URL 规则对拍：自研 URLBuilder vs 参考实现（轻阅 AnalyzeUrl.swift）
        let rule = c["rule"] as? String ?? ""
        let baseUrl = c["baseUrl"] as? String ?? ""
        let mine = URLBuilder.parse(rule, baseUrl: baseUrl)
        let ref = AnalyzeUrl.parse(rule, baseUrl: baseUrl)
        let exp = expect
        var expParts: [String] = []
        var actParts: [String] = []
        func add(_ k: String, _ e: Any?, _ a: Any?) {
            guard let e = e else { return }
            expParts.append("\(k)=\(jsonAnyString(e))")
            actParts.append("\(k)=\(jsonAnyString(a ?? ""))")
        }
        add("method", exp["method"], mine.method)
        add("body", exp["body"], mine.body)
        add("url", exp["url"], mine.url)
        if let ct = exp["contentType"] as? String {
            expParts.append("ct=\(jsonAnyString(ct))")
            let got = mine.headers.first { $0.key.lowercased() == "content-type" }?.value ?? ""
            actParts.append("ct=\(jsonAnyString(got))")
        }
        for (k, v) in (exp["headers"] as? [String: String] ?? [:]) {
            expParts.append("h.\(k)=\(jsonAnyString(v))")
            let got = mine.headers.first { $0.key.lowercased() == k.lowercased() }?.value ?? ""
            actParts.append("h.\(k)=\(jsonAnyString(got))")
        }
        // ⭐ 同时把**参考实现**的结果算进去 —— 两边都跟「规格期望」一致才算过
        //    （若 ref ≠ mine ⇒ 说明自研实现与参考实现有语义差异 ⇒ 要人看一眼）
        let refSame = (ref.method == mine.method) && (ref.body == mine.body) && (ref.url == mine.url)
        if !refSame {
            let refDesc = "method=\(jsonAnyString(ref.method)),body=\(jsonAnyString(ref.body)),url=\(jsonAnyString(ref.url))"
            let mineDesc = "method=\(jsonAnyString(mine.method)),body=\(jsonAnyString(mine.body)),url=\(jsonAnyString(mine.url))"
            FileHandle.standardError.write(("DIVERGE \(id) ref=" + refDesc + " mine=" + mineDesc + "\n").data(using: .utf8)!)
        }
        emit(id, kind, expParts.joined(separator: ","), actParts.joined(separator: ","))

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
        let ev = Evaluator(js: jsBackend)
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
    case .value(let mode): return "value(\(mode))"
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


/// AST 的稳定描述（benchmark 用；与 conformance 的 describeValue 同构）
func describeValue2(_ n: RuleNode) -> String {
    switch n {
    case .empty: return "e"
    case .value(let mode): return "v(\(mode))"
    case .literal(let s): return "l\(s)"
    case .css(let s): return "c\(s)"
    case .xpath(let s): return "x\(s)"
    case .jsonPath(let s): return "j\(s)"
    case .regex(let p, let r): return "r\(p)\(r.count)"
    case .js(let s): return "s\(s)"
    case .jsWithTail(let c, let t): return "w\(c)\(t ?? "-")"
    case .reparse(let i): return "p\(describeValue2(i))"
    case .template(let s): return "t\(s)"
    case .fallback(let xs): return "f" + xs.map(describeValue2).joined(separator: ",")
    case .concat(let xs): return "k" + xs.map(describeValue2).joined(separator: ",")
    case .alternatives(let xs): return "a" + xs.map(describeValue2).joined(separator: ",")
    case .chain(let h, let hi, let st): return "n\(h)\(hi.map(String.init) ?? "-")\(st.count)"
    case .post(let i, _): return "o\(describeValue2(i))"
    }
}
