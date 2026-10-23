import Foundation

/// **编排层** —— 把「规则 + 页面」组装成「书 / 章节 / 正文」。
///
/// ⭐ 五条流水线，对应 Legado 的五个阶段：
/// ```
/// categories()  分类   ← exploreUrl（老式「标题::URL」多行 / 新版 JSON 数组）
/// explore()     发现   ← ruleExplore.bookList
/// search()      搜索   ← ruleSearch
/// bookInfo()    详情   ← ruleBookInfo
/// toc()         目录   ← ruleToc.chapterList
/// content()     正文   ← ruleContent.content
/// ```
///
/// ⚠️ **三条不可让步的规矩**：
/// 1. **每个阶段都要留下诊断** —— 失败要能说清「哪一层、哪个字段」（§S-DIA）
/// 2. **相对地址必须绝对化** —— 基准是「**当前页的最终 URL**」，不是书源首页
/// 3. **空结果要抛错**，不许静默返回空数组 —— 「静默失效」是本项目要消灭的头号敌人
public final class SourceEngine {

    /// ⭐ **目录翻页上限**（防站方 `nextTocUrl` 成环 / 给无穷数组）
    public static let maxTocPages = 20
    /// ⭐ **正文翻页上限**
    public static let maxContentPages = 20

    /// 书源
    public let source: BookSource
    /// 抓页面的入口
    public let fetcher: PageFetcher
    /// ⭐⭐ **源级请求头**（`BookSource.header`）—— 125 源里 **54 个**在用
    ///
    /// ⚠️ 以前编排层**一次都没用** ⇒ 这 54 个源的请求全缺 UA / Referer / Cookie
    /// ⇒ 很多站会直接 403 / 跳验证 / 返回空页。
    public let sourceHeaders: [String: String]
    /// 求值器
    public var evaluator: Evaluator

    /// ⭐ **诊断流水** —— 每次求值都记一条，UI 可以整段回放
    public private(set) var diagnostics: [EngineDiagnostic] = []

    // MARK: - 宿主服务（都是**可选**的 ⇒ 核心层不依赖任何具体实现）

    /// 键值存储（书源变量 / 登录态 / 用户选择）
    public let storage: KeyValueStorage?
    /// 文件存储（缓存 / 离线正文）
    public let files: FileStorage?
    /// 浏览器（登录交接）
    public let browser: BrowserProvider?
    /// 用户提示（toast）
    public let notifier: Notifier?
    /// 引擎日志
    public let logger: EngineLogger?

    public init(source: BookSource, fetcher: PageFetcher, js: JSExecutor? = nil,
                storage: KeyValueStorage? = nil, files: FileStorage? = nil,
                browser: BrowserProvider? = nil, notifier: Notifier? = nil,
                logger: EngineLogger? = nil) {
        self.source = source
        self.fetcher = fetcher
        // ⭐⭐ **源级请求头**（54 个源在用 ⇒ 缺了就 403 / 空页）
        self.sourceHeaders = Self.parseSourceHeader(source.header)
        self.evaluator = Evaluator(js: js)
        self.storage = storage
        self.files = files
        self.browser = browser
        self.notifier = notifier
        self.logger = logger
    }

    // MARK: - ① 分类

