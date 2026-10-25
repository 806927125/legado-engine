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

/// ⭐⭐⭐⭐⭐ **有 JSC 就用 JSC**（macOS）—— 没有就返回 nil（Linux ⇒ 走 Node 后端）
func JSCExecutorIfAvailable() -> JSExecutor? {
    #if canImport(JavaScriptCore)
    return JSCExecutor(api: MinimalHostAPI())
    #else
    return nil
    #endif
}

// ===============================================================
// ⭐ `--crypto` 模式：直接调 Crypto（调试归一化/解码）
// ===============================================================
if CommandLine.arguments.contains("--crypto") {
    let s = CommandLine.arguments.last ?? ""
    print("norm: \(Crypto.b64Normalize(s))")
    print("dec : \(Crypto.base64Decode(s) ?? "nil")")
    print("hex : \(Crypto.hexDecodeToString(s) ?? "nil")")
    exit(0)
}

// ===============================================================
// ⭐⭐⭐⭐⭐ `--js` 模式：**执行任意 JS**（宿主 API / Java 兼容层都在）
//
// ⚠️ **为什么需要**（2026-10-25 老 JS 引擎物理删除）：
//   轻阅的门禁会 `win.eval("java.hexDecodeToString(…)")` 这种**直接调宿主 API**的 JS
//   ⇒ 自己 createContext ⇒ `java` 是 undefined ⇒ 全部失败 ⭐⭐⭐
//   ⇒ 所以：**交给引擎的 node 进程跑**（那儿有宿主壳 + 包装函数 + Java 兼容层）⭐⭐⭐
//
// 用法：`swift run conformance --js '<json>'`
//   json = {"code":"…", "base":"", "isJSON":false, "baseUrl":""}
//   输出：一行 JSON（`{"ok":true,"value":…,"text":…,"branch":…}`）
// ===============================================================
if let ji = CommandLine.arguments.firstIndex(of: "--js") {
    var payload = ji + 1 < CommandLine.arguments.count ? CommandLine.arguments[ji + 1] : "{}"
    // ⭐⭐⭐ **payload 也可以从【文件】读**（`.json` 后缀 ⇒ 当路径）⇒ 大 payload 不用塞命令行
    if payload.hasSuffix(".json"), let pd = try? Data(contentsOf: URL(fileURLWithPath: payload)) {
        payload = String(data: pd, encoding: .utf8) ?? payload
    }
    guard let d = payload.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        print("{\"ok\":false,\"error\":\"bad payload\"}")
        exit(2)
    }
    var code = obj["code"] as? String ?? ""
    // ⭐⭐⭐ **自动补 `@js:` 前缀**（2026-10-25 踩过）
    //   ⇒ 门禁的 `win.eval("java.xxx(…)")` 是**普通 JS** ⇒ 引擎当规则解析会走「默认规则链」⇒ 空 ⭐⭐⭐
    //   ⇒ 这里统一当 **JS** 求值 ⇒ 与门禁的语义一致 ⭐⭐⭐
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.hasPrefix("@js:") && !trimmed.hasPrefix("@JS:")
        && !trimmed.hasPrefix("<js>") && !trimmed.hasPrefix("<JS>") {
        code = "@js:" + code
    }
    let baseText = obj["base"] as? String ?? ""
    let baseType = obj["baseType"] as? String ?? "page"
    let isJSON = obj["isJSON"] as? Bool ?? false
    let raw = obj["raw"] as? String ?? baseText
    let baseUrl = obj["baseUrl"] as? String ?? ""
    let vars = obj["vars"] as? [String: String] ?? [:]

    let base: RuleBase
    switch baseType {
    case "json": base = .json(JSONValue.from(obj["baseJSON"] ?? [:]))
    default: base = .page(baseText)
    }
    // ⭐⭐⭐⭐⭐ **假服务器路由**（内联）⇒ 门禁能在沙盒测 `java.ajax` 语义
    //   （2026-10-25 老 JS 引擎物理删除 ⇒ 假服务器从 JS 层下沉到 transport 层）⭐⭐⭐
    let inlineRoutes = (obj["routes"] as? [[String: Any]]) ?? []
    var routeTransport: RouteTransport? = nil
    if !inlineRoutes.isEmpty {
        let rules = inlineRoutes.compactMap { d -> RouteTransport.Rule? in
            guard let m = d["match"] as? String else { return nil }
            return RouteTransport.Rule(match: m,
                                       status: d["status"] as? Int ?? 200,
                                       body: d["body"] as? String ?? "",
                                       headers: (d["headers"] as? [String: String]) ?? [:])
        }
        routeTransport = RouteTransport(rules: rules)
    }
    let ctx = EvalContext(base: base, baseUrl: baseUrl, raw: raw,
                          vars: vars, isJSON: isJSON)
    // ⭐⭐⭐ **引擎**（带假服务器）⇒ `java.ajax` 在沙盒能跑 ⭐⭐⭐
    let engine: SourceEngine? = {
        guard let srcDict = obj["source"] as? [String: Any],
              let srcData = try? JSONSerialization.data(withJSONObject: srcDict),
              let source = try? JSONDecoder().decode(BookSource.self, from: srcData) else { return nil }
        let jsBackend: JSExecutor?
        if let jsc = JSCExecutorIfAvailable() { jsBackend = jsc }
        else if NodeJSExecutor.isAvailable { jsBackend = try? NodeJSExecutor() }
        else { jsBackend = nil }
        let transport = routeTransport ?? (HTTPTransportShim.failing())
        let e = SourceEngine(source: source, fetcher: PageFetcher(transport: transport), js: jsBackend)
        if let lib = obj["jsLib"] as? String, !lib.isEmpty { try? e.loadJsLib(lib) }
        return e
    }()
    let ev: Evaluator
    if let jsc = JSCExecutorIfAvailable() {
        ev = Evaluator(js: jsc)
    } else if NodeJSExecutor.isAvailable {
        ev = Evaluator(js: try NodeJSExecutor())
    } else {
        print("{\"ok\":false,\"error\":\"本平台既没有 JSC 也没有 node\"}")
        exit(0)
    }
    // ⭐⭐⭐ **把引擎挂到 JS 后端** ⇒ `java.ajax` 走引擎（能打到假服务器）⭐⭐⭐
    if let engine {
        ev.js?.setEngineAPI({ method, args, base in engine.engineJava(method, args, base) })
    }
    // ⭐⭐⭐⭐⭐ **静态路由给 Node 后端** ⇒ `java.ajax` 能**同步**查表
    //   （2026-10-25：Node 的宿主往返是异步 ⇒ 同步包装函数拿不到结果 ⇒ 路由必须下沉到 JS 侧）⭐⭐⭐
    if let node = ev.js as? NodeJSExecutor, !inlineRoutes.isEmpty {
        node.setRoutes(inlineRoutes)
    }
    let e = ev.evalOne(code, base: base, ctx: ctx)
    var out: [String: Any] = [
        "ok": true,
        "value": e.value.jsonValue.foundationValue,
        "text": e.value.text,
        "branch": e.diagnostic.branch ?? "",
        "failure": e.diagnostic.failure.map { "\($0)" } ?? "",
    ]
    // ⭐⭐⭐ **请求记录**（门禁要看「发了哪几条」）⭐⭐⭐
    if let node = ev.js as? NodeJSExecutor, !inlineRoutes.isEmpty {
        out["requests"] = node.recordedRequests()
    } else if let rt = routeTransport {
        out["requests"] = rt.recorder.urls
    }
    let d2 = try! JSONSerialization.data(withJSONObject: out)
    print(String(data: d2, encoding: .utf8)!)
    exit(0)
}

