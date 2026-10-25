/// ⭐⭐⭐⭐⭐ **引擎版本信息**（2026-10-25 真机教训）
///
/// ⚠️⚠️ **为什么必须有这个**：
///   之前 App 侧把引擎 revision **手写**在 `RuleSandbox.engineVersion` 里
///   ⇒ build253 实际跑的是 `8d206b5`，但 App 显示的是 `c28de9b`（**手写的老值**）⭐⭐⭐
///   ⇒ **自证是假的** ⇒ 看到日志的人会以为「引擎版本没变 ⇒ 不是引擎问题」
///   ⇒ **把排查带偏了** ⭐⭐⭐
///
/// ⇒ 修法：revision 由**构建时注入**（CI 传 `-Xswiftc -DLEGADO_REVISION=...`）
///   ⇒ 拿不到注入值时**明说「未知」**，**绝不含糊其辞** ⇒ 宁可不知道，不能报错 ⭐⭐⭐
public enum LegadoEngineInfo {
    /// ⭐⭐⭐ **构建时注入的 revision**（CI 传 `-DLEGADO_REVISION=<sha>`）
    /// ⚠️ 没有注入 ⇒ `"unknown"` ⇒ **明说不知道**（不许手写一个假的）⭐⭐⭐
    public static let revision: String = {
        #if LEGADO_REVISION
        return String(UTF8String: LEGADO_REVISION) ?? "unknown"
        #else
        return "unknown"
        #endif
    }()

    /// ⭐ **引擎版本串**（给 UI 显示）
    public static var version: String {
        "legado-engine \(revision) · 老 JS 引擎已退役，只剩新引擎"
    }
}
