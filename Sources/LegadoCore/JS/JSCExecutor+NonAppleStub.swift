import Foundation

// ⭐⭐⭐⭐⭐ **非 macOS / 非 Apple 平台上的 `JSCExecutor` stub**（2026-10-26 实证）
//
// ──────────────────────────────────────────────────────────────
// 为什么要这个文件（**这是「门禁覆盖不到我改的文件」的第二个实例**）
// ──────────────────────────────────────────────────────────────
//   · `JSCExecutor.swift` 整个文件在 `#if canImport(JavaScriptCore)` 里
//   ⇒ ⇒ **Linux 沙盒里根本没有 `JSCExecutor` 这个类型**
//   ⇒ ⇒ 任何**引用 `JSCExecutor` 的测试代码**在 Linux 上要么被 `#if` 挡掉（不编译）
//   ⇒ ⇒ **macOS 专属的类型错（`cannot find 'FakeAPI' in scope` 这种）在沙盒里完全看不见**
//   ⇒ ⇒ 只能等 macOS CI 才炸 ⇒ **白等一轮** ⭐⭐⭐
//
// ⭐⭐⭐ **正解**：给非 Apple 平台补一个**签名一致的 stub**
//   ⇒ 测试文件**不用 `#if canImport(JavaScriptCore)` 挡掉** ⇒ Linux 也能**编**它
//   ⇒ ⇒ macOS 专属的类型错 ⇒ **在 Linux 沙盒就能抓**（3 秒，不用等 CI）⭐⭐⭐
//
// ⚠️ **stub 原则**：**只给签名，绝不给实现**
//   ⇒ 给实现就变成「用假实现验真代码」⇒ 失去意义 ⭐⭐⭐
//
// ⚠️ **本 stub 只在「没有 JavaScriptCore」的平台生效**（macOS / iOS 有真身）

#if !canImport(JavaScriptCore)

/// ⭐⭐⭐ **非 Apple 平台上的 `JSCExecutor` stub**（签名与真身一致 ⇒ 引用方不用改）
public final class JSCExecutor: JSCExecutorSurface, @unchecked Sendable {
    // ⭐⭐⭐ **`isAvailable` 不在这里定义** ⇒ 统一由 `JSCExecutorSurface.swift` 的共享扩展提供
    //   ⇒ macOS 真身 / Linux stub **只有一份实现** ⇒ **不可能漂移** ⭐⭐⭐

    public init(api: JSHostAPIProvider) {
        self.api = api
    }

    private let api: JSHostAPIProvider

    public func run(_ code: String, context: JSRunContext) throws -> JSONValue {
        throw SourceError.unsupported("JavaScriptCore 只在 macOS / iOS 可用")
    }
    public func runGlobal(_ code: String, context: JSRunContext) throws -> JSONValue {
        throw SourceError.unsupported("JavaScriptCore 只在 macOS / iOS 可用")
    }
    public func setEngineAPI(_ handler: JSEngineAPIHandler?) {}
    public func markGlobalsAsBaseline() {}
    public func invalidate() {}
}

#endif
