import Foundation

/// **URL 规则解析**（Legado `AnalyzeUrl` / 栖阅 `AnalyzeUrl` 语义）。
///
/// 规格：`docs/legado-semantics.md` §S-URL。
///
/// ⭐ **这是请求构造的语义核心** —— 规则里的 URL 决定：
/// 用什么 method、带什么 headers、body 是什么、query 怎么编码。
///
/// ## 三条最要紧的语义（都是踩过的坑）
///
/// 1. ⭐ **query 重新编码对【所有方法】做**
///    只给 GET 编码 ⇒ 站方 POST 的 query 带**裸中文 + 裸 JSON**
///    ⇒ iOS 的 `URL(string:)` 判非法（返回 nil）⇒ **请求压根没发出去**
///    ⇒ 引擎把失败吞成空串 ⇒ 站方 `JSON.parse('')` ⇒「Unable to parse JSON string」
///
/// 2. ⭐ **`+` 必须编码成 `%2B`**
///    留着 `+` ⇒ 服务器按 form 解码 query 时 `'+'` 变**空格**
///    ⇒ base64 的 `book_id` 被损坏 ⇒ **有的书能开、有的书开不了**（最难查的那类）
///
/// 3. ⭐ **`data:` / `blob:` / 自定义 scheme 必须原样返回**
///    聚合源的书籍/目录 URL 是 `data:;base64,<载荷>,{"type":"qingtian"}`
///    ⇒ 载荷是 base64（**没有 `&`**）⇒ 百分号编码会把载荷里的 `+` `/` 改掉 ⇒ 站方解不出 JSON
public enum URLBuilder {

    /// 解析出来的请求
    public struct Built: Sendable, Equatable {
        /// 最终 URL（已绝对化 + 已编码）
        public var url: String
        /// HTTP method（大写）
        public var method: String
        /// 请求头（已补 Content-Type）
        public var headers: [String: String]
        /// 请求体（GET 时为空）
        public var body: String
        /// 基准 URL（目录部分）
        public var baseUrl: String

        public init(url: String, method: String, headers: [String: String], body: String, baseUrl: String) {
            self.url = url; self.method = method; self.headers = headers
            self.body = body; self.baseUrl = baseUrl
        }
    }

    // MARK: - 主入口

    /// 解析一条 URL 规则
    ///
    /// - Parameters:
    ///   - raw: 规则里的 URL（可能带 `,{json}` 选项后缀）
    ///   - baseUrl: 基准 URL（相对地址绝对化用）
    /// ⭐ **原样返回（不做百分号编码）的 scheme 白名单**。
    ///
    /// ⚠️ **不能放行「所有自定义 scheme」** —— 我第一版那么写，结果 **`https:` 也被当成自定义 scheme**
    /// ⇒ 整个 URL 原样返回 ⇒ query 里的裸中文不编码 ⇒ 请求发不出去。
    /// ⇒ 改成**白名单**：默认只放行 `data` / `blob`（Legado 标准），宿主可追加自己的。
    public static let passthroughSchemes: Set<String> = ["data", "blob"]