    /// **分类列表** —— 解析 `exploreUrl`。
    ///
    /// 两种形态都支持：
    /// - 老式：每行 `标题::URL`（**URL 可相对**，相对书源首页）
    /// - 新式：JSON 数组 `[{"title":…,"url":…,"style":…}]`
    public func categories() throws -> [SourceCategory] {
        guard let exploreUrl = source.exploreUrl,
              !exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceError.ruleMissing("exploreUrl")
        }
        let cats = Self.parseExploreUrl(exploreUrl, base: source.bookSourceUrl)
        guard !cats.isEmpty else { throw SourceError.emptyResult("exploreUrl") }
        return cats
    }

    /// 解析 `exploreUrl`（纯函数，便于单测）
    public static func parseExploreUrl(_ raw: String, base: String) -> [SourceCategory] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 新式：JSON 数组
        if text.hasPrefix("[") {
            guard let data = text.data(using: .utf8),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                return []
            }
            return arr.compactMap { item in
                guard let url = (item["url"] as? String), !url.isEmpty else { return nil }
                let title = (item["title"] as? String) ?? url
                return SourceCategory(title: title, url: absolute(url, base: base),
                                style: item["style"] as? String)
            }
        }

        // 老式：`标题::URL` 每行一条
        var out: [SourceCategory] = []
        for line in text.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("//") else { continue }
            let parts = l.components(separatedBy: "::")
            guard parts.count >= 2 else { continue }
            let title = parts[0].trimmingCharacters(in: .whitespaces)
            let url = parts[1].trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { continue }
            out.append(SourceCategory(title: title.isEmpty ? url : title,
                                url: absolute(url, base: base), style: nil))
        }
        return out
    }

    // MARK: - ② 发现

    /// **发现** —— 抓分类页，列出书。
    public func explore(_ url: String, page: Int = 1) throws -> [Book] {
        try notifying {
            let p = try fetch(url, page: page)
            return try books(from: p, rules: source.ruleExplore, field: "bookList")
        }
    }

    // MARK: - ③ 搜索

    /// **搜索**
    public func search(_ keyword: String, page: Int = 1) throws -> [Book] {
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            throw SourceError.ruleMissing("searchUrl")
        }
        return try notifying {
            let rule = searchUrl
                .replacingOccurrences(of: "{{key}}", with: keyword)
                .replacingOccurrences(of: "{{page}}", with: String(page))
            let p = try fetch(rule, base: source.bookSourceUrl, page: page, key: keyword)
            return try books(from: p, rules: source.ruleSearch, field: "bookList")
        }
    }

    // MARK: - ④ 详情

    /// **详情** —— 抓详情页取字段。
    public func bookInfo(_ book: Book) throws -> BookInfo {
        guard !book.bookUrl.isEmpty else { throw SourceError.invalidSource("bookUrl 为空") }
        let rules = source.ruleBookInfo
        return try notifying {
        let p = try fetch(book.bookUrl)
        var info = BookInfo()
        info.bookUrl = book.bookUrl
        info.sourceName = source.bookSourceName
        info.name = value(rules?.name, in: nil, page: p)
        info.author = value(rules?.author, in: nil, page: p)
        info.intro = value(rules?.intro, in: nil, page: p)
        info.kind = value(rules?.kind, in: nil, page: p)
        info.coverUrl = Self.absolute(value(rules?.coverUrl, in: nil, page: p), base: p.url)
        info.lastChapter = value(rules?.lastChapter, in: nil, page: p)
        // ⭐ **字数**（44 个源在用）
        info.wordCount = value(rules?.wordCount, in: nil, page: p)
        let toc = value(rules?.tocUrl, in: nil, page: p)
        // ⚠️ 该源没给 tocUrl ⇒ **目录规则在详情页上跑**（Legado 语义：空 = 用 bookUrl）
        info.tocUrl = toc.isEmpty ? "" : Self.absolute(toc, base: p.url)
        info.raw["bookUrl"] = book.bookUrl
        return info
        }
    }

    // MARK: - ⑤ 目录

    /// **目录** —— 抓目录页（或详情页）列章节。
    public func toc(_ info: BookInfo) throws -> [Chapter] {
        guard let rules = source.ruleToc else { throw SourceError.ruleMissing("ruleToc") }
        let listRule = rules.chapterList ?? ""
        guard !listRule.isEmpty else { throw SourceError.ruleMissing("chapterList") }
        // ⚠️ tocUrl 为空 ⇒ 用 bookUrl（目录规则跑在详情页上）
        let url = info.tocUrl.isEmpty ? info.bookUrl : info.tocUrl
        guard !url.isEmpty else { throw SourceError.invalidSource("目录 URL 为空") }
        return try notifying {
        // ⭐⭐⭐ **目录翻页**（`ruleToc.nextTocUrl`）—— 125 源里 **24 个**在用
        //
        // 以前只抓**第一页** ⇒ 这 24 个源的目录是**残缺的**（红薯小说：50 章 / 实际 274 章）
        //
        // ⚠️ 站方的 `nextTocUrl` 有三种给法，**都要认**：
        //   ① 一个 URL 字符串（最常见）
        //   ② **一个数组**（站方一次把全量页的 URL 都给出来 ⇒ 当「待抓页队列」）
        //   ③ 多行文本（每个 URL 一行）
        //
        // ⚠️⚠️ **必须去重** —— 站方**每页都会再给一次同样的数组**
        //   ⇒ 不去重 ⇒ 死循环 + 章节重复
        var queue = [url]
        var seen: Set<String> = []
        var out: [Chapter] = []
        var pages = 0
        while !queue.isEmpty, pages < Self.maxTocPages {
            let pageURL = queue.removeFirst()
            guard !seen.contains(pageURL) else { continue }
            seen.insert(pageURL)
            let p = try fetch(pageURL)
            pages += 1

            // ⚠️ 翻页页**没命中不许炸**（后面某页没内容是常态）⇒ 跳过继续
            let nodes = try listNodes(listRule, page: p, field: "chapterList", strict: false)
            if !nodes.isEmpty {
                // ⭐ 卷标题判定：**站方给了 `isVolume` 规则就用它**（相对节点求值）
                //   （真书源：`.catalog-section-title@text||span@text` ⇒ 命中 h2 卷标题）
                //   没给 ⇒ 退到「没有章节 URL 就是卷标题」
                let isVolumeRule = rules.isVolume ?? ""
                for node in nodes {
                    let name = value(rules.chapterName, in: node, page: p)
                    let rawURL = value(rules.chapterUrl, in: node, page: p)
                    let chapterURL = rawURL.isEmpty ? "" : Self.absolute(rawURL, base: p.url)
                    let isVolume: Bool
                    if !isVolumeRule.isEmpty {
                        isVolume = !value(isVolumeRule, in: node, page: p).isEmpty
                    } else {
                        isVolume = chapterURL.isEmpty
                    }
                    // ⭐ **付费章节标记**（`ruleToc.isVip` —— 9 个源在用）
                    let isVipRule = rules.isVip ?? ""
                    let isVip = isVipRule.isEmpty ? false
                        : !value(isVipRule, in: node, page: p).isEmpty
                    out.append(Chapter(
                        name: name.isEmpty ? node.text : name,
                        url: chapterURL,
                        isVolume: isVolume,
                        isVip: isVip,
                        index: out.count
                    ))
                }
            }

            // ⭐ 下一批页
            if let nextRule = rules.nextTocUrl, !nextRule.isEmpty {
                queue.append(contentsOf: valueURLs(nextRule, page: p))
            }
        }
        return out
        }
    }

    // MARK: - ⑥ 正文

    /// **正文** —— 抓章节页取内容。
    public func content(_ chapter: Chapter) throws -> String {
        guard let rules = source.ruleContent else { throw SourceError.ruleMissing("ruleContent") }
        guard !chapter.url.isEmpty else { throw SourceError.invalidSource("章节 URL 为空") }
        return try notifying {
        let contentRule = rules.content ?? ""
        guard !contentRule.isEmpty else { throw SourceError.ruleMissing("content") }
        // ⭐⭐⭐ **正文翻页**（`ruleContent.nextContentUrl`）—— 125 源里 **28 个**在用
        //
        // Legado 语义：`nextContentUrl` = 「**下一段正文**的 URL」⇒ 多页正文要**拼起来**
        // 以前只抓第一页 ⇒ 这 28 个源的正文是**截断的**
        var url = chapter.url
        var seen: Set<String> = []
        var parts: [String] = []
        var pages = 0
        while !url.isEmpty, pages < Self.maxContentPages {
            guard !seen.contains(url) else { break }   // ⭐ 防死循环
            seen.insert(url)
            let p = try fetch(url)
            pages += 1
            // ⭐ 正文是**拼接**语义（命中多个 p ⇒ 全部正文都要）
            let piece = valueAll(rules.content, page: p)
            if !piece.isEmpty { parts.append(piece) }
            // 下一段
            if let nextRule = rules.nextContentUrl, !nextRule.isEmpty {
                url = valueURLs(nextRule, page: p).first ?? ""
            } else {
                url = ""
            }
        }
        var text = parts.joined(separator: "\n")
        text = Self.clean(text, using: rules.replaceRegex)
        return text
        }
    }

    /// ⭐⭐ **解析源级请求头**（`BookSource.header`）—— 站方有三种写法，**都要认**：
    ///
    /// ① **JSON 对象**：`{"User-Agent":"…","Referer":"…"}`
    /// ② **JSON 字符串**（Legado 官方写法）：`"{\"User-Agent\":\"…\"}"`
    /// ③ **原始 HTTP 头格式**（每行 `key: value`）
    ///
    /// ⚠️ 解析不出来 ⇒ **返回空 + 不报错**（不该因为一个 header 就让整个源挂掉）
    public static func parseSourceHeader(_ raw: String?) -> [String: String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // ② JSON 字符串 ⇒ 先解一层外壳
        //
        // ⚠️⚠️ **别写成 `try? jsonObject(…) as? String`** ——
        //   `try?` 套 `as?` 会产生**嵌套 optional** ⇒ `guard let` 解一层后仍是 optional
        //   ⇒ `as?` 直接失败 ⇒ 分支永远走不到（**静默返回空**）⭐
        // ⇒ 拆成两步：`try?` 拿 `Any`，再单独 `as?`。
        if t.hasPrefix("\"") {
            guard let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]),
                  let inner = obj as? String
            else { return [:] }
            return parseSourceHeader(inner)
        }
        // ① JSON 对象
        if t.hasPrefix("{") {
            guard let data = t.data(using: .utf8),
                  let anyObj = try? JSONSerialization.jsonObject(with: data),
                  let obj = anyObj as? [String: Any]
            else { return [:] }
            var out: [String: String] = [:]
            for (k, v) in obj { out[k] = String(describing: v) }
            return out
        }
        // ③ 原始头格式：`key: value` 每行一条
        var out: [String: String] = [:]
        for line in t.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, let idx = l.firstIndex(of: ":") else { continue }
            let k = String(l[l.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            let v = String(l[l.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    // MARK: - 内部

    /// 抓一页
    private func fetch(_ urlRule: String, base: String? = nil, page: Int = 1,
                       key: String = "") throws -> Page {
        let baseURL = base ?? source.bookSourceUrl
        // 模板插值（`{{page}}` / `{{key}}` / `{{baseUrl}}`）
        var ctx = EvalContext(base: .page(""), baseUrl: baseURL)
        ctx.page = page
        ctx.key = key
        let rule = TemplateEngine.render(urlRule, ctx: ctx)

        let resp: HTTPResponse
        do {
            // ⭐⭐ **带上源级请求头**（54 个源在用）
            resp = try fetcher.fetch(rule: rule, baseUrl: baseURL, headers: sourceHeaders)
        } catch {
            throw SourceError.requestFailed(rule, String(describing: error))
        }
        let finalURL = resp.finalURL ?? rule
        guard resp.isSuccess else {
            throw SourceError.requestFailed(finalURL, "HTTP \(resp.statusCode)")
        }
        let text = resp.text
        let isJSON = resp.isJSON
        var document: DOMNode?
        if !isJSON, let doc = try? SwiftSoupDocument(html: text, baseURL: finalURL) {
            document = doc.document
        }
        return Page(url: finalURL, text: text, document: document, isJSON: isJSON)
    }

    /// 列表项 → 书
    private func books(from page: Page, rules: RuleFields?, field: String) throws -> [Book] {
        guard let rules else { throw SourceError.ruleMissing(field) }
        let listRule = rules.bookList ?? ""
        guard !listRule.isEmpty else { throw SourceError.ruleMissing(field) }
        let nodes = try listNodes(listRule, page: page, field: field)
        return nodes.map { node in
            Book(
                name: value(rules.name, in: node, page: page),
                author: value(rules.author, in: node, page: page),
                // ⚠️ 相对地址相对**列表页 URL** 绝对化
                bookUrl: Self.absolute(value(rules.bookUrl, in: node, page: page), base: page.url),
                coverUrl: Self.absolute(value(rules.coverUrl, in: node, page: page), base: page.url),
                intro: value(rules.intro, in: node, page: page),
                kind: value(rules.kind, in: node, page: page),
                lastChapter: value(rules.lastChapter, in: node, page: page),
                // ⭐ **字数**（111 处站方在用）
                wordCount: value(rules.wordCount, in: node, page: page)
            )
        }
    }

    /// 列表规则 → 节点
    private func listNodes(_ rule: String, page: Page, field: String,
                            strict: Bool = true) throws -> [DOMNodeRef] {
        let ctx = EvalContext(base: .page(page.text), baseUrl: page.url, raw: page.text,
                              isJSON: page.isJSON, document: page.document)
        let nodes = evaluator.evalNodes(rule, base: ctx.base, ctx: ctx)
        // ⚠️ 翻页时 `strict = false` —— 后面某页没命中是常态，**不许炸掉整个目录**
        if nodes.isEmpty, strict { throw SourceError.emptyResult(field) }
        return nodes
    }

    /// ⭐⭐ **`nextUrl` / `nextTocUrl` / `nextContentUrl` 的求值** ⇒ **URL 列表**。
    ///
    /// 站方有三种给法，**都要认**：
    /// - ① 一个 URL 字符串（最常见）
    /// - ② **一个数组**（站方一次把全量页的 URL 都给出来 ⇒ 当「待抓页队列」）
    ///   （数组元素是对象时取 `url` / `href` 键）
    /// - ③ 多行文本（每个 URL 一行）
    ///
    /// ⚠️ **基准是当前页**（页面级）⇒ 站方 `@js:` 里的 `result` = **页原文**
    /// ⇒ 对 JSON 页面来说就是 **JSON 原文** ⇒ 站方 `JSON.parse(result)` 能直接用 ⭐
    private func valueURLs(_ rule: String?, page: Page) -> [String] {
        guard let rule, !rule.isEmpty else { return [] }
        let base: RuleBase = .page(page.text)
        let ctx = EvalContext(base: base, baseUrl: page.url, raw: page.text,
                              isJSON: page.isJSON, document: page.document)
        let e = evaluator.evalOne(rule, base: base, ctx: ctx)
        diagnostics.append(e.diagnostic)
        logger?.log(Self.diagnosticLine(e.diagnostic))
        var out: [String] = []
        switch e.value {
        case .json(let j):
            if case .array(let arr) = j {
                for it in arr {
                    if case .object(let o) = it {
                        if let u = o["url"]?.scalarString { out.append(u) }
                        else if let u = o["href"]?.scalarString { out.append(u) }
                        else { out.append(it.scalarString) }
                    } else {
                        out.append(it.scalarString)
                    }
                }
            } else {
                out.append(j.scalarString)
            }
        case .list(let items):
            out.append(contentsOf: items.map { $0.text })
        case .string(let s):
            out.append(contentsOf: s.components(separatedBy: .newlines))
        case .node(let n):
            out.append(n.text)
        case .void:
            break
        }
        return out
            .map { Self.absolute($0.trimmingCharacters(in: .whitespacesAndNewlines), base: page.url) }
            .filter { !$0.isEmpty }
    }

    /// **字段规则求值** —— `scope` 非空 ⇒ 在该节点**内部**相对求值。
    ///
    /// ⭐ 相对求值是 Legado 的语义（`AnalyzeByJSoup.getElements` 用 `element.select(rule)`）。
    /// 而 SwiftSoup 的 `select` **含元素自身**（实测坐实）⇒
    /// ⇒ `chapterName: "a@text"` 作用在 `a` 节点上能命中自己 ✔
    /// ⇒ `name: "a@text"` 作用在 `div` 节点上能命中后代 `a` ✔
    /// 一条规则同时覆盖「相对子元素」和「取自身」两种站方写法。
    private func value(_ rule: String?, in scope: DOMNodeRef?, page: Page) -> String {
        guard let rule, !rule.isEmpty else { return "" }
        let base: RuleBase = scope.map { RuleBase.element($0) } ?? .page(page.text)
        let ctx = EvalContext(base: base, baseUrl: page.url, raw: page.text,
                              isJSON: page.isJSON, document: page.document)
        let e = evaluator.evalOne(rule, base: base, ctx: ctx)
        diagnostics.append(e.diagnostic)
        // ⭐ 把诊断**同时**送进宿主日志（宿主才能回放给用户看）
        logger?.log(Self.diagnosticLine(e.diagnostic))
        // ⭐⭐ **字段出口：多个命中 ⇒ 取【第一个非空】**（Legado 语义）
        //
        // ⚠️ 以前用 `e.value.text` ⇒ 多个命中会被**拼起来**
        //   （详情页有 2 个 `.w` ⇒ 字数变成 "12.3万字\n12.3万字" ⇒ 字段是脏的）
        return Self.firstNonEmpty(e.value)
    }

    /// ⭐ **正文出口** —— 多个命中**全部拼接**（与字段出口相反）。
    private func valueAll(_ rule: String?, page: Page) -> String {
        guard let rule, !rule.isEmpty else { return "" }
        let base: RuleBase = .page(page.text)
        let ctx = EvalContext(base: base, baseUrl: page.url, raw: page.text,
                              isJSON: page.isJSON, document: page.document)
        let e = evaluator.evalOne(rule, base: base, ctx: ctx)
        diagnostics.append(e.diagnostic)
        logger?.log(Self.diagnosticLine(e.diagnostic))
        return e.value.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ⭐⭐ **字段出口的值** —— 多个命中取**第一个非空**（Legado 语义）。
    ///
    /// ⚠️ 与**正文出口**不同：正文规则（`ruleContent.content`）命中多个时要**全部拼接**。
    public static func firstNonEmpty(_ v: RuleValue) -> String {
        switch v {
        case .void:
            return ""
        case .string(let s):
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .list(let items):
            for it in items {
                let t = it.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            return ""
        case .json(let j):
            if case .array(let arr) = j {
                for it in arr {
                    let t = it.scalarString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                }
                return ""
            }
            return j.scalarString.trimmingCharacters(in: .whitespacesAndNewlines)
        case .node(let n):
            return n.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// ⭐ 出错时**先通知宿主**（toast / 弹窗），再把错误抛出去。
    ///
    /// ⇒ 宿主既能弹提示（用户看得见），又能拿到错误对象（自己做重试/兜底）——**两条路都要有**。
    private func notifying<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let e as SourceError {
            notifier?.notifyError(e.errorDescription ?? String(describing: e))
            throw e
        }
    }

    /// 诊断的**单行文本形式**（给宿主日志 / 「测书源」报告）
    public static func diagnosticLine(_ d: EngineDiagnostic) -> String {
        var parts: [String] = []
        if let b = d.branch, !b.isEmpty { parts.append("分支=\(b)") }
        if let f = d.failure { parts.append("失败=\(f)") }
        if parts.isEmpty { parts.append("ok") }
        return "规则[\(d.rule)] " + parts.joined(separator: " ")
    }

    // MARK: - 工具

    /// **相对地址绝对化** —— 基准是**当前页的最终 URL**。
    public static func absolute(_ s: String, base: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return t }
        if t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("//") { return t }
        guard !base.isEmpty, let b = URL(string: base) else { return t }
        if let u = URL(string: t, relativeTo: b)?.absoluteURL { return u.absoluteString }
        return t
    }

    /// **正文净化** —— `replaceRegex` 格式：`正则=>替换`，**每行一条**；替换为空 = 删除。
    public static func clean(_ text: String, using replaceRegex: String?) -> String {
        var t = text
        if let rr = replaceRegex, !rr.isEmpty {
            for line in rr.components(separatedBy: .newlines) {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard !l.isEmpty else { continue }
                let parts = l.components(separatedBy: "=>")
                let pattern = parts[0].trimmingCharacters(in: .whitespaces)
                let replacement = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                guard !pattern.isEmpty, let re = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(t.startIndex..<t.endIndex, in: t)
                t = re.stringByReplacingMatches(in: t, options: [], range: range,
                                              withTemplate: replacement)
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