// ===============================================================
// ⭐⭐⭐⭐⭐ `--analyzeUrl` 模式：**URL 规则解析**（老 JS 引擎物理删除后的门禁入口）
//
// ⚠️ **为什么需要**：轻阅的 `qiyue-parity` 门禁原本在 jsdom 里跑老引擎的
//   `QR.analyzeUrl(...)` ⇒ 老引擎删了 ⇒ 门禁的对象没了 ⇒ 改成**直接调新引擎**⭐⭐⭐
// 用法：`swift run conformance --analyzeUrl '<json>'`
//   json = {"url":"https://x.com/a,{...}", "baseUrl":""}
//   输出：一行 JSON（`{"ok":true,"url":…,"method":…,"body":…,"headers":{…}}`）
// ===============================================================
if let au = CommandLine.arguments.firstIndex(of: "--analyzeUrl") {
    let payload = au + 1 < CommandLine.arguments.count ? CommandLine.arguments[au + 1] : "{}"
    guard let d = payload.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        print("{\"ok\":false,\"error\":\"bad payload\"}")
        exit(2)
    }
    let url = obj["url"] as? String ?? ""
    let baseUrl = obj["baseUrl"] as? String ?? ""
    let t = URLBuilder.parse(url, baseUrl: baseUrl)
    var headers: [String: Any] = [:]
    for (k, v) in t.headers { headers[k] = v }
    let out: [String: Any] = [
        "ok": true, "url": t.url, "method": t.method,
        "body": t.body, "headers": headers,
    ]
    let d2 = try! JSONSerialization.data(withJSONObject: out)
    print(String(data: d2, encoding: .utf8)!)
    exit(0)
}

