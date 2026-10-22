import Foundation

/// 规则的 **AST**（抽象语法树）。
///
/// 规格：`docs/legado-semantics.md`。
///
/// ⭐ **为什么要 AST 而不是边扫边执行**：
/// 轻阅的规则解析散落在 `rule-analyzer.js` / `jsoup-compat.js` / `engine.js` 三个文件里
/// （`parseRule` / `splitTopLevel` / `stripModeTail` / `splitTopLevelRules`），
/// 逻辑重叠且不一致 —— 同一个 `||` 在三处有不同的切法。
/// ⇒ AST 化的收益：
/// 1. **规则可缓存**（解析一次，AST 复用）—— 每次请求重新扫字符串是纯浪费
/// 2. **语义统一**（`||` / `&&` / `,` 只有一处实现）
/// 3. **可测**（"这个规则串解析成什么 AST"是纯函数，能做快照测试）
public indirect enum RuleNode: Sendable, Equatable {
    /// 空规则
    case empty
    /// 字面量（模板插值后的值、URL 常量…）
    case literal(String)
    /// CSS 选择器
    case css(String)
    /// XPath
    case xpath(String)
    /// JSONPath
    case jsonPath(String)
    /// 正则：`##pattern##replace1##replace2##`
    case regex(pattern: String, replacements: [String])
    /// 站方 JS（`@js:`）
    case js(String)
    /// **复合规则**：站方 JS 跑完后，用尾部选择器再取一次值
    ///
    /// 规格 §S-JSON-05：`<js>代码</js>$.data`
    /// ⚠️ `tail == nil` 是**合法**的 —— 纯 `<js>` 没有尾部时，
    /// **结果就是 JS 自己返回的列表**（轻阅 build211 修过这条：以前直接毙掉 ⇒ 目录 0 章）。
    case jsWithTail(code: String, tail: String?)
    /// 二次解析（`@@` 前缀）
    case reparse(RuleNode)
    /// 模板插值（`{{…}}`）
    case template(String)
    /// `||` 择一 —— 逐个求值，第一个非空胜出（§S-FBK-01）
    case fallback([RuleNode])
    /// `&&` 串接 —— 依次求值并拼接（§S-FBK-02）
    case concat([RuleNode])
    /// 逗号分隔多规则回退 —— 第一个非空胜出（§S-FBK-03）
    case alternatives([RuleNode])
    /// 默认规则语法链（`class.book@tag.a@ownText`）
    ///
    /// ⭐ **头段保留原文** —— 因为头段和链段的翻译规则**不一样**：
    /// 头段走 `prefixToCss`（无前缀就原样当纯 CSS），链段走 KW 分类。
    /// 混成一个分类器 ⇒ 纯 CSS 的 `dl.B dd` 会被误判成属性名。
    /// - Parameter headIndex: **头段**的索引（`tag.li.0` ⇒ 头段 "tag.li" + 索引 0）
    case chain(head: String, headIndex: Int?, steps: [ChainStep])
    /// 尾部后处理（`##正则##` 或 `@js:` 后缀）作用在主体上
    case post(RuleNode, PostProcess)

    /// 尾部后处理
    public enum PostProcess: Sendable, Equatable {
        /// `##正则##替换`（替换可为空 = 删除；支持 $1..$n）
        case regex(String)
        /// `@js:代码`（以主体结果为 `result`）
        case js(String)
    }
}

/// 链里的一步。
///
/// 规格 §S-SEL-03 ~ §S-SEL-06 ⭐（**S-SEL-06 是重量级债**）。
public enum ChainStep: Sendable, Equatable {
    /// 子元素选择器
    /// - Parameter selector: `"tag:li"` / `"class:x y"` / `"id:x"`（由 `ChainSegmentClassifier` 产出）
    /// - Parameter exclusion: **排除第 N 个**（0-based，§S-EXCL-01）
    case sub(selector: String, index: Int?, exclusion: [Int])
    /// 属性后缀（`text` / `html` / `href` / `src` / …）
    case attr(String)
}

