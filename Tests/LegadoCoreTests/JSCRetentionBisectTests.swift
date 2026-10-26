#if canImport(JavaScriptCore)
import Foundation
import XCTest
import JavaScriptCore
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **JSC 上下文到底被谁抓着**（2026-10-26 · 一次 CI 问完全部）
///
/// 背景：`JSCContextLeakTests` 红了 ⇒ 说明「执行器释放 ⇒ context 已死」**不成立**。
/// ⇒ 但**具体是谁在持有**还没定 ⇒ 本文件把**每种可能的构造**各试一遍
///    ⇒ 一次 CI 的日志里就能看到「哪种构造会留住 context」⭐⭐⭐
///
/// ⭐ **每种构造都只做一件事**：建出来 → 拿弱引用 → 释放 → 看弱引用是不是还活着
/// ⇒ 活着 = 有人强持有它（环）⇒ 死了 = 没人持有 ⭐
final class JSCRetentionBisectTests: XCTestCase {

    /// ⭐ 弱引用盒子（**必须弱** ⇒ 否则测试自己把它钉住了 ⇒ 恒活 ⇒ 假结论）
    final class Box: @unchecked Sendable { weak var ctx: JavaScriptCore.JSContext? }

    private static func report(_ name: String, _ box: Box) {
        let alive = box.ctx != nil
        print("[JSC-BISECT] \(name) => \(alive ? "ALIVE(有人强持有)" : "RELEASED(没人持有)")")
    }

    // ① 裸 context（什么都不做）
    private func bare() -> Box {
        let box = Box()
        guard let ctx = JavaScriptCore.JSContext() else { return box }
        box.ctx = ctx
        return box
    }

    // ② context + evaluateScript（会创建 JSValue 包装）
    private func evaluated() -> Box {
        let box = Box()
        guard let ctx = JavaScriptCore.JSContext() else { return box }
        _ = ctx.evaluateScript("1+1")
        box.ctx = ctx
        return box
    }

    // ③ context + 挂一个**弱捕获自己**的 block（我修完的样子）
    private func weakBlockOnContext() -> Box {
        let box = Box()
        guard let ctx = JavaScriptCore.JSContext() else { return box }
        let block: @convention(block) (String) -> String = { [weak ctx] s in s }
        ctx.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: "__hostJSON" as NSString)
        box.ctx = ctx
        return box
    }

    // ④ context + 挂一个**强捕获自己**的 block（老代码的样子 ⇒ 必环）
    private func strongBlockOnContext() -> Box {
        let box = Box()
        guard let ctx = JavaScriptCore.JSContext() else { return box }
        let block: @convention(block) (String) -> String = { s in s + String(describing: ctx) }
        ctx.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: "__hostJSON" as NSString)
        box.ctx = ctx
        return box
    }

    // ⑤ context + 注入 Java 兼容层（2197 行 JS ⇒ 真实路径的一半）
    private func withJavaCompat() -> Box {
        let box = Box()
        guard let ctx = JavaScriptCore.JSContext() else { return box }
        for src in JSCExecutor.javaCompatSources() {
            _ = ctx.evaluateScript("(0, eval)(" + JSScopeBuilder.jsonLiteral(.string(src)) + ")")
        }
        box.ctx = ctx
        return box
    }

    // ⑥ ⭐ **显式 VM + context，然后两个都放掉**
    private func explicitVMBothReleased() -> Box {
        let box = Box()
        let vm = JavaScriptCore.JSVirtualMachine()
        guard let ctx = JavaScriptCore.JSContext(virtualMachine: vm) else { return box }
        box.ctx = ctx
        // vm 在这里出作用域 ⇒ 只剩 context 自己撑着
        return box
    }

    // ⑦ ⭐ **显式 VM 被一个独立盒子持有**（模拟「执行器持有 VM」的真实修法）
    private func explicitVMHeldByBox() -> Box {
        let box = Box()
        final class VMBox { let vm: JavaScriptCore.JSVirtualMachine; init() { vm = JavaScriptCore.JSVirtualMachine() } }
        let holder = VMBox()
        guard let ctx = JavaScriptCore.JSContext(virtualMachine: holder.vm) else { return box }
        box.ctx = ctx
        // holder 出作用域 ⇒ VM 没人持有了 ⇒ 若 context 还活着 ⇒ 说明 context 自己抱着 VM（环）
        return box
    }

    func testBisectWhoRetainsTheContext() throws {
        print("[JSC-BISECT] ===== 谁在持有 JSContext =====")
        let b1 = bare();                          Self.report("1-bare-context", b1)
        let b2 = evaluated();                     Self.report("2-eval", b2)
        let b3 = weakBlockOnContext();            Self.report("3-weak-block", b3)
        let b4 = strongBlockOnContext();          Self.report("4-strong-block", b4)
        let b5 = withJavaCompat();                Self.report("5-java-compat", b5)
        let b6 = explicitVMBothReleased();        Self.report("6-explicit-vm-both-released", b6)
        let b7 = explicitVMHeldByBox();           Self.report("7-explicit-vm-held-by-box", b7)
        print("[JSC-BISECT] ===== 结束 =====")
        // ⭐ 本测试**只打印**（不判定）⇒ 结论由 CI 日志读出来 ⇒ 不做假断言
    }
}
#endif
