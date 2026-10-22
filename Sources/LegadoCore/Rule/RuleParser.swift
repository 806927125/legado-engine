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
    public func parse(_ raw: String?, isJSON: Bool = false) -> RuleNode {
        // ⭐ **顶层入口走缓存**（§S-EVAL-11）
        guard let cache else { return parseInternal(raw, isJSON: isJSON) }
        let key = RuleCache.Key(rule: raw ?? "", isJSON: isJSON)
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

        // ⑤ 逗号分隔多规则回退（§S-FBK-03）
        let commaParts = Self.splitTopLevel(s, separators: [","])
        if commaParts.count > 1 {
            return .alternatives(commaParts.map { parseInternal($0, isJSON: isJSON) })
        }

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
            return parseSelectorChain(body)
        case .empty:
            return .empty
        }
    }

    /// `<js>…</js>` 整块（可能带尾部选择器：`<js>…</js>$.data`）
    private func parseBlock(_ s: String) -> RuleNode {
        let body = stripBlockWrapper(s)
        // 复合规则：`<js>代码</js>$.data` ⇒ JS 跑完再用尾部取值
        if let (code, tail) = splitJsTail(body) {
            return .jsWithTail(code: code, tail: tail)
        }
        return .jsWithTail(code: body, tail: nil)
    }

    // MARK: - 默认规则语法链

    /// 解析 `class.book@tag.a@ownText` 这种链。
    ///
    /// ⭐ **头段保留原文**（`head`），链段才做 KW 分类（`steps`）——
    /// 因为两者的翻译规则不同（见 `HeadTranslator` / `SegmentTranslator`）。
    private func parseSelectorChain(_ s: String) -> RuleNode {
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
            let head = String(s[..<idx.lowerBound]).trimmingCharacters(in: .whitespaces)
            let code = String(s[idx.upperBound...])
            if !head.isEmpty { return (head, .js(code)) }
        }
        // `##正则##替换`
        if let idx = s.range(of: "##") {
            let head = String(s[..<idx.lowerBound]).trimmingCharacters(in: .whitespaces)
            let tail = String(s[idx.lowerBound...])
            if !head.isEmpty {
                let (pattern, reps) = parseRegexRule(tail)
                let joined = reps.isEmpty ? "" : reps.joined(separator: "##")
                return (head, .regex(joined.isEmpty ? pattern : pattern + "##" + joined))
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
        for p in ["</js>", "</JS>"] where t.hasSuffix(p) { t = String(t.dropFirst(t.count - p.count)) }
        return t
    }

    /// `<js>代码</js>$.data` ⇒ (代码, 尾部)
    private func splitJsTail(_ body: String) -> (String, String)? {
        // 找 `</js>` 之后的尾巴
        guard let close = body.range(of: "</js>", options: .caseInsensitive)
                ?? body.range(of: "</JS>", options: .caseInsensitive) else { return nil }
        let code = String(body[..<close.lowerBound])
        let tail = String(body[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? nil : (code, tail)
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
