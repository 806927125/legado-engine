import Foundation
@testable import LegadoCore

/// ⭐⭐⭐ **老引擎语义的宿主桩**（详情/目录/正文 + 发现页两条对拍共用）
///
/// ⚠️ 之前它是 `StationDahulangChainParityTests` 里的 **private** 类型
/// ⇒ 新加的「发现页对拍」用不了 ⇒ 编译失败 ⇒ **提取成共享的顶层类型** ⭐
final class LegacyHost: JSHostAPIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var vars = ""
    func hostObject(named name: String) -> HostObject? {
        switch name {
        case "source":
            return HostObject(name: "source", methods: [
                "getVariable": { [self] _ in .string(readVars()) },
                "setVariable": { [self] args in
                    writeVars(args.first?.scalarString ?? ""); return .string("")
                },
                "getLoginInfoMap": { _ in .object([:]) },
                "header": { _ in .string("") },
            ])
        case "cookie":
            return HostObject(name: "cookie", methods: [
                "getCookie": { _ in .string("") },
                "setCookie": { _ in .string("") },
                "removeCookie": { _ in .string("") },
            ])
        case "book":
            return HostObject(name: "book", methods: [
                "getVariable": { _ in .string("") },
            ])
        default: return nil
        }
    }

    func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
        switch method {
        case "deviceID": return .string("GT-DEVICE")
        case "androidId": return .string("GT-ANDROID")
        case "getWebViewUA": return .string("UA/1.0")
        default: return .string("")
        }
    }

    private func readVars() -> String { lock.lock(); defer { lock.unlock() }; return vars }
    private func writeVars(_ v: String) { lock.lock(); vars = v; lock.unlock() }
}
