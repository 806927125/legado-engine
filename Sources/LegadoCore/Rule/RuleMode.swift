import Foundation

/// 规则模式 —— 一条规则字符串属于哪一类，决定它被谁求值。
///
/// 规格：`docs/legado-semantics.md` §S-CLS（19 条）。
///
/// ⭐ **判定顺序严格自上而下，先匹配先赢。**
public enum RuleMode: String, Sendable, CaseIterable {
    case js        // @js: / <js>…</js>
    case regex     // ##pattern##replace##
    case jsonPath = "jsonpath"  // @Json: / $. / result.
    case xpath     // @XPath: / 以 / 开头
    case html      // 以 < 开头
    case selector  // @CSS: / @@ / 其余
    case empty
}

/// 模式判定器。
///
/// 这份实现是**照着规格写的**，不是照着轻阅的 JS 抄的 —— 目的是让两套实现**独立**，
/// 然后用同一份 fixture **对拍**（见 `conformance/`）。
/// 对拍能过 ⇒ 说明两边语义一致；对拍不过 ⇒ 有一边是错的，差异就是线索。
public enum RuleClassifier {

    /// §S-CLS-01 ~ §S-CLS-13
    public static func classify(_ raw: String?, isJSON: Bool = false) -> RuleMode {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .empty }

        // ① @js: / @JS:
        if s.hasPrefix("@js:") || s.hasPrefix("@JS:") { return .js }
        // ② <js> / <JS>
        if s.hasPrefix("<js>") || s.hasPrefix("<JS>") { return .js }
        // ③ ##
        if s.hasPrefix("##") { return .regex }

        // ④ @CSS:（大小写不敏感）
        if hasPrefixCI("@CSS:", s) { return .selector }
        // ⑤ @@
        if s.hasPrefix("@@") { return .selector }
        // ⑥ @XPath:（大小写不敏感）
        if hasPrefixCI("@XPath:", s) { return .xpath }
        // ⑦ @Json:（大小写不敏感）
        if hasPrefixCI("@Json:", s) { return .jsonPath }

        // ⑧ 响应是 JSON **且**规则以 $ 开头
        //    ⚠️ 必须同时要求「以 $ 开头」—— 否则 JSON 响应里的值类型规则
        //    （`{{$.grade}}分`）会被硬塞进 JSONPath 解析器 → 一律返回空
        if isJSON && s.hasPrefix("$") { return .jsonPath }
        // ⑨ $. / $[
        if s.hasPrefix("$.") || s.hasPrefix("$[") { return .jsonPath }
        // ⑩ result. / result[   ← 125 源里 130 处
        if hasPrefixCI("result.", s) || hasPrefixCI("result[", s) { return .jsonPath }
        // ⑪ 以 / 开头 ⇒ XPath（Legado 原注释：XPath 特征很明显）
        if s.hasPrefix("/") { return .xpath }
        // ⑫ 以 < 开头 ⇒ HTML
        if s.hasPrefix("<") { return .html }
        // ⑬ 兜底
        return .selector
    }

    /// 剥掉模式前缀，把真正的规则体交回给解析器。
    /// - ⑨ result. 前缀要**改写成 $**（§S-CLS-10 / §S-JSON-03）
    public static func stripModePrefix(_ rule: String, _ mode: RuleMode) -> String {
        switch mode {
        case .xpath:
            return stripPrefixCI("@XPath:", rule)
        case .jsonPath:
            return rewriteResultPath(stripPrefixCI("@Json:", rule))
        case .selector:
            var r = stripPrefixCI("@CSS:", rule)
            if r.hasPrefix("@@") { r = String(r.dropFirst(2)) }
            return r
        default:
            return rule
        }
    }

    /// `result.` / `result[` → `$` / `[`，**每个 `||` 分段都要改**。
    ///
    /// 规格 §S-JSON-03。125 源实例：`result.resultList||result.bookList`。
    public static func rewriteResultPath(_ rule: String) -> String {
        rule.components(separatedBy: "||").map { seg -> String in
            let t = seg.trimmingCharacters(in: .whitespaces)
            guard let range = t.range(of: "^result\\b", options: .regularExpression) else { return seg }
            var out = t
            out.replaceSubrange(range, with: "$")
            return out
        }.joined(separator: "||")
    }

    // MARK: - 私有

    private static func hasPrefixCI(_ prefix: String, _ s: String) -> Bool {
        s.lowercased().hasPrefix(prefix.lowercased())
    }

    private static func stripPrefixCI(_ prefix: String, _ s: String) -> String {
        guard hasPrefixCI(prefix, s) else { return s }
        return String(s.dropFirst(prefix.count))
    }
}
