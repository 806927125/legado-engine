import Foundation

/// **HTTP 传输协议** —— 宿主注入，核心层不关心具体实现。
///
/// ⭐ **为什么是协议**：核心层要能在 **Linux 沙盒**里真编真跑 ⇒ 不能依赖 URLSession
/// （Linux 上 FoundationNetworking 行为与 Apple 有差异，且同步封装麻烦）。
/// ⇒ 核心层只依赖这个协议；**具体实现由宿主给**（轻阅 = okhttp3，自研 = URLSession 封装）。
public protocol HTTPTransport: Sendable {
    /// 发一个请求（**同步**）
    func send(_ request: HTTPRequest) throws -> HTTPResponse
}

/// 一个 HTTP 请求
public struct HTTPRequest: Sendable, Equatable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// 超时（秒）
    public var timeout: TimeInterval
    /// 要带上的 cookie（`k=v; k2=v2`）
    public var cookie: String?

    public init(url: String, method: String = "GET", headers: [String: String] = [:],
                body: Data? = nil, timeout: TimeInterval = 30, cookie: String? = nil) {
        self.url = url; self.method = method; self.headers = headers
        self.body = body; self.timeout = timeout; self.cookie = cookie
    }

    /// 从 `URLBuilder` 的产物构造
    public init(built: URLBuilder.Built, timeout: TimeInterval = 30, cookie: String? = nil) {
        self.url = built.url
        self.method = built.method
        self.headers = built.headers
        self.body = built.body.isEmpty ? nil : built.body.data(using: .utf8)
        self.timeout = timeout
        self.cookie = cookie
    }
}

/// 一个 HTTP 响应
public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    /// **最终 URL**（重定向后）—— 相对地址绝对化必须用它，
    /// 否则「详情页里的相对章节链接」会相对到错误的地址。
    public var finalURL: String?

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data(),
                finalURL: String? = nil) {
        self.statusCode = statusCode; self.headers = headers; self.body = body
        self.finalURL = finalURL
    }

    /// 正文（UTF-8）
    public var text: String { String(data: body, encoding: .utf8) ?? "" }

    /// 是不是「成功」（2xx）
    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// ⭐ **正文是不是 JSON**（决定规则走 JSONPath 还是 CSS）
    public var isJSON: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, first == "{" || first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: body)) != nil
    }
}

/// **取页面**的便捷入口 —— 规则求值 + 宿主能力，一次搞定。
///
/// ⭐ **为什么放宿主层**：URL 规则解析（§S-URL）和「把 URL 变成响应」是**一件事**，
/// 不该拆在两个层里。
public struct PageFetcher: Sendable {
    public let transport: HTTPTransport
    public let cookieJar: CookieJar?

    public init(transport: HTTPTransport, cookieJar: CookieJar? = nil) {
        self.transport = transport
        self.cookieJar = cookieJar
    }

    /// 按 URL 规则取一页
    ///
    /// - Parameters:
    ///   - rule: URL 规则（可能带 `,{json}` 选项）
    ///   - baseUrl: 基准 URL
    ///   - timeout: 超时
    public func fetch(rule: String, baseUrl: String, timeout: TimeInterval = 30) throws -> HTTPResponse {
        let built = URLBuilder.parse(rule, baseUrl: baseUrl)
        var request = HTTPRequest(built: built, timeout: timeout)
        // ⭐ cookie 由 CookieJar 提供（站方聚合源登录态靠它）
        if let jar = cookieJar, let c = jar.cookieHeader(for: built.url), !c.isEmpty {
            request.cookie = c
        }
        let resp = try transport.send(request)
        // 收 cookie（Set-Cookie）
        if let jar = cookieJar {
            jar.store(headers: resp.headers, for: built.url)
        }
        // ⭐ 把**最终 URL**带回去 —— 相对地址绝对化要靠它
        var out = resp
        if out.finalURL == nil { out.finalURL = built.url }
        return out
    }
}
