#if canImport(JavaScriptCore)
import Foundation
import XCTest
import JavaScriptCore
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **JSC 上下文到底被谁抓着 + 每个源到底吃多少内存**（2026-10-26）
///
/// 背景：`JSCContextLeakTests` 红了 ⇒「执行器释放 ⇒ context 已死」**不成立**。
/// ⇒ 但**具体是谁持有**未定 ⇒ 本文件把**每种构造**各试一遍 ⇒ 一次 CI 的日志给全答案 ⭐⭐⭐
///
/// ⚠️⚠️ **输出必须用 `NSLog`**（`print` 在 XCTest 里被吞掉 ⇒ 日志里啥也没有 ⇒ 白跑一轮）
///   ⇒ 而且**结尾用 XCTFail 把汇总贴进断言消息** ⇒ 就算 NSLog 也被吞，断言消息照样进日志 ⭐⭐⭐
final class JSCRetentionBisectTests: XCTestCase {

    /// ⭐ 弱引用盒子（**必须弱** ⇒ 否则测试自己把它钉住了 ⇒ 恒活 ⇒ 假结论）
    final class Box: @unchecked Sendable { weak var ctx: JavaScriptCore.JSContext? }

    /// jetsam 判杀用的同一个口径
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { r in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), r, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint) / (1024 * 1024)
    }

    private func bare() -> Box {
        let box = Box()
        guard let ctx = JavaScriptCore.JSContext() else { return box }
        box.ctx = ctx
        return box
    }

    private func evaluated() -> Box {
        let box = Box()
        guard let ctx = JavaScriptCore.JSContext() else { return box }
        _ = ctx.evaluateScript("1+1")
        box.ctx = ctx
        return box
    }

    private func weakBlockOnContext() -> Box {
        let box = Box()
        guard let ctx = JavaScriptCore.JSContext() else { return box }
        let block: @convention(block) (String) -> String = { [weak ctx] s in s }
        ctx.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: "__hostJSON" as NSString)
        box.ctx = ctx
        return box
    }

    private func strongBlockOnContext() -> Box {
        let box = Box()
        guard let ctx = JavaScriptCore.JSContext() else { return box }
        let block: @convention(block) (String) -> String = { s in s + String(describing: ctx) }
        ctx.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: "__hostJSON" as NSString)
        box.ctx = ctx
        return box
    }

    private func withJavaCompat() -> Box {
        let box = Box()
        guard let ctx = JavaScriptCore.JSContext() else { return box }
        for src in JSCExecutor.javaCompatSources() {
            _ = ctx.evaluateScript("(0, eval)(" + JSScopeBuilder.jsonLiteral(.string(src)) + ")")
        }
        box.ctx = ctx
        return box
    }

    private func explicitVMBothReleased() -> Box {
        let box = Box()
        let vm = JavaScriptCore.JSVirtualMachine()
        guard let ctx = JavaScriptCore.JSContext(virtualMachine: vm) else { return box }
        box.ctx = ctx
        return box
    }

    /// ⭐ 显式 VM 被独立盒子持有（= 「执行器持有 VM」的真实修法）
    private func explicitVMHeldByBox() -> Box {
        let box = Box()
        final class VMBox { let vm: JavaScriptCore.JSVirtualMachine; init() { vm = JavaScriptCore.JSVirtualMachine() } }
        let holder = VMBox()
        guard let ctx = JavaScriptCore.JSContext(virtualMachine: holder.vm) else { return box }
        box.ctx = ctx
        return box
    }

    /// ⭐⭐ **每个「源」到底吃多少内存**（这才是 6.8GB 的关键数字）
    private func makeExecutorAndRelease() -> Int {
        let exec = JSCExecutor(api: StubAPI())
        _ = try? exec.run("1+1", context: JSRunContext(base: .page(""), baseUrl: "https://x.example/"))
        return 0
    }

    final class StubAPI: JSHostAPIProvider, @unchecked Sendable {
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? { nil }
    }

    func testBisectWhoRetainsTheContext() throws {
        var lines: [String] = []
        func probe(_ name: String, _ make: () -> Box) {
            let box = make()
            let alive = box.ctx != nil
            let tag = alive ? "ALIVE-有人强持有" : "RELEASED-没人持有"
            NSLog("JSC-BISECT %@ => %@", name, tag)
            lines.append("\(name)=\(tag)")
        }

        NSLog("JSC-BISECT ===== 谁在持有 JSContext =====")
        probe("1-bare-context", bare)
        probe("2-eval", evaluated)
        probe("3-weak-block", weakBlockOnContext)
        probe("4-strong-block", strongBlockOnContext)
        probe("5-java-compat", withJavaCompat)
        probe("6-explicit-vm-both-released", explicitVMBothReleased)
        probe("7-explicit-vm-held-by-box", explicitVMHeldByBox)

        // ⭐⭐⭐ 每个源吃多少内存（造 N 个执行器 ⇒ 释放 ⇒ 看涨多少）
        let n = 30
        let before = Self.footprintMB()
        for _ in 0..<n { _ = makeExecutorAndRelease() }
        let after = Self.footprintMB()
        let perSource = (after - before) / n
        NSLog("JSC-BISECT %d 个执行器用完即扔 ⇒ footprint %d MB → %d MB ⇒ 每个约 %d MB",
              n, before, after, perSource)
        lines.append("per-source-delta=\(perSource)MB (total \(before)→\(after))")

        // ⭐⭐⭐ 汇总塞进断言消息 ⇒ 就算 NSLog 被吞也能看到
        XCTFail("JSC-BISECT 汇总：" + lines.joined(separator: " | "))
    }
}
#endif
