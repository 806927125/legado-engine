import Foundation

/// 规则前端 —— 规则字符串 → AST。
///
/// 规格：`docs/legado-semantics.md` §S-CLS / §S-EXCL / §S-FBK / §S-RGX / §S-TPL。
///
/// ⭐ **本文件是「语义唯一真源」的落点**：
/// `||` / `&&` / `,` 的切分**只有这一处实现**，
/// 避免轻阅里「三处切法不一致」的历史问题。
public struct RuleParser {

    /// AST 缓存（可选）—— §S-EVAL-11
    ///
    /// ⚠️ **只缓存「整条规则」的 AST**；递归切分出来的子段**不进缓存**
    /// ⇒ 否则缓存里全是碎片，命中率低且 key 爆炸
    private let cache: RuleCache?

    public init(cache: RuleCache? = nil) {
        self.cache = cache
    }

    // MARK: - 入口

    /// 解析一条规则。
    /// - Parameters:
    ///   - raw: 规则原文
    ///   - isJSON: 响应体是不是 JSON（影响模式判定，§S-CLS-08）
    /// ⭐ **缓存统计**（宿主 / 门禁用来确认「缓存真的在用」）
    public var cacheStats: RuleCache.Stats { cache?.stats ?? .empty }

    public func parse(_ raw: String?, isJSON: Bool = false) -> RuleNode {
        // ⭐ **顶层入口走缓存**（§S-EVAL-11）
        guard let cache else { return parseInternal(raw, isJSON: isJSON) }
        let key = RuleCache.Key(rule: raw ?? "", isJSON: isJSON)
        // ⭐ **先只查命中**（不创建闭包 ⇒ 命中路径零堆分配）
        if let hit = cache.cached(for: key) { return hit }
        return cache.node(for: key) { [self] in parseInternal(raw, isJSON: isJSON) }
    }

    /// 内部实现 —— **递归切分出来的子段走这里**（**不进缓存**）
    ///
    /// ⚠️ 纪律：缓存里只该有「整条规则」的 AST ⇒ 碎片不入缓存
    private func parseInternal(_ raw: String?, isJSON: Bool) -> RuleNode {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .empty }

        // ① `<js>…</js>` 整块 —— 不能按行切、不能按 `||` 拆（§S-CMP-01/02）
        if s.hasPrefix("<js>") || s.hasPrefix("<JS>") {
            return parseBlock(s)
        }

        // ② `@@` 二次解析（§S-CLS-05）
        if s.hasPrefix("@@") {
            return .reparse(parseInternal(String(s.dropFirst(2)), isJSON: isJSON))
        }

        // ⭐⭐⭐⭐⭐ **②' `@js:` 整块 —— 不能按 `||` / `&&` 拆**（2026-10-25 真机实证）
        //
        // ⚠️⚠️⚠️ **这是「很多书源都是这样」的通用真凶**：
        //   `@js:` 后面是**站方的 JavaScript 代码** ⇒ 里面的 `||` 是 **JS 的「或」运算符**
        //   ⇒ 而解析器会把规则按 `||` 拆成「兜底链」⇒ **JS 代码被腰斩** ⇒ 规则失败 ⭐⭐⭐
        //   ⇒ 例：`@js:var t = result.tab || "小说"; …` ⇒ 被拆成两段 ⇒ 两段都不是合法 JS ⭐⭐⭐
        //
        // ⇒ 修法：**`@js:` 前缀的规则整体当 JS**（跟 `<js>…</js>` 整块一个待遇）⭐⭐⭐
        //   ⚠️ 这与 `<js>…</js>` 的既有保护**同款**（`RuleParser` 的 ①）⭐⭐⭐
        if s.hasPrefix("@js:") || s.hasPrefix("@JS:") {
            return .js(String(s.dropFirst(4)))
        }