    public static func parse(_ raw: String, baseUrl: String,
                             passthroughSchemes: Set<String> = URLBuilder.passthroughSchemes) -> Built {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // ⓿ 白名单里的 scheme ⇒ **原样返回**
        //    ⚠️ 百分号编码会把 base64 载荷里的 `+` `/` 改掉 ⇒ 站方解不出 JSON
        if isPassthroughScheme(lower, passthroughSchemes) {
            return Built(url: trimmed, method: "GET", headers: [:], body: "", baseUrl: trimmed)
        }

        // ① 切选项后缀 `,{json}`（**只有逗号后紧跟 `{` 才算**）
        let (urlPart, options) = splitOptions(raw)

        // ② method
        let method = (options["method"] as? String ?? "GET").uppercased()

        // ③ headers
        var headers: [String: String] = [:]
        if let h = options["headers"] as? [String: Any] {
            for (k, v) in h { headers[k] = String(describing: v) }
        }

        // ④ body：对象 → JSON 串；字符串 → 原样
        var body = ""
        var isJsonBody = false
        if let b = options["body"] {
            if b is [String: Any] || b is [Any] {
                if let d = try? JSONSerialization.data(withJSONObject: b),
                   let s = String(data: d, encoding: .utf8) {
                    body = s; isJsonBody = true
                }
            } else if let s = b as? String {
                body = s
            } else {
                body = String(describing: b)
            }
        }

        // ⑤ 绝对化 + query 重新编码（**所有方法**）
        var abs = absolutize(urlPart, baseUrl: baseUrl)
        if let q = abs.firstIndex(of: "?"), q != abs.index(before: abs.endIndex) {
            let query = String(abs[abs.index(after: q)...])
            abs = String(abs[..<q]) + "?" + analyzeFields(query)
        }
        // ⑥ URL 里的非法字符（裸中文等）→ 百分号编码
        abs = smartPercentEncode(abs)

        // ⑦ GET ⇒ 不要 body
        if method == "GET" { body = "" }

        // ⑧ Content-Type（**已有就不覆盖** —— 站方显式指定的要尊重）
        if !body.isEmpty {
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if isJsonBody || t.hasPrefix("{") || t.hasPrefix("[") {
                if !hasHeader(headers, "Content-Type") {
                    headers["Content-Type"] = "application/json; charset=utf-8"
                }
            } else {
                body = analyzeFields(body)
                if !hasHeader(headers, "Content-Type") {
                    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
                }
            }
        }

        return Built(url: abs, method: method, headers: headers, body: body, baseUrl: dirOf(abs))
    }

    // MARK: - 字段编码（Legado `analyzeFields`）

