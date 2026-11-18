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

    // ────────────────────────────────────────────────────────────
    // ⭐⭐⭐ **站方 URL 选项透传**（2026-11-18 · 对齐 Legado/legado-E/栖阅）
    //
    // ⚠️ **为什么引擎要带这些**：宿主（App）才是真正发请求的人
    //   ⇒ `charset`（怎么解码）/ `useWebView`/`webJs`/`bodyJs`（怎么发）
    //   ⇒ `retry`（重试几次）/ `proxy`/`dnsIp`/`serverID`（走哪条线路）
    //   ⇒ 只有引擎解析了、宿主才知道要做什么 ⭐⭐⭐
    /// 站方指定的字符集（**优先于响应头**）—— 老站常不声明 ⇒ 乱码 ⭐⭐⭐
    public var charset: String
    /// 失败重试次数（0 = 不重试）
    public var retry: Int
    /// 用 WebView 发这个请求
    public var useWebView: Bool
    /// WebView 里跑的 JS
    public var webJs: String
    /// 请求体由 JS 生成
    public var bodyJs: String
    /// 指定 DNS IP
    public var dnsIp: String
    /// 指定服务器 ID
    public var serverID: String
    /// WebView 延迟（秒）
    public var webViewDelayTime: Double
    /// 代理
    public var proxy: String
    /// 站方的类型标记
    public var type: String
    /// 响应正则提取
    public var sourceRegex: String
    /// 覆盖 URL 正则
    public var overrideUrlRegex: String
    /// 站方指定的请求超时（秒）
    public var requestTimeout: Double?

    public init(url: String, method: String = "GET", headers: [String: String] = [:],
                body: Data? = nil, timeout: TimeInterval = 8, cookie: String? = nil) {
        self.url = url; self.method = method; self.headers = headers
        self.body = body; self.timeout = timeout; self.cookie = cookie
        self.charset = ""; self.retry = 0; self.useWebView = false
        self.webJs = ""; self.bodyJs = ""; self.dnsIp = ""; self.serverID = ""
        self.webViewDelayTime = 0; self.proxy = ""; self.type = ""
        self.sourceRegex = ""; self.overrideUrlRegex = ""; self.requestTimeout = nil
    }

    /// 从 `URLBuilder` 的产物构造
    public init(built: URLBuilder.Built, timeout: TimeInterval = 8, cookie: String? = nil) {
        self.url = built.url
        self.method = built.method
        self.headers = built.headers
        self.body = built.body.isEmpty ? nil : built.body.data(using: .utf8)
        // ⭐ 站方显式指定超时 ⇒ 覆盖默认（Legado 语义）
        self.timeout = built.requestTimeout ?? timeout
        self.cookie = cookie
        self.charset = built.charset
        self.retry = built.retry
        self.useWebView = built.useWebView
        self.webJs = built.webJs
        self.bodyJs = built.bodyJs
        self.dnsIp = built.dnsIp
        self.serverID = built.serverID
        self.webViewDelayTime = built.webViewDelayTime
        self.proxy = built.proxy
        self.type = built.type
        self.sourceRegex = built.sourceRegex
        self.overrideUrlRegex = built.overrideUrlRegex
        self.requestTimeout = built.requestTimeout
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
    /// - Parameters:
    ///   - headers: **源级请求头**（`BookSource.header`）—— 54 个源在用
    /// ⚠️⚠️ **默认超时 30 → 8 秒**（2026-10-24 真机「大灰狼卡死」实证）
    ///   🍅大灰狼的 jsLib 里 `host` 数组有 **8 条线路** ⇒ 站方 catch 循环会**挨个试**
    ///   ⇒ 死线路（服务器不回包）每条都要等满超时
    ///   ⇒ 30 秒 × 8 = **4 分钟** ⇒ 站方 JS 一直卡在那儿 ⇒ 引擎锁死 + 设备发烫 ⭐⭐⭐
    ///   ⇒ 8 秒 × 8 = 64 秒（还是慢，但**不会把 App 拖死**）⇒
    ///   ⇒ 真正的根治是**宿主先测速挑一条通的**（宿主侧 `ensureFastLine`）⇒ 只打 1 条 ⇒ 秒回 ⭐
    ///   ⇒ ⚠️ 取内容的请求（详情/目录/正文）另走 300 秒预算（宿主侧分档）⇒ 这里只管单次请求
    public func fetch(rule: String, baseUrl: String, headers: [String: String] = [:],
                      timeout: TimeInterval = 8) throws -> HTTPResponse {
        let built = URLBuilder.parse(rule, baseUrl: baseUrl)
        var request = HTTPRequest(built: built, timeout: timeout)
        // ⭐⭐ **源级请求头**（54 个源在用 ⇒ 缺了 UA/Referer/Cookie 就会被拒）
        //
        // ⚠️⚠️ **语义：URL 级的 `,{"headers":…}` = 【替换】源级 header，不是合并**
        //   （Legado / 栖阅都是「替换」⇒ 站方在单个 URL 上写了头 ⇒ 就是只用那套）
        if built.headers.isEmpty {
            request.headers = headers
        }
        // ⭐ cookie 由 CookieJar 提供（站方聚合源登录态靠它）
        // ⚠️ **源级 / URL 级已经带了 `Cookie` ⇒ 不用 CookieJar 的**（站方明确给了的优先）
        if !request.headers.keys.contains(where: { $0.lowercased() == "cookie" }),
           let jar = cookieJar, let c = jar.cookieHeader(for: built.url), !c.isEmpty {
            request.cookie = c
        }
        // ⭐⭐⭐⭐⭐ **失败重试**（站方 `url,…,{"retry":2}` ⇒ Legado/栖阅 语义）
        //
        // ⚠️ **为什么必须**：老站/聚合源经常「第一次失败、第二次就通」
        //   ⇒ 站方显式写 `retry` 就是为了这个 ⇒ 柴阅认这个键 ⇒ 轻阅原来不认
        //   ⇒ ⇒ **同一个源：柴阅能出，轻阅出不来**（少了一次重试）⭐⭐⭐
        //   ⇒ `retry: 0` = 不重试；`retry: 2` = 最多再试 2 次（总 3 次）
        var resp: HTTPResponse
        var attempt = 0
        var lastError: Error?
        while true {
            do {
                resp = try transport.send(request)
                lastError = nil
            } catch {
                lastError = error
                resp = HTTPResponse(statusCode: 0, headers: [:], body: Data(), finalURL: nil)
            }
            // 只有**请求本身失败**（抛错 / statusCode == 0）才重试
            // ⚠️ 4xx/5xx 的 HTTP 响应**不算失败**（站方自己要看状态码）⭐⭐⭐
            let failed = lastError != nil || resp.statusCode == 0
            if !failed || attempt >= built.retry { break }
            attempt += 1
        }
        if let e = lastError, resp.statusCode == 0 {
            throw e
        }
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
