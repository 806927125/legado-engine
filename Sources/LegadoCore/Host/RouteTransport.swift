import Foundation

/// ⭐⭐⭐⭐⭐ **路由式假服务器**（2026-10-25 门禁迁移）
///
/// ⚠️ **为什么需要**：
/// · 老 JS 引擎时代，门禁用 `nativeMock` 在 **JS 侧**拦请求 ⇒ 假服务器是 JS 层的
/// · 现在站方 JS 由**引擎同步执行** ⇒ `java.ajax` 在**引擎内**发请求
///   ⇒ 假服务器必须**下沉到 transport 层**才拦得住 ⭐⭐⭐
/// · 不下沉 ⇒ 这批门禁（ajax-retry / ajax-candidate-group / host-failover /
///   timeout-budget）**全跑不起来** ⇒ 覆盖丢失 ⭐⭐⭐
///
/// ⭐ **路由规则**（按顺序匹配，第一条命中即用）：
/// ```json
/// [
///   { "match": "a.example.com", "status": 502, "body": "<html>502</html>" },
///   { "match": "/p", "status": 200, "body": "{\"ok\":1}" }
/// ]
/// ```
/// · `match` 是**子串匹配**（对 URL 去掉 query 后匹配；也可直接写 host 片段）
/// · 未命中 ⇒ 返回 404（**明确失败** ⇒ 不静默 200 ⇒ 门禁能看见）
public struct RouteTransport: HTTPTransport {
    public struct Rule: Sendable {
        public var match: String
        public var status: Int
        public var body: String
        public var headers: [String: String]

        public init(match: String, status: Int = 200, body: String = "",
                    headers: [String: String] = [:]) {
            self.match = match
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    public let rules: [Rule]
    /// ⭐⭐⭐ **请求记录**（门禁要看「到底发了几条、发的哪条」）
    public let recorder: Recorder

    public final class Recorder: @unchecked Sendable {
        public init() {}
        private let lock = NSLock()
        private var _urls: [String] = []
        public var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }
        public func add(_ u: String) { lock.lock(); _urls.append(u); lock.unlock() }
    }

    public init(rules: [Rule], recorder: Recorder = Recorder()) {
        self.rules = rules
        self.recorder = recorder
    }

    /// ⭐⭐⭐⭐⭐ **从 JSON 数组构造**（Conformance 的 `--routes` 参数）
    public static func fromJSON(_ text: String) -> RouteTransport? {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let rules = arr.compactMap { d -> Rule? in
            guard let m = d["match"] as? String else { return nil }
            return Rule(match: m,
                        status: d["status"] as? Int ?? 200,
                        body: d["body"] as? String ?? "",
                        headers: (d["headers"] as? [String: String]) ?? [:])
        }
        return RouteTransport(rules: rules)
    }

    public func send(_ request: HTTPRequest) throws -> HTTPResponse {
        recorder.add(request.url)
        // ⭐⭐⭐ **匹配用「去掉 query 的 URL」**（门禁按 path 过滤）
        let bare = request.url.split(separator: "?").first.map(String.init) ?? request.url
        for r in rules {
            if bare.contains(r.match) || request.url.contains(r.match) {
                var headers = r.headers
                headers["Content-Type"] = headers["Content-Type"] ?? "text/plain; charset=utf-8"
                return HTTPResponse(statusCode: r.status, headers: headers,
                                   body: Data(r.body.utf8), finalURL: request.url)
            }
        }
        // ⚠️ **未命中 ⇒ 404**（明确失败 ⇒ 门禁看得见 ⇒ 不静默 200 造成假绿）⭐⭐⭐
        return HTTPResponse(statusCode: 404, headers: [:],
                            body: Data("no route".utf8), finalURL: request.url)
    }
}

// MARK: - 兜底 transport

/// ⭐⭐⭐ **永远失败的 transport**（没配路由时用 ⇒ 明确失败而不是静默）
public struct HTTPTransportShim {
    public static func failing() -> HTTPTransport {
        FailingTransport()
    }
    struct FailingTransport: HTTPTransport {
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            throw SourceError.requestFailed(request.url, "沙盒没配路由（routes 为空）")
        }
    }
}
