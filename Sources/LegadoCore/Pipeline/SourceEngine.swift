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
    /// ⭐⭐ **源级变量的共享存储**（站方 `java.put` / `java.get` 读写的就是它）
    public let varBox: VarBox
    /// ⭐⭐ **DOM 缓存**（同一个页面只解析一次 —— 实测省 ~20ms）
    public let domCache: DOMCache
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
    /// ⭐⭐ **cookie 服务**（站方 `cookie.*` —— 真实语料 **205 处**）
    public let cookies: CookieService?

    // MARK: - ⭐⭐ 站方 JS 的宿主对象（book / source / chapter）

    /// ⭐⭐ **当前书籍对象**（站方 JS 里的 `book`）
    ///
    /// ⚠️ **必须真的传进去**（轻阅 build161 的教训）：
    ///   站方 `ruleToc.chapterList` 第一句就 `book.getVariable('custom')`
    ///   ⇒ 不给 book 就抛 `Cannot read properties of undefined` ⇒ **整条规则静默失效** ⭐
    public var bookObject: HostObject?
    /// ⭐⭐ **当前章节对象**（站方 JS 里的 `chapter`）
    public var chapterObject: HostObject?
    /// ⭐⭐ **cookie 宿主对象**（站方 `cookie.*` —— 真实语料 **205 处**）
    public var cookieObject: HostObject?
    /// ⭐⭐ **书源对象**（站方 JS 里的 `source`）
    public var sourceObject: HostObject?

    public init(source: BookSource, fetcher: PageFetcher, js: JSExecutor? = nil,
                storage: KeyValueStorage? = nil, files: FileStorage? = nil,
                browser: BrowserProvider? = nil, notifier: Notifier? = nil,
                logger: EngineLogger? = nil, cookies: CookieService? = nil) {
        self.source = source
        self.fetcher = fetcher
        // ⭐⭐ **源级请求头**（54 个源在用 ⇒ 缺了就 403 / 空页）
        self.sourceHeaders = Self.parseSourceHeader(source.header)
        // ⭐⭐ 源级变量的**共享**存储（跨规则 / 跨 JS 调用可写）
        self.varBox = VarBox()
        // ⭐ DOM 缓存（每源一个 ⇒ 天然隔离）
        self.domCache = DOMCache()
        self.evaluator = Evaluator(js: js)
        self.storage = storage
        self.files = files
        self.browser = browser
        self.notifier = notifier
        self.logger = logger
        self.cookies = cookies
        // ⭐⭐ cookie 宿主对象（站方 `cookie.getCookie(url)` 等 —— 205 处真实用法）
        if let cookies { self.cookieObject = Self.makeCookieObject(cookies) }
        // ⭐⭐ **让引擎接管 `java.ajax`**（站方 JS 抓页面用 —— 125 源里 22 处 / 12 个源）
        //
        // ⭐ 引擎**全同步** ⇒ 这里可以**同步发请求**并直接返回正文
        // ⇒ **不需要「两遍跑」机制**（那是 WKWebView 异步桥的补丁）⭐
        js?.setEngineAPI { [weak self] method, args, base in
            guard let self else { return nil }
            return self.engineJava(method, args, base)
        }
    }

    // MARK: - ① 分类

    /// **分类列表** —— 解析 `exploreUrl`。
    ///
    /// 两种形态都支持：
    /// - 老式：每行 `标题::URL`（**URL 可相对**，相对书源首页）
    /// - 新式：JSON 数组 `[{"title":…,"url":…,"style":…}]`
    public func categories() throws -> [SourceCategory] {
        try exploreKinds().kinds
    }

    /// ⭐⭐⭐ **发现页的分类 + 筛选栏**（栖阅契约 · 站方真实形态）
    ///
    /// **`exploreUrl` 有三种形态**（125 源实测）：
    /// ① **静态 JSON 数组**：`[{title,url,style}, …]`
    /// ② **静态纯文本**：`标题::URL` 每行一条（**`&&` 也是分隔符**）
    /// ③ ⭐ **JS**（`@js:` 或 `<js>…</js>`）⇒ **跑 JS 才拿得到分类**
    ///    （全免小说 / 免费追书 ⇒ 活体验证暴露的缺口）
    ///
    /// **JS 的返回值有四种形态**（照抄轻阅 `exploreKinds`）：
    /// - 数组 ⇒ 直接用
    /// - JSON 字符串（以 `[` / `{` 开头）⇒ `JSON.parse`
    /// - 纯文本（`玄幻::/type/xh`）⇒ 按 `&&`/换行切
    /// - 对象带 `exploreKind` ⇒ 取它
    ///
    /// ⚠️⚠️ **`@js:` 里不做 `{{}}` 插值**（Legado / 栖阅语义）
    ///   （`{{...}}` 是 JS 展开语法 ⇒ 插值会吃成空串 ⇒ **整个 JS 语法坏掉**）
    public func exploreKinds() throws -> (kinds: [SourceCategory], filters: [SourceFilter]) {
        // ⭐⭐ **兜底**：顶层 `exploreUrl` 空 ⇒ 试 **规则块里的** `ruleExplore.exploreUrl`
        //   （老引擎：`ruleText(src.exploreUrl) || ruleText(src.ruleExplore && src.ruleExplore.exploreUrl)`）
        //   ⇒ 少了这条 ⇒ 一批源直接「该书源没有发现规则」⭐
        let topURL = (source.exploreUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ruleURL = (source.ruleExplore?.exploreUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topURL.isEmpty || !ruleURL.isEmpty else {
            throw SourceError.ruleMissing("exploreUrl")
        }
        let spec = (topURL.isEmpty ? ruleURL : topURL)

        // ① JS 形态 ⇒ 跑 JS 拿分类数组
        var rawItems: [JSONValue] = []
        var isJS = false
        var jsCode = ""
        if spec.hasPrefix("@js:") || spec.hasPrefix("@JS:") {
            isJS = true; jsCode = String(spec.dropFirst(4))
        } else if spec.hasPrefix("<js>") || spec.hasPrefix("<JS>") {
            isJS = true
            jsCode = String(spec.dropFirst(4))
            if jsCode.hasSuffix("</js>") { jsCode = String(jsCode.dropLast(5)) }
        }

        if isJS {
            guard let js = evaluator.js else {
                throw SourceError.unsupported("exploreUrl 是 JS，但 JS 后端未接")
            }
            let out = try js.run(jsCode, context: JSRunContext(base: .page(""),
                                                                 baseUrl: source.bookSourceUrl,
                                                                 varBox: varBox))
            rawItems = Self.exploreItems(from: out)
        } else {
            // ② 静态形态
            if spec.hasPrefix("[") {
                // ⭐⭐ **容错解析**（站方 JSON 里常有裸换行 ⇒ 不是合法 JSON）
                if let obj = Self.lenientJSONObject(spec), let arr = obj as? [Any] {
                    rawItems = arr.map { JSONValue.from($0) }
                }
            } else {
                rawItems = Self.exploreItems(from: .string(spec))
            }
        }

        var (kinds, filters) = Self.splitExploreItems(rawItems, base: source.bookSourceUrl)

        // ⭐⭐ **分类项的 url 可能是 `@js:` 脚本** ⇒ 跑 JS 得真实 URL
        //   （全免小说 ⇒ 活体验证暴露的缺口；**轻阅也没有这条** ⇒ 全新能力）
        if kinds.contains(where: { $0.url.hasPrefix("@js:") || $0.url.hasPrefix("@JS:") }) {
            guard let js = evaluator.js else {
                throw SourceError.unsupported("分类 url 是 JS，但 JS 后端未接")
            }
            for i in kinds.indices {
                let u = kinds[i].url
                if u.hasPrefix("@js:") || u.hasPrefix("@JS:") {
                    let code = String(u.dropFirst(4))
                    let out = try js.run(code, context: JSRunContext(base: .page(""),
                                                                     baseUrl: source.bookSourceUrl,
                                                                     varBox: varBox))
                    let real = out.scalarString.trimmingCharacters(in: .whitespacesAndNewlines)
                    kinds[i].url = real.isEmpty ? "" : Self.absolute(real, base: source.bookSourceUrl)
                }
            }
        }
        guard !kinds.isEmpty else { throw SourceError.emptyResult("exploreUrl") }
        return (kinds, filters)
    }

    /// ⭐⭐ **容错 JSON 解析**（站方的 `exploreUrl` 里 `@js:` 后面常有**真换行**）
    ///
    /// ⚠️ **JSON 字符串里不能有裸换行** ⇒ 站方写成多行 JSON 时**根本不是合法 JSON**
    ///   （全免小说 ⇒ `exploreUrl` 解析失败 ⇒ 分类全空）
    /// ⇒ 把**字符串内**的真控制字符转义掉（字符串外的换行只是空白 ⇒ 不动）⇒ 再解析 ⭐
    public static func lenientJSONObject(_ text: String) -> Any? {
        var out = ""
        out.reserveCapacity(text.count + 32)
        var inString = false
        var escaped = false
        for ch in text {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { out.append(ch); escaped = true; continue }
            if ch == "\"" { inString.toggle(); out.append(ch); continue }
            if inString {
                switch ch {
                case "\n": out.append("\\n")
                case "\r": out.append("\\r")
                case "\t": out.append("\\t")
                default: out.append(ch)
                }
            } else {
                out.append(ch)
            }
        }
        guard let data = out.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// ⭐ **JS 返回值 ⇒ 分类项数组**（四种形态都认）
    public static func exploreItems(from v: JSONValue) -> [JSONValue] {
        switch v {
        case .array(let a):
            return a
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("[") || t.hasPrefix("{") {
                guard let data = t.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
                if let arr = obj as? [Any] { return arr.map { JSONValue.from($0) } }
                if let d = obj as? [String: Any], let ek = d["exploreKind"],
                   let arr = ek as? [Any] { return arr.map { JSONValue.from($0) } }
                return []
            }
            // 纯文本：`标题::URL`（`&&` 或换行分隔）
            return Self.splitPlainKinds(t).map { .string($0) }
        case .object(let o):
            if let ek = o["exploreKind"], case .array(let a) = ek { return a }
            return []
        default:
            return []
        }
    }

    /// ⭐ **纯文本分类**（`标题::URL`）⇒ 按 `&&` / 换行切
    public static func splitPlainKinds(_ text: String) -> [String] {
        var parts: [String] = []
        var buf = ""
        for ch in text {
            if ch == "&" || ch == "\n" || ch == "\r" {
                let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { parts.append(t) }
                buf = ""
            } else {
                buf.append(ch)
            }
        }
        let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { parts.append(t) }
        return parts
    }

    /// ⭐⭐ **分类项 ⇒ 分类 + 筛选栏**（照抄轻阅 `normalizeKinds` / 栖阅契约）
    ///
    /// - **字符串项**：无 `::` ⇒ **组标题**（剥装饰符号）⇒ 后面项归它
    /// - **字符串项**：有 `::` ⇒ `标题::URL` ⇒ 分类
    /// - **对象项**：`type == "select"` ⇒ **筛选栏**（不是分类！）
    /// - **对象项**：有 url ⇒ 分类
    public static func splitExploreItems(_ items: [JSONValue], base: String)
        -> (kinds: [SourceCategory], filters: [SourceFilter]) {
        var kinds: [SourceCategory] = []
        var filters: [SourceFilter] = []
        var group = ""
        for item in items {
            switch item {
            case .string(let raw):
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                guard let sep = t.range(of: "::") else {
                    // ⭐ 没有 `::` ⇒ **组标题**（装饰符号剥掉，只留文字）
                    group = t.replacingOccurrences(of: "[*☆○●•·　\\s]+", with: "",
                                                 options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if group.isEmpty { group = t }
                    continue
                }
                let title = String(t[t.startIndex..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                let url = String(t[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty, !url.isEmpty else { continue }
                kinds.append(SourceCategory(title: title, url: absolute(url, base: base),
                                            style: nil, group: group.isEmpty ? nil : group))
            case .object(let o):
                // ⭐⭐ **筛选栏**（栖阅契约：`{title, type:'select', chars, default, action}`）
                let ktype = (o["type"]?.scalarString ?? "").lowercased()
                if ktype == "select" {
                    var chars: [String] = []
                    if case .array(let a) = o["chars"] {
                        chars = a.map { $0.scalarString }
                    } else if let s = o["chars"]?.scalarString, !s.isEmpty {
                        chars = s.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                    let ftitle = o["title"]?.scalarString ?? ""
                    if !ftitle.isEmpty {
                        var weight: Double? = nil
                        if case .object(let st) = o["style"],
                           let w = st["layout_flexBasisPercent"] { weight = Double(w.scalarString) }
                        filters.append(SourceFilter(title: ftitle, chars: chars,
                                                   defaultValue: o["default"]?.scalarString,
                                                   action: o["action"]?.scalarString,
                                                   weight: weight))
                    }
                    continue
                }
                let title = o["title"]?.scalarString ?? ""
                let url = o["url"]?.scalarString ?? ""
                guard !title.isEmpty, !url.isEmpty else { continue }
                // ⭐⭐ **`@js:` 前缀必须原样保留**（否则被当相对路径绝对化 ⇒ 前缀丢了 ⇒ JS 分支认不出）
                let isJSURL = url.hasPrefix("@js:") || url.hasPrefix("@JS:")
                kinds.append(SourceCategory(title: title,
                                            url: isJSURL ? url : absolute(url, base: base),
                                            style: o["style"]?.scalarString,
                                            group: group.isEmpty ? nil : group))
            default:
                continue
            }
        }
        return (kinds, filters)
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
    ///
    /// ⭐⭐ **兜底**：`ruleExplore.bookList` 为空 ⇒ **回退 `ruleSearch`**
    ///   （老引擎 `pickListRule(src, false)`：Legado `BookList.kt` 同款）
    ///   ⇒ 少了这条 ⇒ 那些「只有搜索规则」的源在发现页**一本都不出**⭐
    public func explore(_ url: String, page: Int = 1) throws -> [Book] {
        try notifying {
            let p = try fetch(url, page: page)
            return try books(from: p, rules: listRuleForExplore(), field: "bookList")
        }
    }

    /// ⭐⭐ **发现页用的列表规则**（`ruleExplore.bookList` 空 ⇒ 回退 `ruleSearch`）
    ///
    /// ⚠️ 照抄老引擎 `pickListRule(src, isSearch=false)`：
    /// ```js
    /// if (isSearch) return search;
    /// var explore = src.ruleExplore || {};
    /// if (!ruleText(explore.bookList).trim()) return search;   // ← 回退
    /// return explore;
    /// ```
    public func listRuleForExplore() -> RuleFields? {
        let explore = source.ruleExplore
        let exploreList = (explore?.bookList ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if exploreList.isEmpty { return source.ruleSearch }
        return explore
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
            // ⭐ 搜索**永远**用 ruleSearch（老引擎 `pickListRule(src, true)`）
            return try books(from: p, rules: source.ruleSearch, field: "bookList")
        }
    }

    // MARK: - ④ 详情

    /// **详情** —— 抓详情页取字段。
    ///
    /// - Parameters:
    ///   - book: 书籍（列表项）
    ///   - variables: **书籍变量**（站方 `book.getVariable('custom')` 要读它）
    public func bookInfo(_ book: Book, variables: [String: String] = [:]) throws -> BookInfo {
        guard !book.bookUrl.isEmpty else { throw SourceError.invalidSource("bookUrl 为空") }
        let rules = source.ruleBookInfo
        return try notifying {
        let p = try fetch(book.bookUrl)
        var info = BookInfo()
        info.bookUrl = book.bookUrl
        info.sourceName = source.bookSourceName

        // ⭐⭐⭐ **`ruleBookInfo.init`** —— 在详情页结果上跑一次，
        //   **输出当后面所有字段规则的基准**（JSON 接口源几乎全靠它：
        //   `init: "$.data"` 把 `{code,msg,data:{…}}` 缩成 `{…}`）⭐
        let base: RuleBase
        if let initRule = rules?.initRule, !initRule.isEmpty {
            let initCtx = EvalContext(base: .page(p.text), baseUrl: p.url, raw: p.text,
                                     varBox: varBox, isJSON: p.isJSON, document: p.document)
            let e = evaluator.evalOne(initRule, base: initCtx.base, ctx: initCtx)
            diagnostics.append(e.diagnostic)
            logger?.log(Self.diagnosticLine(e.diagnostic))
            switch e.value {
            case .json(let j): base = .json(j)
            case .string(let s): base = .page(s)
            case .list(let items):
                // ⚠️ init 命中多个 ⇒ 取**第一个**（当基准用）
                if let first = items.first {
                    if case .json(let j) = first { base = .json(j) } else { base = .page(first.text) }
                } else { base = .page(p.text) }
            case .node(let n): base = .element(n)
            case .void: base = .page(p.text)
            }
        } else {
            base = .page(p.text)
        }

        // ⭐ 站方 JS 里的 `book` 对象（`book.getVariable('custom')`）
        bookObject = Self.makeBookObject(book, variables: variables)
        sourceObject = Self.makeSourceObject(source, varBox: varBox,
                                              loginInfo: loadLoginInfo(),
                                              storage: storage)

        info.name = value(rules?.name, in: nil, page: p, base: base)
        info.author = value(rules?.author, in: nil, page: p, base: base)
        info.intro = value(rules?.intro, in: nil, page: p, base: base)
        info.kind = value(rules?.kind, in: nil, page: p, base: base)
        info.coverUrl = Self.absolute(valueURL(rules?.coverUrl, in: nil, page: p, base: base), base: p.url)
        info.lastChapter = value(rules?.lastChapter, in: nil, page: p, base: base)
        // ⭐ **字数**（44 个源在用）
        info.wordCount = value(rules?.wordCount, in: nil, page: p, base: base)
        let toc = valueURL(rules?.tocUrl, in: nil, page: p, base: base)
        // ⚠️ 该源没给 tocUrl ⇒ **目录规则在详情页上跑**（Legado 语义：空 = 用 bookUrl）
        //
        // ⭐⭐⭐ **「不是页面 URL」的 tocUrl ⇒ 也当空**（2026-10-23 对拍挖出来的）
        //   站方有些源给 `javascript:;` 这种占位 ⇒ 真去抓 ⇒ 整个目录炸掉
        //   ⇒ 当成「没给」⇒ 目录回退到 bookUrl（老引擎的行为）⭐
        let tocURL = Self.absolute(toc, base: p.url)
        info.tocUrl = (toc.isEmpty || !Self.isPageURL(tocURL)) ? "" : tocURL
        info.raw["bookUrl"] = book.bookUrl
        return info
        }
    }

    // MARK: - ⑤ 目录

    /// **目录** —— 抓目录页（或详情页）列章节。
    ///
    /// - Parameters:
    ///   - info: 详情结果（`tocUrl` 空 ⇒ 目录规则跑在详情页上）
    ///   - book: **书籍对象**（站方 JS 里的 `book`；不给 ⇒ 站方 `book.getVariable(...)` 会炸）⭐
    ///   - variables: 书籍变量
    public func toc(_ info: BookInfo, book: Book? = nil, variables: [String: String] = [:]) throws -> [Chapter] {
        guard let rules = source.ruleToc else { throw SourceError.ruleMissing("ruleToc") }
        let listRule = rules.chapterList ?? ""
        guard !listRule.isEmpty else { throw SourceError.ruleMissing("chapterList") }
        // ⚠️ tocUrl 为空 ⇒ 用 bookUrl（目录规则跑在详情页上）
        let url = info.tocUrl.isEmpty ? info.bookUrl : info.tocUrl
        guard !url.isEmpty else { throw SourceError.invalidSource("目录 URL 为空") }
        return try notifying {
        // ⭐⭐ **站方 JS 的 `book` 对象**（站方目录 JS 第一句常是 `book.getVariable('custom')`）
        if let book {
            bookObject = Self.makeBookObject(book, variables: variables)
        }
        sourceObject = Self.makeSourceObject(source, varBox: varBox, loginInfo: loadLoginInfo())
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
            // ⚠️⚠️ **翻页抓失败不许炸掉整个目录**（2026-10-23 对拍挖出来的）
            //   站方的 `nextTocUrl` 有时给出**不是页面**的 URL（`javascript:;` 占位等）
            //   ⇒ 以前一个坏分页 ⇒ **整本目录 0 章**（老引擎是 promise 链 ⇒ 天然皮实）⭐
            //   ⇒ 现在：跳过这一页 + 记诊断 ⇒ 目录其余部分照常
            let p: Page
            do {
                p = try fetch(pageURL)
            } catch {
                var d = EngineDiagnostic(rule: "nextTocUrl", branch: "目录翻页")
                d.failure = .network("翻页页抓取失败：\(error)")
                diagnostics.append(d)
                logger?.log("目录翻页：跳过 \(pageURL)（\(error)）")
                continue
            }
            pages += 1

            // ⚠️ 翻页页**没命中不许炸**（后面某页没内容是常态）⇒ 跳过继续
            let nodes = try listNodes(listRule, page: p, field: "chapterList", strict: false)
            if !nodes.isEmpty {
                // ⭐ 卷标题判定：**站方给了 `isVolume` 规则就用它**（相对节点求值）
                //   （真书源：`.catalog-section-title@text||span@text` ⇒ 命中 h2 卷标题）
                //   没给 ⇒ 退到「没有章节 URL 就是卷标题」
                let isVolumeRule = rules.isVolume ?? ""
                for node in nodes {
                    let item = ListItem.node(node)
                    let name = value(rules.chapterName, in: item, page: p)
                    let rawURL = valueURL(rules.chapterUrl, in: item, page: p)
                    let chapterURL = rawURL.isEmpty ? "" : Self.absolute(rawURL, base: p.url)
                    let isVolume: Bool
                    if !isVolumeRule.isEmpty {
                        isVolume = !value(isVolumeRule, in: item, page: p).isEmpty
                    } else {
                        isVolume = chapterURL.isEmpty
                    }
                    // ⭐ **付费章节标记**（`ruleToc.isVip` —— 9 个源在用）
                    let isVipRule = rules.isVip ?? ""
                    let isVip = isVipRule.isEmpty ? false
                        : !value(isVipRule, in: item, page: p).isEmpty
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
    ///
    /// - Parameters:
    ///   - chapter: 章节
    ///   - book: **书籍对象**（站方正文 JS 常调 `book.getVariable('custom')` ⇒ 不给就整条规则失效）⭐
    ///   - variables: 书籍变量
    public func content(_ chapter: Chapter, book: Book? = nil, variables: [String: String] = [:]) throws -> String {
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
        // ⭐⭐ **站方 JS 的 `book` / `chapter` 对象**
        if let book {
            bookObject = Self.makeBookObject(book, variables: variables)
        }
        chapterObject = Self.makeChapterObject(chapter)
        sourceObject = Self.makeSourceObject(source, varBox: varBox, loginInfo: loadLoginInfo())
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

    // MARK: - ⭐⭐ 引擎侧接管的 `java.*`

    /// ⭐⭐ **引擎侧接管的 `java.*`** —— **返回 nil = 「我不接管」⇒ 落回宿主**。
    ///
    /// **契约**（125 源真实用量，按处数排序）：
    /// | API | 处数 | 本轮 |
    /// |---|---|---|
    /// | `java.md5Encode` | **233** | ✅ 纯计算 |
    /// | `java.ajax` | 27 | ✅ 同步发请求 |
    /// | `java.base64Decode` / `base64Encode` / `hexDecodeToString` | 7/5/3 | ✅ 纯计算 |
    /// | `java.randomUUID` | 2 | ✅ |
    /// | `java.toNumChapter` | 1 | ✅ |
    /// | `java.getString` / `get` / `put` | 63/34/23 | ✅ 本轮 |
    /// | `java.timeFormat` / `timeFormatUTC` | 16/2 | ✅ 本轮 |
    /// | `java.toast` / `log` / `getCookie` / `startBrowser` … | — | **宿主** |
    public func engineJava(_ method: String, _ args: [JSONValue], _ base: RuleBase = .page("")) -> JSONValue? {
        let first = args.first?.scalarString ?? ""
        switch method {
        case "ajax":
            let options = args.count > 1 ? args[1] : nil
            return ajax(url: first, options: options).map { .string($0) }
        case "md5Encode":
            return .string(Crypto.md5Hex(first))
        case "base64Encode":
            return .string(Crypto.base64Encode(first))
        case "base64Decode":
            // ⚠️ 解不了 ⇒ **空串**（不是 nil）—— nil 表示「不接管」⇒ 会落回宿主
            return .string(Crypto.base64Decode(first) ?? "")
        case "hexDecodeToString":
            // ⚠️ 同上：解不了 ⇒ 空串（**nil = 不接管**，语义不同）
            return .string(Crypto.hexDecodeToString(first) ?? "")
        case "randomUUID":
            return .string(Crypto.randomUUID())
        case "toNumChapter":
            return .string(Crypto.convertChineseNumerals(in: first))
        // ⭐⭐ `java.getString('$.x')` ⇒ **对当前基准做 JSONPath**（125 源里 63 处）
        //   ⚠️ 不是「读文件」—— 站方的实际约定是「取 result 里的字段」
        //   ⇒ 实参以 `$` 开头 ⇒ JSONPath；否则 ⇒ 读源级变量
        // ⭐⭐ `java.timeFormat(t)` ⇒ **epoch 毫秒 → "yyyy-MM-dd HH:mm:ss"**（本地时区）
        //   `java.timeFormatUTC(t, pattern, tz)` ⇒ UTC + **时区偏移小时**（如 8 = UTC+8）
        //   依据：轻阅参考实现（reference/js/java-api.js）+ 125 源真实用法
        case "timeFormat", "timeFormatUTC":
            guard let ms = TimeFormat.millis(from: first) else { return .string("") }
            let pattern = args.count > 1 ? args[1].scalarString : nil
            // ⚠️ 只有 UTC 版才带时区参数（站方：`timeFormatUTC(ms,'yyyy-MM-dd',8)`）
            let tz = (method == "timeFormatUTC" && args.count > 2)
                ? Int(args[2].scalarString) : nil
            return .string(TimeFormat.format(millis: ms, pattern: pattern,
                                             utcOffsetHours: tz))
        case "getString":
            if first.hasPrefix("$") || first.hasPrefix("result") {
                let ctx = EvalContext(base: base, varBox: varBox)
                return .string(VarStore.evalVarExpr(first, ctx: ctx))
            }
            return .string(varBox.get(first) ?? "")
        // ⭐ `java.get(key)` / `java.get(key, default)` ⇒ **读源级变量**
        case "get":
            let def = args.count > 1 ? args[1].scalarString : ""
            return .string(varBox.get(first) ?? def)
        // ⭐ `java.put(key, value)` ⇒ **写源级变量**（共享存储 ⇒ 后续规则读得到）
        case "put":
            let value = args.count > 1 ? args[1].scalarString : ""
            varBox.set(first, value)
            return .string("")
        // ⭐⭐ **宿主侧的出口**（站方 JS 的提示 / 日志 / cookie）
        //
        // ⚠️⚠️ **宿主没给 notifier / logger ⇒ 一律不接管**（返回 nil ⇒ 落回宿主）
        //   —— 「toast 归宿主」是引擎的既定契约（门禁 `testUnimplementedMethodsAreNotIntercepted` 钉死）
        //   ⇒ 只有「宿主明确给了出口」时引擎才代劳（否则站方 toast 会静默丢）⭐
        case "toast":
            guard let notifier else { return nil }
            notifier.notify(first)
            return .string("")
        case "log":
            guard let logger else { return nil }
            logger.log(first)
            return .string("")
        case "getCookie":
            // ⚠️ 站方语义 = 「取某个 URL 的 cookie 串」⇒ 引擎有 CookieJar 就能答
            if let jar = fetcher.cookieJar { return .string(jar.cookieHeader(for: first) ?? "") }
            return nil
        default:
            // ⭐ **不接管** ⇒ 落回宿主实现
            return nil
        }
    }

    // MARK: - ⭐⭐ `java.ajax`（引擎侧）

    /// ⭐⭐ **`java.ajax(url[, options])` 的引擎侧实现**。
    ///
    /// **为什么归引擎**：站方 JS 靠它抓页面（**125 源里 22 处 / 12 个源**）
    /// ⇒ 而引擎自己就有 `HTTPTransport` + `CookieJar` + 源级 header ⇒ **天然能做**
    /// ⇒ 宿主**不用实现**这一条。
    ///
    /// ⚠️ **站方的 `options` 转成 URL 规则后缀**（`url,{"method":…,"body":…}`）
    /// ⇒ **完整复用 `URLBuilder` 的编码语义**（query 重编码 / `+`→`%2B` / 绝对化）
    /// ⇒ ⚠️ **不要自己手搓请求构造** —— 那四条 URL 语义踩过坑 ⭐
    public func ajax(url: String, options: JSONValue?) -> String? {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return nil }

        // ① ⚠️⚠️ **`data:` 伪 URL 绝不能真去 fetch**
        //    （站方聚合源用它装载荷 ⇒ 载荷就是「页面内容」⇒ 当响应体返回）
        if u.lowercased().hasPrefix("data:") {
            return Self.dataPayload(u)
        }

        // ② 站方 options ⇒ URL 规则后缀
        var rule = u
        var opts: [String: Any] = [:]
        if case .object(let o)? = options {
            if let m = o["method"]?.scalarString, !m.isEmpty { opts["method"] = m }
            if let b = o["body"], !b.isNull {
                // ⚠️ body 可能是**字符串**，也可能是**对象**（对象 ⇒ JSON 化）
                switch b {
                case .string(let s): opts["body"] = s
                case .object, .array: opts["body"] = Self.jsonText(b)
                default: opts["body"] = b.scalarString
                }
            }
            if let h = o["headers"], case .object(let hh) = h, !hh.isEmpty {
                var hs: [String: String] = [:]
                for (k, v) in hh { hs[k] = v.scalarString }
                opts["headers"] = hs
            }
        }
        if !opts.isEmpty {
            guard let data = try? JSONSerialization.data(withJSONObject: opts),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            rule = u + "," + text
        }

        // ③ 发请求（走 `PageFetcher` ⇒ 带上源级 header + CookieJar）
        do {
            let resp = try fetcher.fetch(rule: rule, baseUrl: source.bookSourceUrl,
                                        headers: sourceHeaders)
            guard resp.isSuccess else { return nil }
            return resp.text
        } catch {
            // ⚠️ 失败**不抛**（JS 侧拿 undefined ⇒ 站方自己判空）
            //    ⇒ 但要把失败记进诊断（不许静默）
            let d = EngineDiagnostic(rule: "java.ajax", branch: "java.ajax")
            diagnostics.append(d)
            return nil
        }
    }

    /// ⚠️ **`data:` 伪 URL 的载荷**（站方聚合源用它装页面内容）。
    ///
    /// 格式：`data:;base64,<载荷>,{"type":"qingtian2"}`
    /// ⇒ 载荷在 `;base64,` 之后、`,` 之前。
    ///
    /// ⚠️ **解不了要明确失败（返回 nil）**，不许返回乱码
    /// （乱码 ⇒ 站方 `JSON.parse` 炸 ⇒ 整条规则挂掉）⭐
    public static func dataPayload(_ raw: String) -> String? {
        let rest = String(raw.dropFirst("data:".count))
        // ⭐ **标准 `data:` 格式**：`data:[<mediatype>][;base64],<data>`
        //   ⇒ **第一个逗号前 = mediatype**（可能含 `;base64`），**逗号后 = data**
        guard let firstComma = rest.firstIndex(of: ",") else { return rest }
        let mediatype = rest[rest.startIndex..<firstComma]
        let isBase64 = mediatype.lowercased().contains("base64")
        let data = String(rest[rest.index(after: firstComma)...])
        // ⚠️⚠️ **站方在 data 后面又接了自己的尾巴**：`,{"type":"qingtian"}`
        //   ⇒ base64 时载荷到**下一个逗号**为止；明文时**整个 data 都是载荷**（明文里可能有逗号）
        var payload = data
        if isBase64, let comma = data.firstIndex(of: ",") {
            payload = String(data[data.startIndex..<comma])
        }
        if isBase64 {
            // ⚠️ `Data(base64Encoded:)` **默认严格**（非法字符 ⇒ nil）⇒ 正好「明确失败」
            guard let data = Data(base64Encoded: payload, options: []) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return payload
    }

    /// JSON 值 → 文本（`body` 是对象时用）
    static func jsonText(_ v: JSONValue) -> String {
        let any = v.foundationValue
        guard let data = try? JSONSerialization.data(withJSONObject: any),
              let text = String(data: data, encoding: .utf8) else { return v.scalarString }
        return text
    }

    /// ⭐⭐⭐ **加载站方 jsLib**（**全局作用域** ⇒ 站方规则调得到）
    ///
    /// ⚠️ **必须用 `runGlobal`**（间接 eval）⇒ jsLib 的 `var` / `function` 留在全局
    /// ⇒ 而**普通规则求值用 eval 局部作用域**（否则 `let device_type` 撞全局 ⇒ 炸）⭐
    public func loadJsLib(_ code: String) throws {
        guard let js = evaluator.js else { throw SourceError.unsupported("JS 后端未接") }
        let ctx = JSRunContext(base: .page(""), baseUrl: source.bookSourceUrl, varBox: varBox)
        _ = try js.runGlobal(code, context: ctx)
        // ⭐⭐ **必须重设基线** ⇒ 站方 jsLib 定义的全局要长期保留
        //   （否则「每次求值前清全局」会把它们删掉 ⇒ 站方规则一调就炸）⭐
        js.markGlobalsAsBaseline()
    }

    // MARK: - ⑥ 登录链路

    /// ⭐⭐⭐ **加载站方的登录脚本**（`loginUrl`）⇒ 加载到 **JS 全局**。
    ///
    /// 站方真实用法（125 源实测）：
    /// - 猫眼看书：`loginUrl` 是一大段 JS（定义 `function login()` / `get_type()` …）
    /// - 番茄小说TS：`loginUrl` 定义 `function login(){}` + 各种 state helper
    ///
    /// ⚠️⚠️ **加载完必须重设全局基线** —— 否则「每次求值前清全局」会把站方定义的
    ///   `function get_type()` **删掉** ⇒ 站方后续调用就炸 ⭐
    ///   （这正是 JSC 上下文复用的代价：全局要么清、要么留 ⇒ 得由调用方声明）
    @discardableResult
    public func loadLoginScript() throws -> Bool {
        guard let code = source.loginUrl, !code.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        guard let js = evaluator.js else { throw SourceError.unsupported("JS 后端未接，无法加载登录脚本") }
        let runCtx = JSRunContext(base: .page(""), baseUrl: source.bookSourceUrl, varBox: varBox)
        _ = try js.run(code, context: runCtx)
        // ⭐⭐ **重设基线** ⇒ 站方 loginUrl 定义的全局被长期保留
        js.markGlobalsAsBaseline()
        return true
    }

    /// ⭐⭐ **登录界面定义**（`loginUi`）⇒ 交给宿主渲染。
    ///
    /// **两种形态都要认**（125 源实测）：
    /// - **JSON 数组**（猫眼看书）：`[{name, type, action}, …]`
    /// - **`@js:` 脚本**（番茄小说TS）：跑完得到 JSON 串
    public func loginUI() throws -> [LoginField] {
        guard let raw = source.loginUi, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }
        let text: String
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("@js:") || t.hasPrefix("@JS:") {
            guard let js = evaluator.js else { throw SourceError.unsupported("JS 后端未接") }
            let out = try js.run(String(t.dropFirst(4)),
                                context: JSRunContext(base: .page(""), baseUrl: source.bookSourceUrl,
                                                      varBox: varBox))
            text = out.scalarString
        } else {
            text = raw
        }
        return Self.parseLoginUI(text)
    }

    /// ⭐ **解析 `loginUi` 的 JSON 数组**（容错：坏 JSON ⇒ 空数组，不抛）
    public static func parseLoginUI(_ text: String) -> [LoginField] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("["), let data = t.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.map { d in
            LoginField(
                name: d["name"] as? String ?? "",
                type: d["type"] as? String ?? "text",
                hint: d["hint"] as? String,
                action: d["action"] as? String,
                viewName: d["viewName"] as? String,
                defaultValue: d["default"] as? String ?? d["defaultValue"] as? String
            )
        }
    }

    /// ⭐ **执行站方的登录动作**（`function login()`）⇒ 返回它的返回值。
    ///
    /// ⚠️ 站方常返回 **JSON 串**（猫眼：`return JSON.stringify(loginUI)`）
    /// ⇒ 宿主自己解析。
    public func performLogin() throws -> String {
        guard let js = evaluator.js else { throw SourceError.unsupported("JS 后端未接") }
        let out = try js.run("login()",
                            context: JSRunContext(base: .page(""), baseUrl: source.bookSourceUrl,
                                                  varBox: varBox))
        return out.scalarString
    }

    /// ⭐ **执行按钮的动作**（站方 `loginUi` 里 `action` 的 JS 表达式）
    public func performLoginAction(_ action: String) throws -> String {
        guard let js = evaluator.js else { throw SourceError.unsupported("JS 后端未接") }
        let out = try js.run(action,
                            context: JSRunContext(base: .page(""), baseUrl: source.bookSourceUrl,
                                                  varBox: varBox))
        return out.scalarString
    }

    /// ⭐ **登录态检测**（站方 `loginCheckJs`）⇒ 对给定页面跑，返回**原始结果字符串**。
    ///
    /// ⚠️ **语义留给宿主判断** —— 站方写法各异（有的返回 true、有的返回页面 HTML）
    /// ⇒ 引擎只负责「跑」+ 交出结果。
    public func checkLogin(pageText: String, pageURL: String) throws -> String {
        guard let code = source.loginCheckJs, !code.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ""
        }
        guard let js = evaluator.js else { throw SourceError.unsupported("JS 后端未接") }
        let out = try js.run(code,
                            context: JSRunContext(base: .page(pageText), baseUrl: pageURL,
                                                  raw: pageText, varBox: varBox))
        return out.scalarString
    }

    // MARK: - 登录信息（`loginInfo`）—— 站方 `source.getLoginInfoMap()` 读它
    //    （键的定义在上面：`makeSourceObject` 旁边）

    /// ⭐ **保存登录信息**（⇒ 存进宿主的 `KeyValueStorage`）
    public func saveLoginInfo(_ info: [String: String]) {
        guard let json = try? JSONSerialization.data(withJSONObject: info),
              let text = String(data: json, encoding: .utf8) else { return }
        storage?.setString(text, forKey: Self.loginInfoKey)
    }

    /// ⭐ **读取登录信息**
    public func loadLoginInfo() -> [String: String] {
        guard let text = storage?.string(forKey: Self.loginInfoKey),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }

    // MARK: - ⭐⭐ 宿主对象工厂（站方 JS 里的 book / source / chapter）

    /// ⭐⭐ **书籍对象**（站方 JS 里的 `book`）
    ///
    /// ⚠️ **必须真的传进去**（轻阅 build161 的教训）：
    ///   站方 `ruleToc.chapterList` 第一句就 `book.getVariable('custom')`
    ///   ⇒ 不给 book 就抛 `Cannot read properties of undefined` ⇒ **整条规则静默失效** ⭐
    public static func makeBookObject(_ book: Book, variables: [String: String]) -> HostObject {
        var methods: [String: HostMethod] = [:]
        methods["getVariable"] = { args in
            let key = args.first?.scalarString ?? ""
            guard !key.isEmpty else { return .string("") }
            return .string(variables[key] ?? "")
        }
        var properties: [String: JSONValue] = [:]
        properties["name"] = .string(book.name)
        properties["author"] = .string(book.author)
        properties["bookUrl"] = .string(book.bookUrl)
        properties["coverUrl"] = .string(book.coverUrl)
        properties["intro"] = .string(book.intro)
        properties["kind"] = .string(book.kind)
        properties["lastChapter"] = .string(book.lastChapter)
        properties["wordCount"] = .string(book.wordCount)
        // ⭐ **原始字段也挂上去**（站方 `book.book_id` 之类）
        for (k, v) in book.raw { properties[k] = .string(v) }
        return HostObject(name: "book", methods: methods, properties: properties)
    }

    /// ⭐⭐⭐ **书源对象**（站方 JS 里的 `source`）—— **照抄老引擎 `source-api.js` 的语义**
    ///
    /// 📌 **真实用量**（125 源包 + 大灰狼 + NovelHub 实测）：
    /// | API | 处数 |
    /// |---|---|
    /// | `source.get/put`（**单项**变量） | **127** |
    /// | `source.getKey` | **42** |
    /// | `source.get/putLoginHeader` | 3+ |
    ///
    /// ⚠️⚠️ **`source.get/put` 没实现 ⇒ 静默失效 + 假成功**（老引擎踩过的坑）：
    ///   站方（🍒NovelHub）`source.get("nhAuthed")` ⇒ TypeError ⇒ 被站方 try/catch 吞掉
    ///   ⇒ ① `nhAuth()` 恒 false ⇒ **所有规则字段直接 return ""** ⇒ 发现页空白
    ///   ⇒ ② `source.put(...)` 抛 ⇒ 解锁状态没存下来 ⇒ 站方照样弹「已解锁」⇒ **假成功** ⭐
    ///
    /// ⚠️ **`get` 不能实现成「返回整份 vars」** —— 站方是
    ///   `String(source.get("nhAuthed") || "")` 这样比对的 ⇒ 拿到整份 JSON 哈希对不上。
    public static func makeSourceObject(_ source: BookSource, varBox: VarBox,
                                        loginInfo: [String: String] = [:],
                                        loginHeader: String = "",
                                        storage: KeyValueStorage? = nil) -> HostObject {
        var methods: [String: HostMethod] = [:]

        // ── 整份变量 ────────────────────────────────────────────
        methods["getVariable"] = { _ in .string(Self.varsJSON(varBox)) }
        methods["setVariable"] = { args in
            let a = args.first
            // ① 传对象 ⇒ 整份替换
            if case .object(let o)? = a {
                var flat: [String: String] = [:]
                for (k, v) in o { flat[k] = v.scalarString }
                for (k, v) in flat { varBox.set(k, v) }
            } else if args.count > 1 {
                // ② `setVariable(key, value)` ⇒ 改一项
                let k = args[0].scalarString
                if !k.isEmpty { varBox.set(k, args[1].scalarString) }
            } else {
                // ③ `setVariable(jsonString)` ⇒ 整份替换
                let text = a?.scalarString ?? ""
                if let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for (k, v) in obj {
                        varBox.set(k, (v as? String) ?? String(describing: v))
                    }
                }
            }
            return .string("")
        }

        // ── ⭐⭐ 单项变量（真实语料 127 处）──────────────────────
        methods["get"] = { args in
            let key = args.first?.scalarString ?? ""
            guard !key.isEmpty else { return .string("") }
            // ⚠️ 没有该项 ⇒ **空串**（站方都按「空串 = 没设置」处理）
            return .string(varBox.get(key) ?? "")
        }
        methods["put"] = { args in
            let key = args.first?.scalarString ?? ""
            let value = args.count > 1 ? args[1].scalarString : ""
            if !key.isEmpty { varBox.set(key, value) }
            return .string("")
        }

        // ── ⭐ `getKey`（真实语料 42 处）─────────────────────────
        // Legado：给缓存当 key 用 ⇒ **稳定的源标识**即可
        methods["getKey"] = { _ in .string(source.bookSourceUrl) }

        // ── 登录信息 ────────────────────────────────────────────
        methods["getLoginInfoMap"] = { _ in
            var out: [String: JSONValue] = [:]
            for (k, v) in Self.currentLoginInfo(loginInfo, storage: storage) { out[k] = .string(v) }
            return .object(out)
        }
        methods["getLoginInfo"] = { _ in
            let info = Self.currentLoginInfo(loginInfo, storage: storage)
            guard let data = try? JSONSerialization.data(withJSONObject: info),
                  let text = String(data: data, encoding: .utf8) else { return .string("{}") }
            return .string(text)
        }
        methods["putLoginInfo"] = { args in
            var info = Self.currentLoginInfo(loginInfo, storage: storage)
            let a = args.first
            if let a, case .object(let o) = a {
                info = [:]
                for (k, v) in o { info[k] = v.scalarString }
            } else if args.count > 1 {
                let k = args[0].scalarString
                if !k.isEmpty { info[k] = args[1].scalarString }
            } else {
                let text = a?.scalarString ?? ""
                info = [:]
                if let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    info = obj
                }
            }
            // ⭐ 落盘（宿主给的 storage ⇒ 轻阅那边就是 UserDefaults）
            if let data = try? JSONSerialization.data(withJSONObject: info),
               let text = String(data: data, encoding: .utf8) {
                storage?.setString(text, forKey: SourceEngine.loginInfoKey)
            }
            return .string("")
        }

        // ── 登录头（栖阅机制：自动注入到每次请求头）───────────────
        methods["getLoginHeader"] = { _ in .string(Self.currentLoginHeader(loginHeader, storage: storage)) }
        methods["putLoginHeader"] = { args in
            let v = args.first?.scalarString ?? ""
            storage?.setString(v, forKey: SourceEngine.loginHeaderKey)
            return .string("")
        }

        var properties: [String: JSONValue] = [:]
        properties["bookSourceUrl"] = .string(source.bookSourceUrl)
        properties["bookSourceName"] = .string(source.bookSourceName)
        properties["bookSourceGroup"] = .string(source.bookSourceGroup ?? "")
        return HostObject(name: "source", methods: methods, properties: properties)
    }

    /// ⭐ **登录信息的键**（宿主存储用）
    public static let loginInfoKey = "loginInfo"
    /// ⭐ **登录头的键**（宿主存储用）
    public static let loginHeaderKey = "loginHeader"

    /// 当前登录信息（优先读宿主存储 ⇒ 站方改了立刻生效）
    static func currentLoginInfo(_ fallback: [String: String],
                                 storage: KeyValueStorage?) -> [String: String] {
        if let text = storage?.string(forKey: Self.loginInfoKey),
           let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return obj
        }
        return fallback
    }

    /// 当前登录头（优先读宿主存储）
    static func currentLoginHeader(_ fallback: String, storage: KeyValueStorage?) -> String {
        storage?.string(forKey: Self.loginHeaderKey) ?? fallback
    }

    /// ⭐ **源级变量 → JSON 串**（`getVariable` 的返回）
    public static func varsJSON(_ box: VarBox) -> String {
        let all = box.all
        guard !all.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: all),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// ⭐⭐ **cookie 宿主对象**（站方 `cookie.*` —— 真实语料 **205 处**）
    public static func makeCookieObject(_ service: CookieService) -> HostObject {
        var methods: [String: HostMethod] = [:]
        methods["getCookie"] = { args in
            .string(service.cookieHeader(for: args.first?.scalarString ?? ""))
        }
        methods["setCookie"] = { args in
            let url = args.first?.scalarString ?? ""
            let value = args.count > 1 ? args[1].scalarString : ""
            if !url.isEmpty { service.setCookie(value, for: url) }
            return .string("")
        }
        methods["removeCookie"] = { args in
            let url = args.first?.scalarString ?? ""
            if !url.isEmpty { service.removeCookie(for: url) }
            return .string("")
        }
        methods["replaceCookie"] = { args in
            let url = args.first?.scalarString ?? ""
            let value = args.count > 1 ? args[1].scalarString : ""
            if !url.isEmpty { service.replaceCookie(value, for: url) }
            return .string("")
        }
        return HostObject(name: "cookie", methods: methods, properties: [:])
    }

    /// ⭐⭐ **章节对象**（站方 JS 里的 `chapter`）
    public static func makeChapterObject(_ chapter: Chapter) -> HostObject {
        var properties: [String: JSONValue] = [:]
        properties["title"] = .string(chapter.name)
        properties["url"] = .string(chapter.url)
        properties["index"] = .int(chapter.index)
        properties["isVolume"] = .bool(chapter.isVolume)
        properties["isVip"] = .bool(chapter.isVip)
        return HostObject(name: "chapter", methods: [:], properties: properties)
    }

    // MARK: - 内部

    /// ⭐⭐ **这个 URL 是不是「页面」**（能发 HTTP 请求的那种）
    ///
    /// ⚠️ 站方规则会给出**不是页面**的 URL：`javascript:;`（占位）/ `mailto:` / `tel:` …
    /// ⇒ 真去 fetch ⇒ 报「unsupported URL」⇒ **整个目录炸掉** ⭐
    /// ⇒ `data:` **是例外**（聚合源用它装载荷 ⇒ 载荷当页面内容）
    public static func isPageURL(_ url: String) -> Bool {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if u.hasPrefix("data:") { return true }   // 载荷当页面内容（宿主负责解）
        return u.hasPrefix("http://") || u.hasPrefix("https://")
    }

    /// 抓一页
    private func fetch(_ urlRule: String, base: String? = nil, page: Int = 1,
                       key: String = "") throws -> Page {
        let baseURL = base ?? source.bookSourceUrl
        // 模板插值（`{{page}}` / `{{key}}` / `{{baseUrl}}`）
        var ctx = EvalContext(base: .page(""), baseUrl: baseURL, varBox: varBox)
        ctx.page = page
        ctx.key = key
        let rule = TemplateEngine.render(urlRule, ctx: ctx)

        // ⚠️⚠️ **不是「页面」的 URL**（`javascript:;` / `mailto:` …）⇒ 别发请求
        //   ⇒ 报一个**说人话**的错（以前报「unsupported URL」⇒ 整个目录炸）⭐
        let plainURL = URLBuilder.absolutize(rule, baseUrl: baseURL)
        if !Self.isPageURL(plainURL) {
            throw SourceError.invalidSource("不是页面 URL：\(plainURL)")
        }
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
        if !isJSON {
            // ⭐⭐ **DOM 缓存**：同一页只解析一次（详情页 + 目录页常是同一个 URL）
            if let cached = domCache.node(for: finalURL) {
                document = cached
            } else if let doc = try? SwiftSoupDocument(html: text, baseURL: finalURL) {
                document = doc.document
                domCache.put(doc.document, for: finalURL)
            }
        }
        return Page(url: finalURL, text: text, document: document, isJSON: isJSON)
    }

    /// 列表项 → 书
    private func books(from page: Page, rules: RuleFields?, field: String) throws -> [Book] {
        guard let rules else { throw SourceError.ruleMissing(field) }
        let listRule = rules.bookList ?? ""
        guard !listRule.isEmpty else { throw SourceError.ruleMissing(field) }
        // ⭐⭐⭐ **JSON 页面 ⇒ 列表项是 JSON 对象**（以前只认 DOM 节点 ⇒ JSON 源 0 本）⭐
        let items = try listItems(listRule, page: page, field: field)
        return items.map { item in
            Book(
                name: value(rules.name, in: item, page: page),
                author: value(rules.author, in: item, page: page),
                // ⚠️ 相对地址相对**列表页 URL** 绝对化
                bookUrl: Self.absolute(valueURL(rules.bookUrl, in: item, page: page), base: page.url),
                coverUrl: Self.absolute(valueURL(rules.coverUrl, in: item, page: page), base: page.url),
                intro: value(rules.intro, in: item, page: page),
                kind: value(rules.kind, in: item, page: page),
                lastChapter: value(rules.lastChapter, in: item, page: page),
                // ⭐ **字数**（111 处站方在用）
                wordCount: value(rules.wordCount, in: item, page: page),
                // ⭐⭐⭐ **原始字段**（站方聚合源要 book_id 之类 ⇒ 少了整本书崩）
                raw: item.rawFields
            )
        }
    }

    /// ⭐⭐⭐ **列表规则 → 列表项**（HTML ⇒ DOM 节点；**JSON ⇒ JSON 对象**）
    ///
    /// ⚠️ **为什么必须分两路**（2026-10-23 换引擎时暴露的缺口）：
    ///   以前编排层的列表项**只有 DOM 节点** ⇒ JSONPath 命中的是 JSON 值不是节点
    ///   ⇒ `evalNodes` 返回空 ⇒ **JSON 接口源一个都出不来**（列表 0 本）⭐
    private func listItems(_ rule: String, page: Page, field: String,
                           strict: Bool = true) throws -> [ListItem] {
        let ctx = EvalContext(base: .page(page.text), baseUrl: page.url, raw: page.text,
                              varBox: varBox, isJSON: page.isJSON, document: page.document)
        if page.isJSON {
            let e = evaluator.evalOne(rule, base: .page(page.text), ctx: ctx)
            diagnostics.append(e.diagnostic)
            logger?.log(Self.diagnosticLine(e.diagnostic))
            var raw: [JSONValue] = []
            switch e.value {
            case .json(let j):
                raw = [j]
            case .list(let items):
                raw = items.map { item in
                    if case .json(let j) = item { return j }
                    // ⚠️ 站方 `@js:` 的 bookList 常返回**字符串数组**
                    //   （每项一行 ⇒ 子规则用 `##正则##` 抠字段）⇒ 当成「文本项」
                    return .string(item.text)
                }
            case .string(let s):
                if !s.isEmpty { raw = [.string(s)] }
            case .node(let n):
                return [.node(n)]
            case .void:
                break
            }
            // ⭐⭐⭐ **摊平一层**（命中的是**数组** ⇒ 元素才是列表项）
            //   （老引擎 `jsonListOf` 同口径：数组 ⇒ 元素；对象 ⇒ 自身当一项）
            var flat: [JSONValue] = []
            for v in raw {
                if case .array(let arr) = v { flat.append(contentsOf: arr) } else { flat.append(v) }
            }
            let out = flat.map { ListItem.json($0) }
            if out.isEmpty, strict { throw SourceError.emptyResult(field) }
            return out
        }
        let nodes = try listNodes(rule, page: page, field: field, strict: strict)
        return nodes.map { ListItem.node($0) }
    }

    /// 列表规则 → 节点
    private func listNodes(_ rule: String, page: Page, field: String,
                            strict: Bool = true) throws -> [DOMNodeRef] {
        let ctx = EvalContext(base: .page(page.text), baseUrl: page.url, raw: page.text,
                              book: bookObject, source: sourceObject, chapter: chapterObject,
                              varBox: varBox, isJSON: page.isJSON, document: page.document)
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
                              varBox: varBox, isJSON: page.isJSON, document: page.document)
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

    // MARK: - ⭐⭐⭐ URL 字段专用求值（bookUrl / tocUrl / chapterUrl / coverUrl）

    /// ⭐⭐⭐ **URL 字段的求值** —— 「选择器求值不通 ⇒ 按 URL 规则再试一次」
    ///
    /// ⚠️⚠️⚠️ **为什么必须单独一条路**（2026-10-23 真实源对拍挖出来的）：
    ///   站方**大量**把 URL 直接写在字段规则里：
    ///     `ruleToc.chapterUrl  = 'https://xs.zzxsa.com/read/@get:{xid}/{{$.num}}?app_name=…'`
    ///     `ruleBookInfo.tocUrl = 'https://n.cmread.com/nap/p/catalogForWap.jsp?bid=@get:{bid}'`
    ///     `ruleBookInfo.bookUrl = '/novel/chapterList?novel_id={{$.novel_id}}'`   ← **以 `/` 开头**
    ///   ⇒ 规则以 `/` 开头会被**模式判定当成 XPath** ⇒ 查不到 ⇒ **章节 URL / 目录 URL 全空** ⭐
    ///   ⇒ **老引擎也这样**（轻阅的老债 ⇒ 那几个源目录 0 章）
    ///   ⇒ **新引擎要做得更好**：URL 字段就该按 URL 规则处理 ⭐
    ///
    /// ⭐ **顺序：先常规求值，命中就用；不通再按 URL 规则** ⇒
    ///   `a@href`（选择器）照常 ✔，`/novel/x?id={{$.id}}`（URL）兜底命中 ✔
    private func valueURL(_ rule: String?, in item: ListItem?, page: Page,
                          base overrideBase: RuleBase? = nil) -> String {
        guard let rule, !rule.isEmpty else { return "" }
        // ① 常规求值（选择器 / JSONPath / JS …）—— ⚠️ **init 基准要传进去**
        let normal = value(rule, in: item, page: page, base: overrideBase)
        if !normal.isEmpty { return normal }
        // ② ⭐ 兜底：当 URL 规则处理（插值 + 绝对化）
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeURL(t) else { return normal }
        // ②a 模板插值（基准 = 当前项 ⇒ `{{$.id}}` 能取到列表项的字段）⭐
        let ctx = EvalContext(base: overrideBase ?? item?.base ?? .page(page.text),
                              baseUrl: page.url, raw: page.text,
                              book: bookObject, source: sourceObject, chapter: chapterObject,
                              varBox: varBox, isJSON: page.isJSON, document: page.document)
        let rendered = TemplateEngine.render(t, ctx: ctx)
        // ②b ⭐ 走 `URLBuilder.parse` ⇒ **剥掉 `,{json}` 选项后缀** + 绝对化
        //   （站方真实写法：`https://chuangshi.qq.com/chapter/26150754,{"headers":{…}}`
        //     ⇒ 不剥后缀 ⇒ 服务器收到一坨带逗号的 URL ⇒ 404 ⇒ **目录 0 章** ⭐）
        //   相对基准 = **当前页的最终 URL**（不是书源首页）
        return URLBuilder.parse(rendered, baseUrl: page.url).url
    }

    /// ⭐⭐⭐ **这条规则长得像「URL」吗**（相对 URL / 绝对 URL / 带模板）
    ///
    /// ⚠️ **必须排除 XPath**：XPath 也以 `/` 开头（`//div`、`/html/body`）
    /// ⇒ 判据：带 `{{`（模板）/ 带 `?`（查询串）/ 带 http(s) ⇒ 一定是 URL
    public static func looksLikeURL(_ rule: String) -> Bool {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return true }
        if t.contains("{{") || t.contains("@get:") || t.contains("@put:") { return true }
        // 以 `/` 开头：**要像路径而不是 XPath**
        if t.hasPrefix("/") && !t.hasPrefix("//") {
            if t.contains("?") { return true }
            let head = t.split(separator: "?").first.map(String.init) ?? t
            if head.contains(".") && !head.contains("::") { return true }
        }
        return false
    }

    /// **字段规则求值** —— `scope` 非空 ⇒ 在该节点**内部**相对求值。
    ///
    /// ⭐ 相对求值是 Legado 的语义（`AnalyzeByJSoup.getElements` 用 `element.select(rule)`）。
    /// 而 SwiftSoup 的 `select` **含元素自身**（实测坐实）⇒
    /// ⇒ `chapterName: "a@text"` 作用在 `a` 节点上能命中自己 ✔
    /// ⇒ `name: "a@text"` 作用在 `div` 节点上能命中后代 `a` ✔
    /// 一条规则同时覆盖「相对子元素」和「取自身」两种站方写法。
    private func value(_ rule: String?, in item: ListItem?, page: Page,
                       base overrideBase: RuleBase? = nil) -> String {
        guard let rule, !rule.isEmpty else { return "" }
        let base: RuleBase = overrideBase ?? item.map { $0.base } ?? .page(page.text)
        let ctx = EvalContext(base: base, baseUrl: page.url, raw: page.text,
                              book: bookObject, source: sourceObject, chapter: chapterObject,
                              varBox: varBox, isJSON: page.isJSON, document: page.document)
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
                              book: bookObject, source: sourceObject, chapter: chapterObject,
                              varBox: varBox, isJSON: page.isJSON, document: page.document)
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