// ===============================================================
// ⭐⭐⭐⭐⭐ `--op` 模式：**跑完整 op 链**（假服务器 + 真引擎）
//
// ⚠️ **为什么需要**（2026-10-25 老 JS 引擎物理删除）：
//   轻阅有一批门禁原本**在 jsdom 里跑老引擎的完整链**（explore / bookInfo / toc）
//   ⇒ 老引擎删了 ⇒ 门禁的对象没了 ⇒ **覆盖就丢了** ⭐⭐⭐
//   ⇒ 现在：**直接跑新引擎**（本模式）⇒ 门禁继续有效，而且验的是**真正在跑的那份**⭐⭐⭐
//
// 用法：`swift run conformance --op '<json>'`
//   json = {"op":"explore", "source":{…}, "routes":[["匹配串","响应文件路径"]],
//           "dir":"假服务器目录", "kindUrl":"…"}
//   输出：一行 JSON（`{"ok":true, "books":[…], …}` 或 `{"ok":false,"error":"…"}`）
// ===============================================================
if let oi = CommandLine.arguments.firstIndex(of: "--op") {
    // ⭐⭐⭐ **支持从文件读 payload**（payload 可能很大 ⇒ 命令行放不下 ⇒ "Argument list too long"）
    var payload = oi + 1 < CommandLine.arguments.count ? CommandLine.arguments[oi + 1] : "{}"
    if payload.hasSuffix(".json"), let pd = try? Data(contentsOf: URL(fileURLWithPath: payload)) {
        payload = String(data: pd, encoding: .utf8) ?? payload
    }
    guard let d = payload.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        print("{\"ok\":false,\"error\":\"bad payload\"}")
        exit(2)
    }

    /// ⭐⭐⭐ **假服务器**（照抄 `--bench-e2e` 的 `FileTransport`）⇒ 全程离线 ⭐⭐⭐
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

    let op = obj["op"] as? String ?? "explore"
    let dir = URL(fileURLWithPath: (obj["dir"] as? String) ?? ".")
    // ⭐⭐⭐⭐⭐ **内联路由**（假服务器 ⇒ 门禁不用造 fixture 文件）
    //   （老门禁用 JS 层的 `nativeMock` ⇒ 现在必须下沉到 transport 层）⭐⭐⭐
    let inlineRoutes = (obj["routes"] as? [[String: Any]]) ?? []
    let fileRoutes = (obj["fileRoutes"] as? [[String]] ?? []).map { ($0[0], $0[1]) }
    let routes = fileRoutes
    guard let srcDict = obj["source"] as? [String: Any],
          let srcData = try? JSONSerialization.data(withJSONObject: srcDict),
          let source = try? JSONDecoder().decode(BookSource.self, from: srcData) else {
        print("{\"ok\":false,\"error\":\"source 解不开\"}")
        exit(2)
    }
    // ⭐ JS 后端：有 JSC 用 JSC，没有就用 Node（Linux 沙盒）⭐⭐⭐
    var jsBackend: JSExecutor?
    if let jsc = JSCExecutorIfAvailable() {
        jsBackend = jsc
    } else if NodeJSExecutor.isAvailable {
        jsBackend = try? NodeJSExecutor()
    }
    // ⭐⭐⭐ **transport**：有内联路由 ⇒ 用 `RouteTransport`；否则用文件 fixture
    var routeTransport: RouteTransport? = nil
    if !inlineRoutes.isEmpty {
        let rules = inlineRoutes.compactMap { d -> RouteTransport.Rule? in
            guard let m = d["match"] as? String else { return nil }
            return RouteTransport.Rule(match: m,
                                       status: d["status"] as? Int ?? 200,
                                       body: d["body"] as? String ?? "",
                                       headers: (d["headers"] as? [String: String]) ?? [:])
        }
        routeTransport = RouteTransport(rules: rules)
    }
    let transport: HTTPTransport = routeTransport ?? FileTransport(dir: dir, routes: routes)
    // ⭐⭐⭐⭐⭐ **宿主的存储 / cookie 罐**（登录链路要用）⭐⭐⭐⭐⭐
    //
    // ⚠️ **为什么要有**（2026-10-25 迁移门禁时实证）：
    //   · 站方的登录脚本要读 **登录信息**（`source.getLoginInfoMap()` ⇒ 表单值）
    //     和 **cookie**（`cookie.getCookie(url)` / `cookie.getKey(host, name)`）
    //   · 而它们分别住在**宿主的存储**和**宿主的 cookie 罐**里（真机 = UserDefaults / HTTPCookieStorage）
    //   · ⇒ 沙盒里也要有 ⇒ 这里给内存实现（与 App 侧的 `SourceStorage` / `AppCookieService` 同款）⭐⭐⭐
    let storage = MemoryStorage()
    if let srcDict = obj["source"] as? [String: Any] {
        if let li = srcDict["__loginInfo"] as? String, !li.isEmpty {
            storage.setString(li, forKey: SourceEngine.loginInfoKey)
        }
        if let lh = srcDict["__loginHeader"] as? String, !lh.isEmpty {
            storage.setString(lh, forKey: SourceEngine.loginHeaderKey)
        }
    }
    let cookieService = MemoryCookieService()
    // ⭐ cookie 快照（App 的 cookie 罐 ⇒ 引擎的罐）
    if let snap = obj["cookieSnapshot"] as? [String: String] {
        for (host, value) in snap { cookieService.setCookie(value, for: host) }
    }
    let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport), js: jsBackend,
                              storage: storage, cookies: cookieService)
    // ⭐⭐⭐⭐⭐ **站方变量 ⇒ 灌进引擎的变量盒**（App 侧 `seedVars` 同款）⭐⭐⭐⭐⭐
    if let srcDict = obj["source"] as? [String: Any],
       let text = srcDict["__variables"] as? String, !text.isEmpty,
       let data = text.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for (k, v) in parsed {
            if let s = v as? String { engine.varBox.set(k, s) }
            else if let n = v as? NSNumber { engine.varBox.set(k, n.stringValue) }
        }
    }
    // ⭐⭐⭐⭐⭐ **静态路由给 Node 后端** ⇒ `java.ajax` 能**同步**查表
    //   （Node 的宿主往返是异步 ⇒ 同步包装函数拿不到结果 ⇒ 路由必须下沉到 JS 侧）⭐⭐⭐
    if let node = jsBackend as? NodeJSExecutor, !inlineRoutes.isEmpty {
        node.setRoutes(inlineRoutes)
    }
    // ⭐⭐⭐⭐⭐ **宿主对象的状态 ⇒ 灌进 Node 后端**（`source.*` / `cookie.*` 的数据）⭐⭐⭐⭐⭐
    //
    // ⚠️ Node 后端**没法同步回调 Swift** ⇒ 宿主对象只能「Swift 灌数据 + JS 记写回」⭐
    //   ⇒ 这里灌的是：**站方变量 / 登录信息 / 登录头 / cookie 罐** ⭐
    func hostStatePayload() -> [String: Any] {
        var vars: [String: String] = [:]
        for (k, v) in engine.varBox.all { vars[k] = v }
        var loginInfo: [String: String] = [:]
        if let text = storage.string(forKey: SourceEngine.loginInfoKey),
           let data = text.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            loginInfo = o
        }
        var jar: [String: String] = [:]
        if let snap = obj["cookieSnapshot"] as? [String: String] { jar = snap }
        return [
            "source": [
                "url": source.bookSourceUrl,
                "name": source.bookSourceName,
                "group": source.bookSourceGroup ?? "",
                "vars": vars,
                "loginInfo": loginInfo,
                "loginHeader": storage.string(forKey: SourceEngine.loginHeaderKey) ?? "",
            ],
            "cookie": ["jar": jar],
        ]
    }
    if let node = jsBackend as? NodeJSExecutor {
        node.setHostState(hostStatePayload())
    }
    // ⭐⭐⭐⭐⭐ **假浏览器**（站方 🍅番茄登录靠它拿 sessionid）⭐⭐⭐⭐⭐
    if let node = jsBackend as? NodeJSExecutor {
        let pages = (obj["browserPages"] as? [[String: Any]]) ?? []
        if !pages.isEmpty { node.setBrowserPages(pages) }
    }
    if let lib = obj["jsLib"] as? String, !lib.isEmpty {
        try? engine.loadJsLib(lib)
    }

    // ⭐⭐⭐ **登录信息快照**（跑 op 之前）⇒ 失败的登录不许破坏已有登录态 ⭐⭐⭐
    let loginInfoBefore = engine.loadLoginInfo()
    let loginAction = obj["action"] as? String ?? ""

    var out: [String: Any] = [:]
    do {
        switch op {
        case "exploreKinds":
            let (kinds, filters) = try engine.exploreKinds()
            // ⭐⭐⭐ **组名/样式也带出去**（App 的发现页要显示分组 ⇒ 门禁要能断言）
            out["kinds"] = kinds.map { ["title": $0.title, "url": $0.url,
                                       "group": $0.group ?? "", "style": $0.style ?? ""] }
            out["filters"] = filters.map { ["title": $0.title] }
        case "explore":
            let kindUrl = obj["kindUrl"] as? String ?? ""
            let page = obj["page"] as? Int ?? 1
            let books = try engine.explore(kindUrl, page: page)
            // ⭐⭐⭐ **coverUrl 也要带出去**（老引擎的 explore op 给过 ⇒ 门禁在验它）
            out["books"] = books.map { ["name": $0.name, "author": $0.author,
                                        "bookUrl": $0.bookUrl, "intro": $0.intro,
                                        "kind": $0.kind, "lastChapter": $0.lastChapter,
                                        "coverUrl": $0.coverUrl, "wordCount": $0.wordCount] }
        case "search":
            // ⭐⭐⭐ **搜索 op**（老引擎有 ⇒ 门禁在验它 ⇒ 新引擎也要能跑）
            let keyword = obj["keyword"] as? String ?? ""
            let page = obj["page"] as? Int ?? 1
            let books = try engine.search(keyword, page: page)
            out["books"] = books.map { ["name": $0.name, "author": $0.author,
                                        "bookUrl": $0.bookUrl, "intro": $0.intro,
                                        "kind": $0.kind, "lastChapter": $0.lastChapter,
                                        "coverUrl": $0.coverUrl, "wordCount": $0.wordCount] }
        case "bookInfo":
            let bookUrl = obj["bookUrl"] as? String ?? ""
            var b = Book()
            b.bookUrl = bookUrl
            b.name = obj["name"] as? String ?? ""
            let info = try engine.bookInfo(b)
            out["book"] = ["name": info.name, "author": info.author, "intro": info.intro,
                           "kind": info.kind, "bookUrl": info.bookUrl, "tocUrl": info.tocUrl,
                           "lastChapter": info.lastChapter, "coverUrl": info.coverUrl,
                           "group": info.group, "wordCount": info.wordCount]
        case "toc":
            let bookUrl = obj["bookUrl"] as? String ?? ""
            var b = Book()
            b.bookUrl = bookUrl
            // ⚠️⚠️ **tocUrl 可以在 payload 里直接给**（老门禁就是这么做的）
            //   ⇒ 不给 ⇒ 才去跑一遍 bookInfo 拿 tocUrl（老引擎的语义）
            var info = BookInfo()
            info.bookUrl = bookUrl
            let payloadTocUrl = obj["tocUrl"] as? String ?? ""
            if !payloadTocUrl.isEmpty {
                info.tocUrl = payloadTocUrl
            } else {
                info = try engine.bookInfo(b)
            }
            let chapters = try engine.toc(info, book: b)
            // ⭐⭐⭐ **章节字段名对齐老引擎**：老门禁断言的是 `title` / `index`
            out["chapters"] = chapters.map { ["name": $0.name, "title": $0.name, "url": $0.url,
                                             "index": $0.index, "isVolume": $0.isVolume] }
        case "content":
            let chapterUrl = obj["chapterUrl"] as? String ?? ""
            let raw = (obj["book"] as? [String: Any]) ?? [:]
            var b = Book()
            b.bookUrl = (raw["bookUrl"] as? String) ?? (obj["bookUrl"] as? String) ?? ""
            b.name = (raw["name"] as? String) ?? ""
            var ch = Chapter()
            ch.url = chapterUrl
            ch.name = (obj["title"] as? String) ?? ""
            let text = try engine.content(ch, book: b)
            out["content"] = text
            out["title"] = ch.name
        case "explain":
            let kindUrl = obj["kindUrl"] as? String ?? ""
            let page = obj["page"] as? Int ?? 1
            let d = ExplainOps.explain(engine: engine, kindUrl: kindUrl, page: page)
            for (k, v) in d { out[k] = v }
        case "explainToc":
            let tocUrl = obj["tocUrl"] as? String ?? ""
            let bookUrl = obj["bookUrl"] as? String ?? ""
            let d = ExplainOps.explainToc(engine: engine, tocUrl: tocUrl, bookUrl: bookUrl)
            for (k, v) in d { out[k] = v }
        case "login":
            // ⭐⭐⭐⭐⭐ **登录 op**（老引擎 `engine.js` 的 `login` 同款）⭐⭐⭐⭐⭐
            //   ⚠️ 老引擎不是调 `login()`，而是跑【宿主传来的 action 表达式】
            //   ⇒ 这里照抄 App 侧 `LegadoEngineBackend.runLogin` 的口径 ⭐⭐⭐
            let action = obj["action"] as? String ?? ""
            let formValues = obj["formValues"] as? [String: String] ?? [:]
            let r = try engine.runLoginAction(action, formValues: formValues)
            out["ok"] = r.ok
            // ⭐⭐⭐ **站方原文**（toast / log）—— 判断「登录成没成功」的唯一依据 ⭐⭐⭐
            out["messages"] = r.messages
            if r.ok { out["result"] = r.result } else { out["error"] = r.result }
        case "loginProbe":
            // ⭐⭐⭐⭐⭐ **登录态检测 op**（老引擎 `loginProbe` 同款）⭐⭐⭐⭐⭐
            let r = try engine.probeLoginStatus()
            out["baseUrl"] = r.baseUrl
            out["messages"] = r.messages
            out["stationCheck"] = r.stationCheck
        default:
            out["error"] = "unknown op: \(op)"
        }
        out["ok"] = true
    } catch {
        out["ok"] = false
        out["error"] = "\(error)"
    }
    // ⭐⭐⭐⭐⭐ **宿主对象的状态收回来**（站方改过的变量 / 登录信息 / cookie）⭐⭐⭐⭐⭐
    //
    // ⚠️ Node 后端的宿主对象是「JS 侧记着 ⇒ Swift 收走」⇒ 收回来才能落盘（App 侧同款）⭐
    if let node = jsBackend as? NodeJSExecutor {
        let st = node.hostState()
        if let srcState = st["source"] as? [String: Any] {
            // ⚠️ **值不一定都是字符串**（站方变量可能有数字/布尔）⇒ 用 `[String: Any]` 再逐项转字符串
            //   ⇒ 否则整个字典转换失败 ⇒ **一个变量都收不回来**（静默丢）⭐⭐⭐
            if let vars = srcState["vars"] as? [String: Any] {
                for (k, v) in vars {
                    let s: String
                    if let str = v as? String { s = str }
                    else if let n = v as? NSNumber { s = n.stringValue }
                    else { s = String(describing: v) }
                    engine.varBox.set(k, s)
                }
            }
            if let info = srcState["loginInfo"] as? [String: Any] {
                var flat: [String: String] = [:]
                for (k, v) in info {
                    if let str = v as? String { flat[k] = str }
                    else if let n = v as? NSNumber { flat[k] = n.stringValue }
                    else { flat[k] = String(describing: v) }
                }
                // ⭐⭐⭐⭐⭐ **合并**（不是整份替换）⭐⭐⭐⭐⭐
                //   ⇒ 引擎那边**已经把表单值合并进登录信息**了（站方 action 里读 `getLoginInfoMap()` 要读得到）
                //   ⇒ 整份替换会把那份**抹掉** ⇒ 站方读不到输入框的值 ⇒ 用户点了「解锁整个源」还是提示「没填密码」⭐⭐⭐
                //   ⇒ 站方 `putLoginInfo` 写的键**盖在上面**（它写的就是要生效的）⭐
                var merged: [String: String] = [:]
                if let text = storage.string(forKey: SourceEngine.loginInfoKey),
                   let data = text.data(using: .utf8),
                   let old = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    merged = old
                }
                for (k, v) in flat { merged[k] = v }
                if let data = try? JSONSerialization.data(withJSONObject: merged),
                   let text = String(data: data, encoding: .utf8) {
                    storage.setString(text, forKey: SourceEngine.loginInfoKey)
                }
            }
            if let header = srcState["loginHeader"] as? String, !header.isEmpty {
                storage.setString(header, forKey: SourceEngine.loginHeaderKey)
            }
        }
        if let cookieState = st["cookie"] as? [String: Any],
           let jar = cookieState["jar"] as? [String: String] {
            for (host, value) in jar { cookieService.setCookie(value, for: host) }
        }
    }
    // ⭐⭐⭐⭐⭐ **失败的登录不许破坏已有登录态**（老引擎 `restoreLoginIfLost` 同款）⭐⭐⭐⭐⭐
    //
    // ⚠️ **为什么在这儿再恢复一次**：站方 `login(true)` 第一步无条件 `putLoginInfo(表单值)`
    //   ⇒ **把「密钥」抹掉**；而密钥是「登录成功」的标志（只有成功那步才写回去）
    //   ⇒ 登录_api 失败（服务器 502）⇒ 密钥**永远回不来**（用户真机就是这样丢的）⭐⭐⭐
    // ⚠️ **必须放在「写回站方改过的登录信息」之后** ⇒ 否则写回会把恢复好的密钥又抹掉 ⭐⭐⭐
    engine.restoreLoginIfLost(before: loginInfoBefore, action: loginAction)
    // ⭐⭐⭐ **登录信息 / 登录头 / 站方变量回传**（App 侧 `invoke` 的口径 ⇒ 门禁要能断言）⭐⭐⭐
    let info = engine.loadLoginInfo()
    if !info.isEmpty, let data = try? JSONSerialization.data(withJSONObject: info),
       let text = String(data: data, encoding: .utf8) {
        out["__loginInfo"] = text
    }
    let header = engine.currentLoginHeaderString()
    if !header.isEmpty { out["__loginHeader"] = header }
    let varsJSON = SourceEngine.varsJSON(engine.varBox)
    if !varsJSON.isEmpty { out["__sourceVars"] = varsJSON }
    // ⭐⭐⭐ **cookie 罐的回传**（门禁要断言「站方写了 cookie」）⭐⭐⭐
    var cookieOut: [String: String] = [:]
    for (host, value) in cookieService.cookieJarSnapshot() { cookieOut[host] = value }
    if !cookieOut.isEmpty { out["__cookies"] = cookieOut }
    // ⭐⭐⭐ **请求记录**（门禁要断言「发了哪几条」）⭐⭐⭐
    //
    // ⚠️⚠️ **两处都要记**（2026-10-26 门禁迁移时补的）：
    // · `rt.recorder.urls` ⇒ **引擎自己发的**请求（搜索页 / 详情页 / 目录页 / 正文页）
    // · `node.recordedRequests()` ⇒ **站方 JS 里 `java.ajax` 发的**请求
    //   （Node 后端的 `java.ajax` 走 JS 侧的静态路由表 ⇒ 不经过引擎的 transport ⇒ 记不到）
    // ⇒ 以前只记后者 ⇒ 门禁**看不到引擎发的请求**（「请求 URL 有没有编码」这类断言根本没法验）⭐⭐⭐
    var reqURLs: [String] = []
    if let rt = routeTransport { reqURLs.append(contentsOf: rt.recorder.urls) }
    if let node = jsBackend as? NodeJSExecutor, !inlineRoutes.isEmpty {
        for u in node.recordedRequests() where !reqURLs.contains(u) { reqURLs.append(u) }
    }
    if !reqURLs.isEmpty { out["requests"] = reqURLs }
    // ⭐⭐⭐ **开过的浏览器**（门禁要断言「引擎让宿主弹了浏览器」）⭐⭐⭐
    if let node = jsBackend as? NodeJSExecutor {
        let bs = node.recordedBrowsers()
        if !bs.isEmpty { out["browsers"] = bs }
    }
    let d2 = try! JSONSerialization.data(withJSONObject: out)
    print(String(data: d2, encoding: .utf8)!)
    exit(0)
}