    /// 查询串 / 表单体的字段编码。
    ///
    /// - `=` `&` 原样保留（结构符）
    /// - 已经合法的 `%XX` **不重复编码**
    /// - **`+` → `%2B`**（⚠️ 留着 `+` 的话，服务器 form 解码时会变成**空格**）
    /// - 字母数字与 `-._` 保留，其余按 UTF-8 字节 `%XX`
    public static func analyzeFields(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count * 2)
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%" && i + 2 < chars.count,
               isHexDigit(chars[i + 1]), isHexDigit(chars[i + 2]) {
                // 已是合法百分号编码 ⇒ 原样
                out.append("%")
                out.unicodeScalars.append(chars[i + 1])
                out.unicodeScalars.append(chars[i + 2])
                i += 3
                continue
            }
            if c == "=" || c == "&" {
                out.unicodeScalars.append(c); i += 1; continue
            }
            if isPlainFieldChar(c) {
                out.unicodeScalars.append(c); i += 1; continue
            }
            // 其余按 UTF-8 字节 %XX
            for b in String(c).utf8 {
                out += String(format: "%%%02X", b)
            }
            i += 1
        }
        return out
    }

    // MARK: - URL 编码（栖阅 `smartPercentEncode`）

    /// URL 里的**非法字符**百分号编码。
    /// ⚠️ 只动 URL 本身**不在合法集**里的字符；已有的 `%XX` 不重复编码。
    public static func smartPercentEncode(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%" && i + 2 < chars.count,
               isHexDigit(chars[i + 1]), isHexDigit(chars[i + 2]) {
                out.append("%")
                out.unicodeScalars.append(chars[i + 1])
                out.unicodeScalars.append(chars[i + 2])
                i += 3
                continue
            }
            if isURLChar(c) {
                out.unicodeScalars.append(c); i += 1; continue
            }
            for b in String(c).utf8 {
                out += String(format: "%%%02X", b)
            }
            i += 1
        }
        return out
    }

    // MARK: - URL 工具

    /// 相对地址 → 绝对地址
    ///
    /// ⚠️ **用 Foundation 解析**（不用手搓字符串拼接）⇒ 跟真机同一套 ⇒ 沙盒验的就是真机的行为。
    /// ⇒ 协议相对地址 `//cdn.x/a.png` ⇒ 会补上 baseUrl 的 scheme。
    public static func absolutize(_ raw: String, baseUrl: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        if let u = URL(string: s), u.scheme != nil { return u.absoluteString }
        if baseUrl.isEmpty { return s }
        guard let b = URL(string: baseUrl) else { return s }
        if let u = URL(string: s, relativeTo: b)?.absoluteURL { return u.absoluteString }
        return s
    }

    /// 取 URL 的目录部分（`https://x.com/a/b.html` → `https://x.com/a/`）
    public static func dirOf(_ raw: String) -> String {
        guard let u = URL(string: raw) else { return raw }
        var dir = u.deletingLastPathComponent()
        dir.appendPathComponent("")
        return dir.absoluteString
    }

    /// 切掉站方的 URL 选项后缀 `,{...}`
    ///
    /// ⚠️ **从左往右扫，找【第一个】逗号**（不是最后一个！）——
    /// ⚠️ 我第一版用了 `lastIndex` ⇒ 对 `url,{"method":"POST","body":{...}}`
    /// 最后一个逗号在 `"POST",` 后面 ⇒ tail 不是 `{` 开头 ⇒ **选项拆不出来** ⇒
    /// method/body 全丢 ⇒ 请求用 GET 发出去 ⇒ 站方拿不到 body。
    ///
    /// 判据：逗号后（trim 空白）以 `{` 开头，**且能解析成 JSON**。
    public static func splitOptions(_ raw: String) -> (url: String, options: [String: Any]) {
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            if chars[i] == "," {
                let rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("{") {
                    let head = String(chars[0..<i])
                    if let data = rest.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return (head, obj)
                    }
                }
            }
            i += 1
        }
        return (raw, [:])
    }

    /// 这条 URL 后面有没有带站方的选项后缀 `,{json}`
    ///
    /// ⚠️ 判定比 `splitOptions` 更严：还得真的有 method / body / headers 之一。
    public static func hasOptionSuffix(_ raw: String) -> Bool {
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            if chars[i] == "," {
                let rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("{") {
                    guard let data = rest.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return false
                    }
                    return obj["method"] != nil || obj["body"] != nil || obj["headers"] != nil
                }
            }
            i += 1
        }
        return false
    }

    // MARK: - 字符判定

    private static func hasHeader(_ h: [String: String], _ name: String) -> Bool {
        for k in h.keys where k.lowercased() == name.lowercased() { return true }
        return false
    }

    private static func isHexDigit(_ c: Unicode.Scalar) -> Bool {
        (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
    }

    /// 表单字段保留字符（Legado：`A-Za-z0-9-._`）
    private static func isPlainFieldChar(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
            || c == "-" || c == "." || c == "_"
    }

    /// URL 合法字符（栖阅 `AnalyzeUrl+Request` 的字符集，逐字）
    private static func isURLChar(_ c: Unicode.Scalar) -> Bool {
        if (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") { return true }
        switch c {
        case "-", ".", "_", "~", ":", "/", "?", "#", "[", "]", "@", "!", "$", "&",
             "'", "(", ")", "*", "+", ",", ";", "=", "%":
            return true
        default:
            return false
        }
    }

    /// 这个 scheme 要不要**原样返回**（不做百分号编码）
    ///
    /// ⚠️ **必须是白名单，不能是「所有自定义 scheme」** —— 见 `passthroughSchemes` 的注释。
    private static func isPassthroughScheme(_ lower: String, _ whitelist: Set<String>) -> Bool {
        guard let colon = lower.firstIndex(of: ":") else { return false }
        let scheme = lower[lower.startIndex..<colon]
        return whitelist.contains(String(scheme))
    }
}
