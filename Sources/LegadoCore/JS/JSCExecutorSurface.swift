import Foundation

// ⭐⭐⭐⭐⭐ **`JSCExecutor` 的「跨平台共同面」**（2026-10-26 实证）
//
// ──────────────────────────────────────────────────────────────
// 为什么单开一个文件（**双实现漂移**的教训）
// ──────────────────────────────────────────────────────────────
//   · `JSCExecutor` 有**两份实现**：macOS 的真身（`JSCExecutor.swift`，整个在
//     `#if canImport(JavaScriptCore)` 里）+ 非 Apple 平台的 **stub**（`JSCExecutor+NonAppleStub.swift`）
//   ⇒ ⇒ **两份的 API 面会漂移**：我给 stub 加了 `isAvailable`，真身没有
//   ⇒ ⇒ **macOS CI 编译失败**（`type 'JSCExecutor' has no member 'isAvailable'`）⭐⭐⭐
//   ⇒ ⇒ 而 **Linux 沙盒永远看不见**（沙盒用的是 stub）⇒ 白等一轮 CI ⭐⭐⭐
//
// ⭐⭐⭐ **正解**（三条一起）：
//   ① **平台差异收进这一份共享扩展** ⇒ `isAvailable` 只有**一份实现**
//      （macOS/iOS ⇒ true；其它 ⇒ false）⇒ **不可能漂移** ⭐⭐⭐
//   ② **`JSCExecutorSurface` 协议**：两份实现**都必须满足同一张清单**
//      ⇒ 少一个成员 ⇒ **Linux 沙盒就编不过**（stub 那侧）⭐⭐⭐
//   ③ ⚠️ 残留洞：「**真身**不满足协议」只能 macOS CI 抓（真身在 Linux 不存在）
//      ⇒ ⇒ 所以**协议成员要少而精**（只放测试真的在用的）⇒ 每次加成员都会想一次 ⭐⭐⭐

// MARK: - ① 平台差异（**唯一一份实现** ⇒ 不会漂移）

public extension JSCExecutor {
    /// ⭐⭐⭐ **这个平台能不能用 JavaScriptCore 后端**
    ///
    /// - macOS / iOS：✅ 真身存在
    /// - 其它（Linux 沙盒）：❌ 只有 stub ⇒ 门禁会**显式 skip**（**不等于通过**）
    static var isAvailable: Bool {
        #if canImport(JavaScriptCore)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - ② 两份实现共用的 API 面（**少而精** ⇒ 只放测试真在用的）

/// ⭐⭐⭐ **两份 `JSCExecutor` 实现共用的面**
///
/// ⚠️ **成员要少而精**（每加一个 ⇒ 就是给 macOS CI 加一个「真身可能没有」的风险）
/// ⇒ ⇒ 加成员前先问：**测试真的会用到吗？**
public protocol JSCExecutorSurface: JSExecutor {
    /// ⭐⭐⭐ **能不能用**（平台差异 ⇒ 唯一实现在上面的共享扩展里）
    static var isAvailable: Bool { get }
}
