import Foundation

/// ⭐⭐ **HTTP 缓存装饰器** —— 给 `HTTPTransport` 套一层缓存。
///
/// ⭐ **为什么放在引擎层**：真实场景里**网络是最大头**（一次详情页可能几百 ms）
///   而「详情页 + 目录页」常常是**同一个 URL** ⇒ 白跑一次网络。
///   ⇒ 引擎提供这个装饰器 ⇒ **宿主按需启用**（引擎不强制，避免内容过期风险）⭐
///
/// ⚠️ **要不要缓存由宿主决定**（有的书源内容会变 ⇒ 缓存时间要短 / 不缓存）。
///
/// ```swift
/// let cached = CachedTransport(inner: URLSessionTransport(), ttl: 60)
/// let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: cached))
/// ```
public final class CachedTransport: HTTPTransport, @unchecked Sendable {

    /// 缓存有效期（秒）
    public let ttl: TimeInterval
    /// 容量上限（条目数）
    public let capacity: Int

    private let inner: HTTPTransport
    private let lock = NSLock()
    private var store: [String: Entry] = [:]
    private var order: [String] = []

    private struct Entry {
        let response: HTTPResponse
        let at: Date
    }

    public init(inner: HTTPTransport, ttl: TimeInterval = 60, capacity: Int = 64) {
        self.inner = inner
        self.ttl = max(0, ttl)
        self.capacity = max(1, capacity)
    }

    public func send(_ request: HTTPRequest) throws -> HTTPResponse {
        // ⚠️ TTL = 0 ⇒ 等于不缓存
        guard ttl > 0 else { return try inner.send(request) }

        let key = request.url + "|" + request.method + "|" + (request.body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        lock.lock()
        if let e = store[key], Date().timeIntervalSince(e.at) < ttl {
            if let i = order.firstIndex(of: key) { order.remove(at: i) }
            order.append(key)
            lock.unlock()
            return e.response
        }
        lock.unlock()

        let resp = try inner.send(request)

        lock.lock()
        if store[key] == nil { order.append(key) }
        store[key] = Entry(response: resp, at: Date())
        while order.count > capacity {
            let old = order.removeFirst()
            store.removeValue(forKey: old)
        }
        lock.unlock()
        return resp
    }

    /// 清空缓存（切书源 / 登录态变了时）
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll(); order.removeAll()
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }
}