        // ⭐⭐⭐⭐⭐ **③' 尾部后处理（`@js:` / `<js>`）必须【先于 `||` 切分】提取**
        //
        // ⚠️⚠️⚠️ **为什么顺序反了就是真机「详情目录都不能用」的根因**（2026-10-27 真机实证）：
        //   站方真实规则（UAA 四合一 / 知秋）：
        //     `videoId||id` ⏎ `@js:` `let type = baseUrl.match(…)[1]` ⏎ `getApiUrl('/'+type+'/info', {novelId: result})`
        //   ⇒ 语义 = **「(videoId || id) 选出 id ⇒ 交给 JS 拼 URL」**（JS 跑在**整条链之后**）⭐⭐⭐
        //
        //   以前 `||` 先切 ⇒ 变成 `["videoId", "id\n@js:…"]`
        //   ⇒ ① 尾部 `@js:` **只挂在最后一段** ⇒ 第一段命中时 **JS 根本不跑** ⇒ URL 是裸 id ⭐⭐⭐
        //   ⇒ ② head 带着尾换行（`"id\n"`）⇒ JSON 相对路径被**误判成 CSS 选择器**
        //      ⇒ 空 ⇒ 「|| 兜底链全部未命中」⭐⭐⭐（= 真机诊断里那行字）
        //   ⇒ ③ 更糟：JS 代码里的 `||`（JS 的「或」运算符）会被 `||` 切分**腰斩** ⭐⭐⭐
        //
        // ⇒ **正解：先把尾部后处理摘出来 ⇒ 剩下的 head 再切 `||`/`&&` ⇒ 整条链的值当 `result` 喂给 JS** ⭐⭐⭐
        //   （与老引擎 `analyzeJsInUrl` 同款：`@js:` 贪婪到末尾 / `<js>` 非贪婪）⭐⭐⭐
        if let (head, post) = Self.splitPostProcess(s), !head.isEmpty {
            return .post(parseInternal(head, isJSON: isJSON), post)
        }

        // ③ `||` 择一（§S-FBK-01）—— 优先级最高
        let orParts = Self.splitTopLevel(s, separators: ["||"])
        if orParts.count > 1 {
            return .fallback(orParts.map { parseInternal($0, isJSON: isJSON) })
        }

        // ④ `&&` 串接（§S-FBK-02）
        let andParts = Self.splitTopLevel(s, separators: ["&&"])
        if andParts.count > 1 {
            return .concat(andParts.map { parseInternal($0, isJSON: isJSON) })
        }

        // ⑤ ⛔ **不再按逗号拆分**
        //
        // ⚠️⚠️ **逗号是 CSS 选择器并集，不是兜底链** —— 这是 Phase 3 用真书源踩出来的：
        //   `ruleToc.chapterList = ".catalog-section-title,.article-title a||…"`
        //   逗号拆分 ⇒ 第一段（10 个卷标题）命中就停 ⇒ **16 个章节全丢**
        //   ⇒ 现象是「目录只有卷标题、没有章节」。
        // ⇒ 逗号原样交给 CSS 引擎（`select("a,b")` 天然是并集）。
        // ⇒ 真正的兜底链只有 `||`（择一）和 `&&`（串接）。
        //
        // 📌 规格 §S-FBK-03 已据此改写（原写法「逗号多规则回退」是**错的**）。

