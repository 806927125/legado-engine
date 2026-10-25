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
    /// ⭐⭐⭐⭐⭐ **revision 由【宿主 App】提供**（不是这里读）⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么不能在这里读 `-D` 宏**：
    ///   `LegadoCore` 是 **SPM 依赖 target** ⇒ 它的编译参数**不受 App target 的
    ///   `OTHER_SWIFT_FLAGS` 影响** ⇒ 宏传不进来 ⇒ 永远 `unknown` ⭐⭐⭐
    ///   ⇒（实测：`-DLEGADO_REVISION=` 出现在 App target 的 SwiftCompile 命令行里，
    ///     但 **LegadoCore 的 SwiftCompile 命令行里没有** ⇒ 宏没生效）⭐⭐⭐
    ///
    /// ⇒ 所以：**App target 读宏**（它拿得到）⇒ 传给这里拼版本串 ⭐⭐⭐
    /// ⇒ 拿不到 ⇒ `"unknown"` ⇒ **明说不知道**（绝不含糊其辞）⭐⭐⭐
    public static func version(revision: String) -> String {
        "legado-engine \(revision) · 老 JS 引擎已退役，只剩新引擎"
    }
}
