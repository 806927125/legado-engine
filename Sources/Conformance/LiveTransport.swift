import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LegadoCore

/// ⭐ **真网络传输**（只给「活体验证」工具用；库里不依赖 URLSession —— 核心层要纯 Foundation）
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"]
        self.session = URLSession(configuration: cfg)
        self.timeout = timeout
    }

    public func send(_ request: HTTPRequest) throws -> HTTPResponse {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<HTTPResponse, Error> = .failure(SourceError("未返回"))
        var urlReq = URLRequest(url: URL(string: request.url)!)
        urlReq.httpMethod = request.method
        urlReq.timeoutInterval = timeout
        for (k, v) in request.headers { urlReq.setValue(v, forHTTPHeaderField: k) }
        if let cookie = request.cookie { urlReq.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body = request.body { urlReq.httpBody = body }
        session.dataTask(with: urlReq) { data, resp, err in
            defer { sem.signal() }
            if let err { out = .failure(err); return }
            guard let http = resp as? HTTPURLResponse else { out = .failure(SourceError("非 HTTP 响应")); return }
            out = .success(HTTPResponse(statusCode: http.statusCode,
                                        headers: http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
                                            acc[String(describing: kv.key)] = String(describing: kv.value)
                                        },
                                        body: data ?? Data(),
                                        finalURL: http.url?.absoluteString))
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return try out.get()
    }

    struct SourceError: Swift.Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}