        return parseSingle(s, isJSON: isJSON)
    }

    // MARK: - 单条规则

    private func parseSingle(_ s: String, isJSON: Bool) -> RuleNode {
        // ① 模式判定
        let mode = RuleClassifier.classify(s, isJSON: isJSON)
        if mode == .empty { return .empty }

        // ② 剥前缀（JSONPath 分支顺带把 `result.` 改写成 `$`）
        var body = RuleClassifier.stripModePrefix(s, mode)

        // ③ 模板插值整条规则（`{{…}}`）⇒ 结果就是这个值（§S-TPL-02）
        if Self.isWholeTemplate(body) {
            return .template(body)
        }

        // ④ 尾部后处理：`##正则##替换` 或 `@js:` 后缀
        if let (head, post) = Self.splitPostProcess(body) {
            body = head
            let inner = parseSingle(body, isJSON: isJSON)
            return .post(inner, post)
        }

        // ④' `@js:` 前缀的规则（尾部 `@js:` 已在上面处理掉）
        if mode == .js, body.hasPrefix("@js:") {
            return .js(String(body.dropFirst(4)))
        }

        // ⑤ 按模式落地
        switch mode {
        case .js:
            return .js(body)
        case .regex:
            let (pattern, replacements) = Self.parseRegexRule(body)
            return .regex(pattern: pattern, replacements: replacements)
        case .jsonPath:
            return .jsonPath(body)
        case .xpath:
            return .xpath(body)
        case .html:
            return .literal(body)
        case .selector:
            return parseSelectorChain(body, isJSON: isJSON)
        case .empty:
            return .empty
        }
    }

    /// ⭐ **取值模式**（`text` / `href` / `html` / …）—— 整条规则就是它时，
    /// 语义是「取**当前节点**的这个值」。
    ///
    /// ⚠️ 与 `text.x`（文本**完全相等**的筛选）**不是一回事**：
    /// - `text.x` ⇒ 筛选：找文本等于 x 的元素
    /// - `text`   ⇒ 取值：取当前节点的文本
    public static func valueMode(of raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        // `all` 是「取全部属性」，不是单值模式 ⇒ 不算
        if s == "all" { return nil }
        return ChainSegmentClassifier.attributeNames.contains(s) ? s : nil
    }

    /// `<js>…</js>` 整块（可能带尾部选择器：`<js>…</js>$.data`）
    private func parseBlock(_ s: String) -> RuleNode {
        // ⭐⭐⭐ **复合规则要在【带标签的原文】里找尾部**（2026-10-24 真机栽的）
        //   以前先 `stripBlockWrapper`（把 `</js>` 也剥了）⇒ 再找 `</js>` **找不到**
        //   ⇒ 复合规则 `<js>代码</js>$.data` 的**尾巴丢了** ⇒ 尾部取值失效 ⭐
        //   ⇒ 而大灰狼的 `ruleToc.chapterList` 正是复合规则 ⭐⭐
        if let (code, tail) = splitJsTail(s) {
            return .jsWithTail(code: code, tail: tail)
        }
        return .jsWithTail(code: stripBlockWrapper(s), tail: nil)
    }

    // MARK: - 默认规则语法链

    /// 解析 `class.book@tag.a@ownText` 这种链。
    ///
    /// ⭐ **头段保留原文**（`head`），链段才做 KW 分类（`steps`）——
    /// 因为两者的翻译规则不同（见 `HeadTranslator` / `SegmentTranslator`）。
    private func parseSelectorChain(_ s: String, isJSON: Bool = false) -> RuleNode {
        var r = s.trimmingCharacters(in: .whitespaces)

        // 站方有时多写一个 `@`：`@a.2@text` / `@class.book` —— 前面这个 @ 只是习惯性前缀
        // ⚠️ 只放过「带尾 @」的别名/变量形式（`@text@` / `@get:{k}`）
        if r.hasPrefix("@"), r.count > 1, r[r.index(r.startIndex, offsetBy: 1)] != "@",
           !r.hasPrefix("@get:"), !r.hasPrefix("@put:"), !r.hasPrefix("@getString:"),
           !r.hasPrefix("@getInt:"), !r.hasPrefix("@text@"), !r.hasPrefix("@html@"),
           !r.hasPrefix("@ownText@"), !r.hasPrefix("@href@"), !r.hasPrefix("@src@"),
           !r.hasPrefix("@tag@"), !r.hasPrefix("@js@") {
            r = String(r.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        let segs = r.components(separatedBy: "@")

        // ⭐⭐ **逗号把规则切成多条完整规则**（每段都带 `@`）⇒ 择一。
        //
        // ⚠️ **两种逗号语义要分清**：
        // - `"tag.h1, tag.h2"`      ⇒ **头段逗号** ⇒ CSS 选择器**并集**（真书源用法）
        // - `"tag.h1@text, tag.h2@text"` ⇒ 逗号把**完整规则**切开 ⇒ **择一**（第一个非空胜出）
        //
        // 判据 = **切开后每段是否都带 `@`**（带 ⇒ 每段是独立完整规则；不带 ⇒ 是 CSS 并集）。
        let commaParts = r.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if commaParts.count > 1, commaParts.allSatisfy({ $0.contains("@") }) {
            return .fallback(commaParts.map { parseSelectorChain($0, isJSON: isJSON) })
        }

        // ⭐⭐ **整条规则就是一个取值模式** ⇒ 「取当前节点的这个值」
        //
        // 站方真实写法（真书源「过期杂志」逐字）：
        //   "chapterName": "text"   ⇒ 取章节节点的文本
        //   "chapterUrl":  "href"   ⇒ 取章节节点的 href
        // ⚠️ 以前这里当成 CSS 标签名去查（`select("text")`）⇒ **永远查不到**。
        //
        // 判定：整条规则**精确等于**一个取值模式名（且没有 `@` 分段）。
        // ⭐⭐⭐⭐⭐ **JSON 基准 ⇒ 不许判「取值模式」**（2026-10-25 真机实证）
        //
        // ⚠️⚠️⚠️ **这是「很多书源都是这样」的通用真凶**：
        //   取值模式的名字表（`text` / `html` / `href` / **`name`** / `title` / `value` /
        //   `type` / `class` / `id` / `alt` …）**全是常见的 JSON 字段名**！⭐⭐⭐
        //   ⇒ 站方 JSON 接口源的字段规则（`"name": "name"` / `"author": "author"`）
        //   ⇒ **被误判成「取值模式」** ⇒ 取值模式**只在 DOM 基准下**有意义
        //   ⇒ JSON 基准 ⇒ `baseNode` = nil ⇒ **「基准类型不符」⇒ 字段取不到** ⭐⭐⭐
        //   ⇒ 症状：书**出得来但书名/作者/书 URL 全空** ⇒ App 判「结果不可信」⇒ emptyResult ⭐⭐⭐
        //
        // ⇒ 修法：**JSON 基准时按 JSON 字段名取**（不是取值模式）⭐⭐⭐
        //   ⇒ 与「JSON 基准上的裸字段名要相对当前对象取」是同一条语义 ⭐
        if segs.count == 1, !isJSON, let mode = Self.valueMode(of: segs[0]) {
            return .value(mode: mode)
        }

        // ⭐ 头段也可能带索引（`tag.li.0` 整条就是头段）⇒ 拆出来
        let (head, headIndex) = ChainSegmentClassifier.splitIndex(segs.first ?? "")
        var steps: [ChainStep] = []

        for rawSeg in segs.dropFirst() {
            var seg = rawSeg
            // 剥掉排除后缀 `!0:1:2`（§S-EXCL-01：排除**第 N 个**，0-based）
            var exclusion: [Int] = []
            if let bang = seg.lastIndex(of: "!") {
                let tail = String(seg[seg.index(after: bang)...])
                let nums = tail.components(separatedBy: ":").compactMap { Int($0) }
                if !nums.isEmpty {
                    exclusion = nums
                    seg = String(seg[..<bang])
                }
            }
            if seg.isEmpty { continue }
            steps.append(ChainSegmentClassifier.classify(segment: seg, exclusion: exclusion))
        }
        return .chain(head: head, headIndex: headIndex, steps: steps)
    }

    // MARK: - 工具

    /// 顶层切分 —— 只在**不在**引号/括号/花括号内部时切。
    ///
    /// ⚠️ 这是最容易写错的一段：`result.tab || '小说'` 这种站方 JS 里本来就有 `||`，
    /// 切错就整条规则废了（轻阅 build146 踩过）。
    public static func splitTopLevel(_ s: String, separators: [String]) -> [String] {
        var out: [String] = []
        var buf = ""
        var depthParen = 0, depthBracket = 0, depthBrace = 0
        var quote: Character? = nil
        var escaped = false
        var i = s.startIndex

        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)

            if escaped {
                buf.append(c); escaped = false; i = next; continue
            }
            if c == "\\" {
                buf.append(c); escaped = true; i = next; continue
            }
            if let q = quote {
                buf.append(c)
                if c == q { quote = nil }
                i = next; continue
            }
            if c == "\"" || c == "'" || c == "`" {
                quote = c; buf.append(c); i = next; continue
            }
            switch c {
            case "(": depthParen += 1
            case ")": depthParen = max(0, depthParen - 1)
            case "[": depthBracket += 1
            case "]": depthBracket = max(0, depthBracket - 1)
            case "{": depthBrace += 1
            case "}": depthBrace = max(0, depthBrace - 1)
            default: break
            }

            if depthParen == 0 && depthBracket == 0 && depthBrace == 0 {
                var matched = false
                for sep in separators {
                    if s[i...].hasPrefix(sep) {
                        out.append(buf)
                        buf = ""
                        i = s.index(i, offsetBy: sep.count)
                        matched = true
                        break
                    }
                }
                if matched { continue }
            }
            buf.append(c)
            i = next
        }
        out.append(buf)
        return out
    }

    /// `##pattern##replace1##replace2##` ⇒ (pattern, replacements)
    public static func parseRegexRule(_ rule: String) -> (String, [String]) {
        let parts = rule.components(separatedBy: "##")
        var ops: [String] = []
        if parts.count > 1 {
            for idx in 1..<parts.count {
                if parts[idx].isEmpty && idx == parts.count - 1 { continue }
                ops.append(parts[idx])
            }
        }
        let pattern = ops.first ?? ""
        let replacements = ops.count > 1 ? Array(ops.dropFirst()) : []
        return (pattern, replacements)
    }

    /// 拆出尾部后处理（`##正则##` 或 `@js:`）
    public static func splitPostProcess(_ s: String) -> (String, RuleNode.PostProcess)? {
        // `@js:` 后缀
        if let idx = s.range(of: "@js:", options: .backwards) {
            // ⭐⭐⭐ **head 要连换行一起 trim**（2026-10-27 真机实证）
            //   站方复合规则是**换行分隔**的：`videoId||id` ⏎ `@js:…`
            //   ⇒ head = `"videoId||id\n"` ⇒ 尾换行留着 ⇒
            //     · JSON 相对路径被**误判成 CSS 选择器**（`id\n` 不是合法 JSONPath）⇒ 空 ⭐⭐⭐
            //     · 「|| 兜底链全部未命中」= 真机那行诊断 ⭐⭐⭐
            //   ⇒ 老引擎是 `body.slice(0, idx).trim()`（**JS 的 trim 连换行一起**）⇒ 照抄 ⭐⭐⭐
            let head = String(s[..<idx.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let code = String(s[idx.upperBound...])
            if !head.isEmpty { return (head, .js(code)) }
        }
        // ⭐⭐ `<js>…</js>` **块**（站方的「路径 + JS 后处理」复合形态）
        //
        // 真书源实测（125 源里 4 处）：
        //   `$.uptime<js>java.getString('$.last_chapter_name')+' '+…</js>`
        //   `$.data.chapterList[0].volumeList<js>java.put(…);result</js>`
        //   `$.chapterArticle\n<js>doc=org.jsoup.Jsoup.parse(result)…</js>`
        //
        // ⚠️⚠️⚠️ **以前这里取错了区间**（注释写着「已支持」，实现其实没支持）：
        //   旧代码取的是 **`</js>` 之后**的片段 ⇒
        //     head = `$.data.list<js>result.map(…)`（**把 JS 代码也留在头里**）
        //     code = `""`（**空的**）
        //   ⇒ AST 变成 `post(jsonPath("整串"), js(""))`
        //   ⇒ 主体求值失败（JSONPath 语法不支持）⇒ **静默空**
        // ⇒ **规格/注释写了 ≠ 实现做了**（又一次现场教学）
        //
        // ✅ 正确切法：head = `<js>` **之前**；code = `<js>` 与 `</js>` **之间**；
        //             tail = `</js>` **之后**（可空 ⇒ 还能再接尾部选择器）
        if let open = s.range(of: "<js>", options: .backwards),
           let close = s.range(of: "</js>", options: .backwards),
           open.lowerBound < close.lowerBound {
            let head = String(s[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let code = String(s[open.upperBound..<close.lowerBound])
            let tail = String(s[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty {
                return (head, .jsWithTail(code: code, tail: tail.isEmpty ? nil : tail))
            }
        }

        // `##正则##替换`
        if let idx = s.range(of: "##") {
            let head = String(s[..<idx.lowerBound]).trimmingCharacters(in: .whitespaces)
            let tail = String(s[idx.lowerBound...])
            if !head.isEmpty {
                // ⭐ **存 tail 原文（含前导 `##`）** —— 这样才能区分
                //   `##正则`      ⇒ 删除匹配部分
                //   `##正则##替换` ⇒ 替换
                // 以前在这里把 tail 拆开又拼回去 ⇒ 「无替换」的信息丢了
                // ⇒ `applyPost` 拿到空 pattern ⇒ **整条规则变空**（真书源
                //   `ruleContent.content = "tag.p@html##我爱读者校园网"` 直接踩中）⭐
                return (head, .regex(tail))
            }
        }
        return nil
    }

    /// 整条规则是不是一个 `{{…}}`
    public static func isWholeTemplate(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("{{"), t.hasSuffix("}}") else { return false }
        // 找配对的 }}
        var depth = 0
        let chars = Array(t)
        var i = 0
        while i < chars.count {
            if chars[i] == "{", i + 1 < chars.count, chars[i + 1] == "{" { depth += 1; i += 2; continue }
            if chars[i] == "}", i + 1 < chars.count, chars[i + 1] == "}" {
                depth -= 1; i += 2
                if depth == 0 { return i == chars.count }
                continue
            }
            i += 1
        }
        return false
    }

    private func stripBlockWrapper(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["<js>", "<JS>"] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        // ⚠️⭐⭐⭐ **必须 `dropLast`**（2026-10-24 真机栽的）
        //   以前写的是 `dropFirst(t.count - p.count)` ⇒ 那是**删前缀、留尾巴**
        //   ⇒ 整段站方 JS 被扔光，**只剩 `</js>`** ⇒ 喂给 JS 就是 `</js>`
        //   ⇒ `SyntaxError: Unexpected token '<'` ⇒ **规则的 JS 从来没跑过** ⭐⭐⭐
        //   ⇒ 大灰狼的 `ruleExplore.bookUrl`（`<js>…</js>`）⇒ bookUrl 恒空
        //   ⇒ 详情/目录/正文全断 ⭐
        for p in ["</js>", "</JS>"] where t.hasSuffix(p) { t = String(t.dropLast(p.count)) }
        return t
    }

    /// `<js>代码</js>$.data` ⇒ (代码, 尾部)
    private func splitJsTail(_ body: String) -> (String, String)? {
        // 找 `</js>` 之后的尾巴（**body 是带标签的原文** ⇒ 见 parseBlock 的注释）
        guard let close = body.range(of: "</js>", options: .caseInsensitive)
                ?? body.range(of: "</JS>", options: .caseInsensitive) else { return nil }
        // ⚠️ **要连换行一起 trim**（`whitespaces` 不含 `\n` ⇒ 尾巴会带着前导换行
        //   ⇒ 尾巴是 `\n$.data` ⇒ 后面当选择器/JSONPath 用会出问题）⭐
        let tail = String(body[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        var code = String(body[..<close.lowerBound])
        // ⚠️ code 里还带着开头的 `<js>` ⇒ 要去掉
        for p in ["<js>", "<JS>"] where code.hasPrefix(p) { code = String(code.dropFirst(p.count)) }
        return (code, tail)
    }
}

// MARK: - 复合规则的尾部

extension RuleNode {
    /// 取出 JS 复合规则的尾部（若有）。
    public var jsTail: String? {
        if case .jsWithTail(_, let tail) = self { return tail }
        if case .post(let inner, _) = self { return inner.jsTail }
        return nil
    }
}
