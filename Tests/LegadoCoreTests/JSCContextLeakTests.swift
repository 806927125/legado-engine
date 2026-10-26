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
/// ⚠️ **变异测试要求**：把 `JSCExecutor` 里任意一个 `[weak js]` / `[weak self]` 改回强捕获
///   ⇒ 本门禁**必须变红** ⇒ 否则它就是装饰品 ⭐⭐⭐
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
        XCTAssertNil(box.ctx,
            "JSC 上下文泄漏：执行器已释放，JSContext 仍存活 ⇒ 每个书源永久占一份 JSC 堆 ⇒ "
            + "几十个源就能吃掉 GB 级 ⇒ jetsam 杀进程 ⇒ 表现为「闪退 + 没有 .ips」")
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
        XCTAssertTrue(alive.isEmpty,
            "JSC 上下文泄漏：第 \(alive) 次建/放后 context 仍存活 ⇒ 每次用过的书源都永久占一份堆")
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
