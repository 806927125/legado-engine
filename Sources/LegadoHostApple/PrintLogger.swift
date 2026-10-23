import Foundation
import LegadoCore

/// ⭐ **引擎日志**（宿主服务契约 §S-HOST-05 的参考实现）—— 两种：
/// - `PrintLogger` ⇒ 纯 Foundation（**Linux 沙盒也能跑**）⇒ 打到 stdout
/// - `OSLogLogger` ⇒ 用 `os_log`（Apple 平台）⇒ 进系统日志
///
/// ⭐ **关键**：宿主应该**同时**把日志收进自己的缓冲区（用户能在「测书源」里看到），
/// 别只打 NSLog —— **只进 NSLog 等于用户完全看不到**（这是踩过的坑）⭐
public final class PrintLogger: EngineLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let keep: Int

    public init(keep: Int = 500) { self.keep = keep }

    public func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(message)
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
        print("[legado] \(message)")
    }

    public var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    public func clear() { lock.lock(); defer { lock.unlock() }; lines.removeAll() }
}

#if canImport(os)
import os

/// ⭐ **系统日志版**（Apple 平台）⇒ 进「Console.app」/ 设备日志
public final class OSLogLogger: EngineLogger, @unchecked Sendable {
    private let osLog = OSLog(subsystem: "com.legado.engine", category: "engine")
    private let mirror: PrintLogger

    public init(mirror: PrintLogger = PrintLogger()) { self.mirror = mirror }

    public func log(_ message: String) {
        os_log("%{public}@", log: osLog, type: .debug, message)
        mirror.log(message)   // ⭐ 同时留一份给「测书源」面板
    }
}
#endif
