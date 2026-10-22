import Foundation

/// **Cookie 罐** —— 聚合源的登录态靠它。
///
/// 规格：`docs/legado-semantics.md` §S-HOST-02。
///
/// ⭐ **为什么必须宿主自己管 cookie 罐**（轻阅 build162 的教训）：
/// 站方聚合源的 cookie 是**站方服务器认的**（如番茄的 `sessionid_ss`）
/// ⇒ 必须**同一个罐**跨请求保持 ⇒ 不能每次现抓。
///
/// ⭐ **域/路径匹配规则**（跟浏览器一致）：
/// - `Domain=example.com` ⇒ 匹配 `example.com` **及其所有子域**
/// - 没写 `Domain` ⇒ **只匹配 host 完全相等**（不能给父域发）
/// - `Path` 前缀匹配
/// - **过期 cookie 要删掉**（不然登录态"看着还在、其实已失效"）
public final class CookieJar: @unchecked Sendable {

    /// 一条 cookie
    public struct Cookie: Sendable, Equatable {
        public var name: String
        public var value: String
        /// 域（`example.com`；`nil` = **没写 Domain** ⇒ 只匹配 host 完全相等）
        public var domain: String?
        /// 来源 host（**永远记录**）—— 没写 Domain 时用它做「完全相等」判定
        public var host: String
        public var path: String
        /// 过期时间（epoch 秒；`nil` = 会话 cookie）
        public var expires: Date?
        public var secure: Bool
        public var httpOnly: Bool

        public init(name: String, value: String, domain: String?, host: String = "",
                    path: String = "/", expires: Date? = nil,
                    secure: Bool = false, httpOnly: Bool = false) {
            self.name = name; self.value = value; self.domain = domain
            self.host = host
            self.path = path; self.expires = expires
            self.secure = secure; self.httpOnly = httpOnly
        }

        /// 是不是已过期
        public var isExpired: Bool {
            guard let e = expires else { return false }
            return e <= Date()
        }

        /// 能不能发给 `url`
        public func matches(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            // ⭐ 域匹配
            //    写了 Domain ⇒ 匹配该域**及其子域**
            //    没写 Domain ⇒ **只匹配 host 完全相等**（不能给子域/父域发）
            //    ⚠️ 这里踩过坑：早先写成 `host == url.host?.lowercased()`（自己跟自己比，恒真）
            //    ⇒ 没写 Domain 的 cookie 会被发给**任何域** ⭐
            if let d = domain?.lowercased() {
                guard host == d || host.hasSuffix("." + d) else { return false }
            } else {
                guard !self.host.isEmpty, host == self.host else { return false }
            }
            // 路径匹配
            let p = url.path.isEmpty ? "/" : url.path
            guard p.hasPrefix(path) else { return false }
            // secure cookie 只走 https
            if secure, url.scheme?.lowercased() != "https" { return false }
            return true
        }
    }

    private var storage: [Cookie] = []
    private let lock = NSLock()

    public init() {}

    // MARK: - 读

    /// 取该 URL 要带的 cookie 头（`k=v; k2=v2`）
    public func cookieHeader(for urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // ⭐ 顺手清掉过期项（不然登录态"看着还在、其实已失效"）
        storage.removeAll { $0.isExpired }
        let hits = storage.filter { $0.matches(url) }
        guard !hits.isEmpty else { return nil }
        return hits.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 全部 cookie（调试用）
    public var all: [Cookie] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    // MARK: - 写

    /// 存一条 cookie（同名同域同路径 ⇒ 覆盖）
    public func set(_ cookie: Cookie) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll {
            $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path
        }
        if cookie.isExpired { return }
        storage.append(cookie)
    }

    /// 从响应头里收 cookie（`Set-Cookie`）
    public func store(headers: [String: String], for urlString: String) {
        for (k, v) in headers where k.lowercased() == "set-cookie" {
            if let c = parseSetCookie(v, for: urlString) { set(c) }
        }
    }

    /// 清空（换书源 / 退出登录时）
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    /// 按名字删（退出登录）
    public func remove(named name: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll { $0.name == name }
    }

    // MARK: - Set-Cookie 解析

    /// 解析一行 `Set-Cookie`
    ///
    /// 格式：`name=value; Path=/; Domain=example.com; Expires=...; Secure; HttpOnly`
    public func parseSetCookie(_ line: String, for urlString: String) -> Cookie? {
        let parts = line.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let first = parts.first else { return nil }
        let nv = first.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard nv.count == 2 else { return nil }
        let name = String(nv[0]).trimmingCharacters(in: .whitespaces)
        let value = String(nv[1]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        var domain: String? = nil
        var path = "/"
        var expires: Date? = nil
        var secure = false
        var httpOnly = false

        for attr in parts.dropFirst() {
            let lower = attr.lowercased()
            if lower.hasPrefix("domain=") {
                domain = String(attr.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()
            } else if lower.hasPrefix("path=") {
                path = String(attr.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if path.isEmpty { path = "/" }
            } else if lower.hasPrefix("expires=") {
                expires = parseDate(String(attr.dropFirst(8)).trimmingCharacters(in: .whitespaces))
            } else if lower.hasPrefix("max-age=") {
                if let n = Int(attr.dropFirst(8).trimmingCharacters(in: .whitespaces)) {
                    expires = Date().addingTimeInterval(TimeInterval(n))
                }
            } else if lower == "secure" {
                secure = true
            } else if lower == "httponly" {
                httpOnly = true
            }
        }
        // ⭐ **没写 Domain ⇒ domain 保持 nil**（表示「只匹配 host 完全相等」）
        //    ⚠️ 早先在这里把 domain 补成 host ⇒ 语义变成「匹配子域」⇒ 越权发 cookie
        let reqHost = URL(string: urlString)?.host?.lowercased() ?? ""
        return Cookie(name: name, value: value, domain: domain, host: reqHost, path: path,
                      expires: expires, secure: secure, httpOnly: httpOnly)
    }

    /// 解析常见的 cookie 过期时间格式
    private func parseDate(_ s: String) -> Date? {
        let formats = [
            "EEE, dd-MMM-yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        // RFC 1123（带 GMT）
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let d = f.date(from: s) { return d }
        return nil
    }
}
