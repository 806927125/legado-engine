import Foundation

/// **宿主服务契约** —— 引擎需要、但**不该自己实现**的五件事。
///
/// ⭐ **为什么是协议而不是实现**：
/// 核心层必须**纯 Foundation**、能在 Linux 沙盒真编真跑 ⇒ 不能碰 URLSession / WKWebView / UserDefaults。
/// ⇒ 这里只定义**契约**，具体实现由宿主给（iOS = SwiftUI/UIKit 那一侧）。
/// ⇒ 沙盒里用**内存实现**当替身 ⇒ 门禁能离线跑。
///
/// 规格 §S-HOST-03 ~ §S-HOST-07。

// MARK: - ① 键值存储（书源变量 / 用户设置 / 登录态）

/// **键值存储** —— 存「书源变量」「登录信息」「用户选择」这类小数据。
public protocol KeyValueStorage: Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
    func removeValue(forKey key: String)
    /// 全部键（宿主用于「导出全部配置」）
    func allKeys() -> [String]
}

/// **内存实现**（沙盒 / 测试用；真机由宿主给 UserDefaults 版）
public final class MemoryStorage: KeyValueStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    public init(_ initial: [String: String] = [:]) { store = initial }

    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }
    public func setString(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { store[key] = value } else { store[key] = nil }
    }
    public func removeValue(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        store[key] = nil
    }
    public func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(store.keys).sorted()
    }
}

// MARK: - ② 文件存储（缓存 / 离线正文 / 书源包）

/// **文件存储** —— 路径是**逻辑路径**（由宿主决定映射到沙盒/文档目录）。
public protocol FileStorage: Sendable {
    func read(_ path: String) throws -> Data
    func write(_ data: Data, to path: String) throws
    func exists(_ path: String) -> Bool
    func remove(_ path: String) throws
    /// 列出目录下的文件名
    func list(_ directory: String) throws -> [String]
}

/// **内存实现**
public final class MemoryFileStorage: FileStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    public init() {}

    public func read(_ path: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let d = files[path] else { throw SourceError.invalidSource("文件不存在：\(path)") }
        return d
    }
    public func write(_ data: Data, to path: String) throws {
        lock.lock(); defer { lock.unlock() }
        files[path] = data
    }
    public func exists(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files[path] != nil
    }
    public func remove(_ path: String) throws {
        lock.lock(); defer { lock.unlock() }
        files[path] = nil
    }
    public func list(_ directory: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return files.keys.filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .filter { !$0.contains("/") }
            .sorted()
    }
}

// MARK: - ③ 浏览器（登录交接）

/// **浏览器能力** —— 站方登录要开浏览器、拿回页面。
///
/// ⚠️ **同步契约**：引擎内部**全同步**（见 docs/architecture.md）⇒
/// 这里是**唯一**的异步点（登录交接）⇒ 宿主自己决定用 WKWebView 还是别的实现。
public protocol BrowserProvider: Sendable {
    /// 打开一个 URL（让用户登录 / 授权）
    func open(_ url: String)
    /// **同步**取回页面源码（宿主要保证「已加载完」才返回）
    func fetchSource(_ url: String) throws -> String
}

// MARK: - ④ 提示（toast / 弹窗）

/// **用户提示** —— 站方 `java.toast` / 登录失败提示的出口。
public protocol Notifier: Sendable {
    /// 展示一条提示
    func notify(_ message: String)
    /// 展示一条**错误**（宿主可以决定用红色 / 弹窗）
    func notifyError(_ message: String)
}

// MARK: - ⑤ 日志

/// **引擎日志** —— 宿主能回放给用户看（「测书源」报告的原料）。
public protocol EngineLogger: Sendable {
    func log(_ message: String)
}

/// **收集式日志**（沙盒 / 测试用；真机由宿主接到 NSLog 或诊断面板）
public final class RecordingLogger: EngineLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    public init() {}

    public func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(message)
    }
    /// 全部日志行
    public var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        lines.removeAll()
    }
}

/// **收集式提示**（沙盒 / 测试用）
public final class RecordingNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    private var errors: [String] = []

    public init() {}

    public func notify(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(message)
    }
    public func notifyError(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        errors.append(message)
    }
    public var allMessages: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
    public var allErrors: [String] {
        lock.lock(); defer { lock.unlock() }
        return errors
    }
}
