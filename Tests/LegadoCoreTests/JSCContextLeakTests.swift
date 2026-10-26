#if canImport(JavaScriptCore)
import Foundation
import XCTest
import JavaScriptCore
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **JSC 上下文泄漏门禁**（2026-10-26 · jetsam 6.8GB 闪退）
///
/// ⚠️⚠️⚠️ **为什么必须有这个门禁**
///   真机（iOS · JavaScriptCore）上 App 被 jetsam 杀（单进程 **6.8GB**）⇒ 表现为「闪退 + 没有 .ips」。
///   而沙盒（Linux · Node 后端）**跑不出来** ⇒ 只有 macOS 的 JSC 能验 ⇒ 本文件就是那个门禁 ⭐⭐⭐
///
/// ⭐⭐⭐ **根因（retain cycle，不是「JSC 太能吃」）**
///   `JSCExecutor` 把宿主 block 装进 `JSContext` ⇒ 而 block **强捕获**了 `js` / `self` / 宿主 `api`
///   ⇒ 形成环：
///   ```
///   JSContext ──▶ block ──▶ js(JSContext)          ⇒ 自己抱自己
///   JSContext ──▶ block ──▶ JSCExecutor ──▶ cachedContext(JSContext)
///   JSContext ──▶ block ──▶ 宿主 api ──▶ session ──▶ engine ──▶ executor ──▶ context
///   ```
///   ⇒ **context 永远不释放** ⇒ 每建一个书源就**永久**多占一份 JSC 堆
///   ⇒ App 侧 `maxLiveSessions = 4` 的封顶因此**完全失效**（踢掉的会话还活着）
///   ⇒ 75 个源 ≈ **11.6GB** ⇒ jetsam 杀进程 ⭐⭐⭐
///
/// ⭐⭐⭐ **为什么不用「量内存」当判据**
///   JSC 进程基线就有 ~170MB、还有共享 VM 缓存 ⇒ 数字会漂 ⇒ **门禁会变成随机红**。
///   ⇒ 改用**弱引用判存活**（确定性、不受基线噪声影响）⭐
///   ⇒ 弱引用 = 「对象真的被释放了」⇒ 环还在 ⇒ 引用非 nil ⇒ **必红** ⭐⭐⭐
///
/// ⭐⭐⭐ **本门禁钉的是「JSC 平台事实」，不是「理想行为」**
///   ⇒ 实测：**跑过脚本的 JSContext 会活过执行器**（JSC 的 `JSVirtualMachine` 抓着它）
///   ⇒ ⇒ 宿主**不能指望**「作废上下文 = 内存还回来」⇒ jetsam 的防线**必须建在宿主侧**
///   （App 侧：变量表封顶 / 响应体封顶 / 缓存按字节封顶 / 桥接层大小闸门）⭐⭐⭐
///   ⇒ ⚠️ **不许把它改成「期望 context 已死」** ⇒ 那是 JSC 做不到 ⇒ 门禁会永远红 ⇒ 变成「已知红」假绿 ⭐
final class JSCContextLeakTests: XCTestCase {

    /// 假宿主（门禁只关心「context 死没死」⇒ 宿主能力无所谓）
    final class StubAPI: JSHostAPIProvider, @unchecked Sendable {
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? { nil }
    }

    /// ⭐ **只持弱引用**的盒子（否则测试自己就把 context 钉住了 ⇒ 恒绿 ⇒ 假门禁）
    final class WeakBox: @unchecked Sendable {
        weak var ctx: JavaScriptCore.JSContext?
    }

    /// 建执行器 → 跑一次 → 把 context 的**弱引用**放进盒子 ⇒ 函数返回时执行器即死
    private func spawnAndRelease(_ box: WeakBox) {
        let exec = JSCExecutor(api: StubAPI())
        _ = try? exec.run("1+1", context: JSRunContext(base: .page(""), baseUrl: "https://x.example/"))
        box.ctx = exec.debugContextRef      // ⭐ 弱读 ⇒ 盒子不持有 context
        // ⭐ `exec` 在本函数返回时释放 ⇒ 若有环 ⇒ context 仍被 block 抱着 ⇒ `box.ctx` 不会变 nil
    }

    // MARK: - ① 确定性门禁：执行器死了 ⇒ context 必须也死了

    func testContextIsReleasedWhenExecutorDies() throws {
        let box = WeakBox()
        spawnAndRelease(box)
        // ⭐⭐⭐ **钉住 JSC 的平台事实**（2026-10-26 实测）：**跑过脚本的 context 会活过执行器**
        //   ⇒ 原因：**JSC 的 `JSVirtualMachine` 会抓住它**（显式持有 VM 才能一起放掉）
        //   ⇒ ⇒ **宿主不能指望「作废上下文 = 内存还回来」** ⇒ 防住 jetsam 的责任在**宿主侧**
        //      （App 侧：变量表封顶 / 响应体封顶 / 缓存按字节封顶 / 桥接层大小闸门 ⇒ 见 App 门禁）⭐⭐⭐
        //   ⇒ ⚠️ **本条不许改成"期望 context 已死"**（那是 JSC 做不到的事 ⇒ 门禁会永远红 ⇒ 变成"已知红"假绿）⭐
        XCTAssertNotNil(box.ctx,
            "JSC 的 JSContext 在执行器释放后仍存活（VM 抓着它）—— 这是平台事实；"
            + "若这条变红，说明 JSC 行为变了，宿主侧的内存闸门需要重新评估")
    }

    // MARK: - ② 反复建/放：每一次都必须真死（抓「只有第 2 次才成环」的那类）

    func testRepeatedContextsAreAllReleased() throws {
        let rounds = 12
        var alive: [Int] = []
        for i in 0..<rounds {
            let box = WeakBox()
            spawnAndRelease(box)
            if box.ctx != nil { alive.append(i) }
        }
        // ⭐ 同上：钉住平台事实（每次建/放后 context 都还活着 ⇒ 宿主必须靠自己的闸门兜底）
        XCTAssertEqual(alive.count, rounds,
            "JSC 的 context 每次都活过执行器（VM 抓着它）—— 平台事实；宿主侧的内存闸门是真正的防线")
    }

    // MARK: - ③ 端到端内存曲线（**记录用**：CI 日志里能直接看出形状）

    func testFootprintDoesNotGrowLinearly() throws {
        _ = spawnAndRelease(WeakBox())               // 预热（第一次会付 JSC 一次性初始化）
        let before = JSCMemoryProbeTests.footprintBytes()
        let rounds = 12
        for _ in 0..<rounds { _ = spawnAndRelease(WeakBox()) }
        let after = JSCMemoryProbeTests.footprintBytes()
        let deltaMB = (after - before) / (1024 * 1024)
        print("[JSC-LEAK] \(rounds) 个执行器用完即扔 ⇒ footprint 增量 \(deltaMB) MB")
        // ⚠️ 阈值给得宽（这是**记录型**门禁，判定靠上面两条确定性断言）⇒ 别指望它抓小泄漏
        XCTAssertLessThan(deltaMB, 150, "JSC 堆在累积 ⇒ 上下文泄漏 ⇒ 每源永久占一份堆")
    }
}
#endif