// ===============================================================
// ⭐⭐⭐⭐⭐ `--sourceVars` 模式：**问站方要默认变量表**
//
// ⚠️ **为什么需要**（2026-10-25 老 JS 引擎物理删除）：
//   轻阅的「站方默认变量」门禁原本在 jsdom 里跑老引擎 ⇒ 老引擎删了 ⇒ 门禁的对象没了
//   ⇒ 现在**直接调新引擎的 `sourceVars` op** ⇒ 语义完全对齐 + 覆盖不丢 ⭐⭐⭐
//
// 用法：`swift run conformance --sourceVars '<json>'`
//   json = {"bookSourceUrl":"…", "jsLib":"…"}
//   输出：一行 JSON（变量表）
// ===============================================================
if let si = CommandLine.arguments.firstIndex(of: "--sourceVars") {
    let payload = si + 1 < CommandLine.arguments.count
        ? CommandLine.arguments[si + 1] : "{}"
    guard let d = payload.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        print("{}")
        exit(2)
    }
    let url = obj["bookSourceUrl"] as? String ?? ""
    let jsLib = obj["jsLib"] as? String ?? ""
    // ⭐⭐⭐ 引擎的 `BookSource` **没有 jsLib 字段**（站方 jsLib 由宿主单独带进来）
    //   ⇒ 这里直接 `loadJsLib`（与 App 侧 `Session.init` 同款）⭐⭐⭐
    let src = BookSource(bookSourceName: "probe", bookSourceUrl: url)
    // ⭐⭐⭐⭐⭐ **选 JS 后端**：JSC 优先，没有就用 **Node**（Linux 沙盒）⭐⭐⭐
    let jsBackend: JSExecutor?
    if let jsc = JSCExecutorIfAvailable() {
        jsBackend = jsc
    } else if NodeJSExecutor.isAvailable {
        jsBackend = try NodeJSExecutor()
    } else {
        jsBackend = nil
    }
    guard let jsBackend else {
        print("{\"__skip\":\"本平台既没有 JSC 也没有 node ⇒ jsLib 用例没法验\"}")
        exit(0)
    }
    let engine = SourceEngine(source: src, fetcher: PageFetcher(transport: URLSessionTransport()),
                               js: jsBackend)
    try? engine.loadJsLib(jsLib)
    let vars = (try? engine.sourceVars()) ?? [:]
    let d2 = try! JSONSerialization.data(withJSONObject: vars)
    print(String(data: d2, encoding: .utf8)!)
    exit(0)
}

