import Foundation
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **Node 驱动的 JS 执行器**（Linux 沙盒用）—— 让沙盒能「真跑站方 JS」
///
/// **为什么需要**（2026-10-25 真机 JM小说 实证）：
/// · 站方 JS 有**自定义加密** ⇒ 必须真跑 JS 才能验 ⇒ 手写 stub 会**假定**行为 ⇒ 测不出真机问题 ⭐⭐⭐
/// · Linux 沙盒**没有 JSC** ⇒ 真机行为复现不了 ⇒ 只能一轮轮出包试 ⭐⭐⭐
/// ⇒ 本类把求值交给**长驻 node 进程**（`node-js-harness.js`）⇒ **贵平台的复现搬到便宜平台** ⭐⭐⭐
///
/// ⚠️ **只用于测试**（不进 App）⇒ Linux 上跑 `swift test` 就能验真源 ⭐
public final class NodeJSExecutor: JSExecutor, @unchecked Sendable {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let lock = NSLock()

    /// ⭐⭐⭐ **启动 node 进程**（找不到 node ⇒ 抛错 ⇒ 门禁显式 SKIP，不许假绿）
    public init() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", NodeJSExecutor.harnessPath]
        p.standardInput = Pipe()
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        self.process = p
        self.stdin = p.standardInput as! Pipe
        self.stdout = p.standardOutput as! Pipe
    }

    /// ⭐ harness 脚本路径（跟本文件同目录）
    static var harnessPath: String {
        // ⭐⭐⭐ **必须按 `#file` 定位**（不能用相对路径 ⇒ swift test 的 cwd 不确定）⭐⭐⭐
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile.deletingLastPathComponent()
            .appendingPathComponent("node-js-harness.js").path
    }

    /// ⭐ 节点是否存在（门禁用它做显式 SKIP）
    public static var nodeAvailable: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", "--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    deinit {
        try? stdin.fileHandleForWriting.close()
        process.terminate()
    }

    /// ⭐⭐⭐ 送一条命令、读一条回复
    private func send(_ payload: [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "NodeJSExecutor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "命令序列化失败"])
        }
        stdin.fileHandleForWriting.write(Data((line + "\n").utf8))
        // ⭐ 读一行回复
        var buf = Data()
        while true {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buf.append(chunk)
            if let nl = buf.firstIndex(of: 0x0A) {
                let out = buf[..<nl]
                let obj = try JSONSerialization.jsonObject(with: Data(out)) as? [String: Any] ?? [:]
                return obj
            }
        }
        throw NSError(domain: "NodeJSExecutor", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "node 进程没有回复"])
    }

    // MARK: - JSExecutor

    /// ⭐⭐⭐ **求值**（复刻引擎的 scope + eval 包装 ⇒ 与 JSC 同语义）
    public func run(_ code: String, context: JSRunContext) throws -> JSONValue {
        // ⭐⭐⭐⭐⭐ **必须传【JS 字面量】，不是 `.text`**（2026-10-25 踩过）
        //   引擎的 scope 是 `var result = <jsonLiteral(base.resultValue)>;`
        //   ⇒ 对 `.json(对象)` 基准 ⇒ 字面量是**对象字面量** ⇒ `result.title` 才拿得到 ⭐⭐⭐
        //   ⇒ 而 `RuleValue.text` 对 `.json` 是 **`scalarString` ⇒ 对象/数组 ⇒ 空串** ⭐⭐⭐
        //   ⇒ 传 `.text` ⇒ **把结构丢了** ⇒ `result.title` 恒空 ⇒ **假失败** ⭐⭐⭐
        let resultLiteral = JSScopeBuilder.jsonLiteral(
            JSScopeBuilder.toJSON(context.base.resultValue))
        var payload: [String: Any] = [
            "cmd": "run",
            "code": code,
            "resultLiteral": resultLiteral,
            "baseUrl": context.baseUrl,
            "key": context.key,
            "page": context.page,
            "vars": context.vars,
        ]
        if !context.extra.isEmpty {
            payload["extra"] = context.extra.mapValues { $0.foundationValue }
        }
        let reply = try send(payload)
        if (reply["ok"] as? Bool) != true {
            throw NSError(domain: "NodeJSExecutor", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "JS 执行失败：\(reply["error"] as? String ?? "?")"])
        }
        return JSONValue.from(reply["value"])
    }

    /// ⭐ **全局求值**（站方 jsLib ⇒ 间接 eval ⇒ 留在全局）
    public func runGlobal(_ code: String, context: JSRunContext) throws -> JSONValue {
        let reply = try send(["cmd": "loadGlobal", "code": code])
        if (reply["ok"] as? Bool) != true {
            throw NSError(domain: "NodeJSExecutor", code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                            "jsLib 加载失败：\(reply["error"] as? String ?? "?")"])
        }
        return .null
    }

    public func setEngineAPI(_ handler: JSEngineAPIHandler?) {}
    public func markGlobalsAsBaseline() {}
    public func invalidate() {}
}