/// ⭐ **链段的分类**（本项目最关键的一条判定）。
///
/// 规格 §S-SEL-06：
/// 链段是**裸 HTML 标签名**（`li` / `a` / `img` / `span` / `p` / `dd` / `h2` / `ul` / `tr` …）
/// ⇒ 语义是「**在上一段结果内找这种子元素**」。
///
/// **只有属性白名单**才是属性后缀。
///
/// ⚠️ 轻阅的错法（`jsoup-compat.js:218`）：要求「必须有 `kw.` 前缀」才算子选择器，
/// 裸名一律当属性 ⇒ **125 源里 279 处、60 个源（48%）的链断掉**。
public enum ChainSegmentClassifier {

    /// Legado 的属性后缀白名单。
    ///
    /// ⚠️ 这个白名单必须**最小且明确** —— 名单外的裸名一律当子选择器。
    /// 125 源实测的属性后缀用法：`text` `html` `href` `src` `content` `ownText` `outerHtml` `all`。
    public static let attributeNames: Set<String> = [
        "text", "html", "outerhtml", "innerhtml", "owntext", "all",
        "href", "src", "title", "value", "class", "id", "alt", "name", "type",
    ]

    /// 判定一个链段（已剥掉 `!N` 排除后缀）是什么。
    public static func classify(segment raw: String, exclusion: [Int] = []) -> ChainStep {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return .attr(raw) }

        // ⓿ 简写前缀：`.class` / `#id` ⇒ 子选择器（**点/井在开头，不是分隔符**）
        if s.hasPrefix(".") {
            let (val, index) = splitIndex(String(s.dropFirst()))
            return .sub(selector: "class:\(val)", index: index, exclusion: exclusion)
        }
        if s.hasPrefix("#") {
            let (val, index) = splitIndex(String(s.dropFirst()))
            return .sub(selector: "id:\(val)", index: index, exclusion: exclusion)
        }

        // ① 带前缀的：`tag.` / `class.` / `id.` ⇒ 子选择器
        //    ⚠️ 只认**非首位**的 `.`（`.sidebar` 是简写，`class.book` 是前缀）
        if let dot = s.firstIndex(of: "."), dot != s.startIndex {
            let kw = String(s[s.startIndex..<dot]).lowercased()
            let val = String(s[s.index(after: dot)...])
            let (val2, index) = splitIndex(val)
            switch kw {
            case "tag":   return .sub(selector: "tag:\(val2)", index: index, exclusion: exclusion)
            case "class": return .sub(selector: "class:\(val2)", index: index, exclusion: exclusion)
            case "id":    return .sub(selector: "id:\(val2)", index: index, exclusion: exclusion)
            case "text":  return .sub(selector: "text:\(val2)", index: index, exclusion: exclusion)
            case "owntext": return .sub(selector: "owntext:\(val2)", index: index, exclusion: exclusion)
            default:      break
            }
        }

        // ② 属性白名单 ⇒ 属性后缀
        let lower = s.lowercased()
        if attributeNames.contains(lower) { return .attr(lower) }

        // ③ ⭐ 裸 HTML 标签名 ⇒ **子元素选择器**（§S-SEL-06）
        if HTMLTagNames.contains(lower) { return .sub(selector: "tag:\(s)", index: nil, exclusion: exclusion) }

        // ④ 其它裸名（`data-src` / `data-origin` 之类）⇒ 属性后缀
        return .attr(s)
    }

    /// `tag.div.0` ⇒ 去掉末尾的 `.0`（索引），`tag.div[-1]` 同理
    static func splitIndex(_ val: String) -> (String, Int?) {
        if let dot = val.lastIndex(of: ".") {
            let tail = String(val[val.index(after: dot)...])
            if let n = Int(tail) { return (String(val[..<dot]), n) }
        }
        if val.hasSuffix("]"), let open = val.lastIndex(of: "["),
           let n = Int(val[val.index(after: open)..<val.index(before: val.endIndex)]) {
            return (String(val[..<open]), n)
        }
        return (val, nil)
    }
}
