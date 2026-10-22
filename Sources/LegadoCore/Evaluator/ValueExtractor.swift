import Foundation

/// **取值器** —— 从 DOM 节点上按「取值模式」取值。
///
/// 规格：`docs/legado-semantics.md` §S-SEL-04。
///
/// ⚠️ **已知差异（已在规格里记）**：
/// Legado/Jsoup 的 `@html` = **innerHTML**；轻阅把 `html` 和 `outerhtml` 都映射成 outerHTML。
/// ⇒ 本实现按 **Legado 语义**。
public enum ValueExtractor {

    /// 取值
    /// - Parameters:
    ///   - node: 节点
    ///   - mode: 取值模式（`nil` = 完整文本）
    ///   - baseURL: 基准 URL（URL 属性要绝对化）
    public static func value(_ node: DOMNode, mode: ValueMode?, baseURL: String) -> String {
        guard let mode else { return node.textContent }
        switch mode {
        case .text:            return node.textContent
        case .ownText:         return node.ownTextContent
        case .html:            return innerHTML(of: node)
        case .outerHTML:       return node.outerHTML
        case .tag:             return node.tagName
        case .all:             return node.outerHTML
        case .attribute(let n): return decodeEntities(node.attribute(n) ?? "")
        case .urlAttribute(let n):
            let raw = decodeEntities(node.attribute(n) ?? "")
            return raw.isEmpty ? "" : absolutize(raw, baseURL: baseURL)
        }
    }

    /// 内层 HTML —— Jsoup `html()`。
    ///
    /// ⚠️ `DOMNode` 协议没强制要 innerHTML ⇒ 通过 `outerHTML` 去掉外层标签近似。
    /// 生产实现（SwiftSoupNode）覆写得更准。
    public static func innerHTML(of node: DOMNode) -> String {
        if let ss = node as? SwiftSoupNode { return ss.innerHTML }
        return node.outerHTML
    }

    /// 相对地址绝对化（轻阅 `absolutize` 语义）
    public static func absolutize(_ path: String, baseURL: String) -> String {
        let u = path.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return "" }
        if u.hasPrefix("http://") || u.hasPrefix("https://") || u.hasPrefix("//")
            || u.hasPrefix("file://") || u.hasPrefix("data:") { return u }
        guard !baseURL.isEmpty else { return u }
        if u.hasPrefix("/") {
            // 取 scheme://host 部分（⚠️ 斜杠要从 "://" **之后**找，否则 "https://" 自己被截断）
            var s = ""
            if let range = baseURL.range(of: "://") {
                s = String(baseURL[baseURL.startIndex...range.upperBound])
                let tail = baseURL[range.upperBound...]
                if let slash = tail.firstIndex(of: "/") {
                    s = String(baseURL[baseURL.startIndex..<slash])
                }
            }
            return s + u
        }
        if let base = URL(string: baseURL), let resolved = URL(string: u, relativeTo: base) {
            return resolved.absoluteURL.absoluteString
        }
        return u
    }

    /// HTML 实体解码（轻阅 `decodeEntities` 语义）。
    ///
    /// ⚠️ 核心层保持**纯 Foundation** ⇒ 不能用 DOM 解 ⇒ 自己实现。
    /// ⚠️ 只解**文本级**实体（`&amp; &lt; &gt; &quot; &apos; &nbsp;` + 数字实体），
    /// 不解会改变结构的实体（`&lt;script&gt;` 不该被还原成标签）。
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            rest = rest[rest.index(after: amp)...]
            guard let semi = rest.firstIndex(of: ";") else {
                out += "&" + rest
                return out
            }
            // 实体名不能太长 ⇒ 防误判
            let name = rest[rest.startIndex..<semi]
            guard name.count <= 12, !name.isEmpty else {
                out += "&" + rest
                return out
            }
            if let replacement = entityValue(String(name)) {
                out += replacement
                rest = rest[semi...]
            } else {
                out += "&"
                rest = rest[rest.startIndex...]
            }
        }
        out += rest
        return out
    }

    private static func entityValue(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = String(name.dropFirst())
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                guard let v = UInt32(digits.dropFirst(), radix: 16), let s = Unicode.Scalar(v) else { return nil }
                return String(Character(s))
            }
            guard let v = UInt32(digits), let s = Unicode.Scalar(v) else { return nil }
            return String(Character(s))
        }
        switch name {
        case "amp":    return "&"
        case "lt":     return "<"
        case "gt":     return ">"
        case "quot":   return "\""
        case "apos":   return "'"
        case "nbsp":   return "\u{00A0}"
        case "hellip": return "…"
        case "mdash":  return "—"
        case "ndash":  return "–"
        case "ldquo":  return "\u{201C}"
        case "rdquo":  return "\u{201D}"
        case "lsquo":  return "\u{2018}"
        case "rsquo":  return "\u{2019}"
        default: return nil
        }
    }
}