// ===============================================================
// ⭐⭐⭐⭐⭐ `--eval` 模式：**任意规则 + 基准 ⇒ 求值结果 JSON**
//
// ⚠️ **为什么需要**（2026-10-25 老 JS 引擎物理删除）：
//   轻阅那 7 个「规则语义」门禁原本**在 jsdom 里跑老引擎 JS**
//   ⇒ 老引擎删了 ⇒ 门禁的对象没了 ⇒ **覆盖就丢了** ⭐⭐⭐
//   ⇒ 正解：让它们**跑新引擎**（本模式）⇒ 门禁继续有效，而且验的是**真正在跑的代码** ⭐⭐⭐
//
// 用法：`swift run conformance --eval '<json>'`
//   json = {"rule":"…", "base":"…", "baseType":"page|json|node",
//           "isJSON":true, "raw":"…", "baseUrl":"…", "vars":{…}}
//   输出：一行 JSON `{"ok":true,"value":…,"text":"…","branch":"…","failure":"…"}`
// ===============================================================
if let ei = CommandLine.arguments.firstIndex(of: "--eval") {
    var payload = ei + 1 < CommandLine.arguments.count
        ? CommandLine.arguments[ei + 1] : "{}"
    // ⭐⭐⭐ **payload 也可以从【文件】读**（`.json` 后缀 ⇒ 当路径）⇒ 大 payload 不用塞命令行
    //   （argv 单参数上限 128KB ⇒ 真书源（158KB）+ 真页面快照 ⇒ 直接炸 `E2BIG`）⭐⭐⭐
    if payload.hasSuffix(".json"), let pd = try? Data(contentsOf: URL(fileURLWithPath: payload)) {
        payload = String(data: pd, encoding: .utf8) ?? payload
    }
    guard let d = payload.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        print("{\"ok\":false,\"error\":\"bad payload\"}")
        exit(2)
    }
    let rule = obj["rule"] as? String ?? ""
    let baseText = obj["base"] as? String ?? ""
    let baseType = obj["baseType"] as? String ?? "page"
    let isJSON = obj["isJSON"] as? Bool ?? false
    let raw = obj["raw"] as? String ?? baseText
    let baseUrl = obj["baseUrl"] as? String ?? ""
    let vars = obj["vars"] as? [String: String] ?? [:]

    let base: RuleBase
    var document: DOMNode? = nil
    switch baseType {
    case "json":
        // ⭐⭐⭐ **baseJSON 是个对象** ⇒ 不能 `JSONValue.from(字典)`（那会走「当普通字符串」分支）
        //   ⇒ 必须直接 `JSONValue.from(Any)`（字典 ⇒ `.object`）⭐⭐⭐
        base = .json(JSONValue.from(obj["baseJSON"] ?? [:]))
    case "node":
        // ⭐⭐⭐⭐⭐ **条目级基准**（2026-10-26 门禁迁移补的）
        //   老门禁（`rules.test.js` 等）有一批断言是「**相对某个 DOM 节点**求值」
        //   （如「在 li 内查 li 自身」「`a@text` 取当前节点的链接」）
        //   ⇒ 基准必须是**那个节点** ⇒ 页面级基准做不到 ⇒ 这里按 CSS 选择器取节点 ⭐⭐⭐
        //   用法：`{"baseType":"node","base":"<html…>","selector":"li.item"}`
        let sel = obj["selector"] as? String ?? ""
        let doc = try? SwiftSoupDocument(html: baseText, baseURL: baseUrl)
        let node = doc.flatMap { d -> DOMNode? in
            sel.isEmpty ? d.document : (d.document.queryAll(sel).first)
        }
        if let node {
            base = .element(DOMNodeRef(node))
        } else {
            base = .page(baseText)
            document = doc?.document
        }
    default:
        base = .page(baseText)
        // ⭐⭐⭐⭐⭐ **页面级基准 ⇒ 必须解析出 DOM**（2026-10-26 门禁迁移补的）
        //   ⚠️⚠️ **不解析 ⇒ CSS / XPath 规则全都报 `baseTypeMismatch`**
        //   ⇒ 选择器类门禁（在 jsdom 里跑老引擎的那些）**一条都跑不了** ⭐⭐⭐
        if let doc = try? SwiftSoupDocument(html: baseText, baseURL: baseUrl) {
            document = doc.document
        }
    }
    var ctx = EvalContext(base: base, baseUrl: baseUrl, raw: raw,
                          vars: vars, isJSON: isJSON, document: document)
    // ⭐⭐⭐⭐⭐ **选 JS 后端**：有 JSC 用 JSC（macOS）；没有就**用 Node 顶替**（Linux 沙盒）
    //   ⇒ 沙盒里也能真跑站方 JS ⇒ **JS 类门禁不用 SKIP** ⭐⭐⭐
    let ev: Evaluator
    if let jsc = JSCExecutorIfAvailable() {
        ev = Evaluator(js: jsc)
    } else if NodeJSExecutor.isAvailable {
        ev = Evaluator(js: try NodeJSExecutor())
    } else {
        print("{\"ok\":false,\"error\":\"本平台既没有 JSC 也没有 node ⇒ JS 用例没法验\"}")
        exit(0)
    }
    // ⭐⭐⭐⭐⭐ **把【引擎的宿主 API】挂到 JS 后端**（2026-10-26 门禁迁移时补）
    //   ⇒ `java.getString('$.x')` 这类**要靠引擎**的宿主 API 才能算 ⭐⭐⭐
    //   ⇒ 而 `{{java.getString('$.status')=='50'?'完结':'连载'}}` 这种模板
    //     **379 个真源里 90 个（24%）在用** ⇒ 不挂 ⇒ 这些源的分类/简介/更新时间全是空 ⭐⭐⭐
    //   ⇒ 这里挂一个**空源**的引擎（不联网 ⇒ 只借它的宿主 API）⭐⭐⭐
    let apiEngine = SourceEngine(source: BookSource(bookSourceName: "eval", bookSourceUrl: ""),
                                 fetcher: PageFetcher(transport: HTTPTransportShim.failing()),
                                 js: ev.js)
    ev.js?.setEngineAPI({ method, args, base in apiEngine.engineJava(method, args, base) })
    // ⭐⭐⭐ **可选：先加载站方 jsLib**（2026-10-25 老引擎退役 ⇒ 门禁改验新引擎）
    //   ⇒ 站方 jsLib 定义的 `getArguments` / `host` 等**全局**必须先在同一个 JS 上下文里跑 ⭐⭐⭐
    //   ⇒ Linux 上没有 JSC ⇒ **JS 后端不可用** ⇒ jsLib 相关的用例会跳过（显式 SKIP）⭐⭐⭐
    if let jsLib = obj["jsLib"] as? String, !jsLib.isEmpty {
        guard let js = ev.js else {
            print("{\"ok\":false,\"error\":\"本平台没有 JS 后端（jsLib 用例没法验）\"}")
            exit(0)
        }
        try? js.runGlobal(jsLib, context: JSRunContext(base: .page(""), baseUrl: baseUrl))
    }
    let e = ev.evalOne(rule, base: base, ctx: ctx)
    var out: [String: Any] = [
        "ok": true,
        "value": e.value.jsonValue.foundationValue,
        "text": e.value.text,
        // ⭐⭐⭐⭐⭐ **字段出口**（2026-10-26 门禁迁移补的）
        //   老门禁的 `QR.rule.getValue(rule, base, ctx)` ⇒ **多个命中取第一个非空**（Legado 语义）
        //   ⇒ `text` 是「全部命中拼起来」⇒ 不能拿它当 getValue ⇒ 这里单独给 `first` ⭐⭐⭐
        "first": SourceEngine.firstNonEmpty(e.value),
        "branch": e.diagnostic.branch ?? "",
        "failure": e.diagnostic.failure.map { "\($0)" } ?? "",
    ]
    // ⭐⭐⭐⭐⭐ **「要全部命中」模式**（2026-10-26 门禁迁移补的）
    //   老门禁的 `QR.rule.getElements(rule, base, ctx).values` ⇒ **一次要全部**
    //   ⇒ `evalOne` 只给第一个 ⇒ 必须走 `getElements`（列表出口）⭐⭐⭐
    if (obj["all"] as? Bool) == true {
        let all = ev.getElements(rule, base: base, ctx: ctx)
        let values = all.value.items.map { $0.text }
        out["values"] = values
        out["count"] = values.count
    }
    let d2 = try! JSONSerialization.data(withJSONObject: out)
    print(String(data: d2, encoding: .utf8)!)
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
