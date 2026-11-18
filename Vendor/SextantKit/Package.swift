// swift-tools-version:5.9
import PackageDescription

/// **SextantKit** —— **本地 vendored** 的第三方 MIT 包（Sextant / Hitch / Spanker）
///
/// ⭐ 为什么是「本地 path 依赖」而不是 SPM 远程依赖：
///   · **不联网** ⇒ 沙盒/Linux 门禁离线也能编 ⇒ 不会因为拉不到包而红
///   · **保持模块边界** ⇒ 三个包各自是独立 target（`import Hitch` / `import Spanker` 原样保留）
///     ⚠️⚠️ **不能把它们塞进同一个模块**：`Hitch.ValueType` 与 `Spanker.ValueType` 定义**不同**
///        ⇒ 同模块会「invalid redeclaration」⇒ 编译直接挂 ⭐⭐⭐
///
/// ⭐ 为什么要它：栖阅 / 柴阅的引擎用的就是这套（MIT）⇒ JSONPath 与
///   `[?(@.a=='b')]` 过滤表达式**语义与它们逐字一致** ⇒ 书源在两个引擎上结果一致。
///
/// ⚠️ 许可：三个包全是 **MIT**（可商用、无 copyleft）⇒ 许可原文见
///   `LICENSE-Sextant.txt` / `LICENSE-Hitch.txt` / `LICENSE-Spanker.txt`（+ `VENDOR.md`）。
let package = Package(
    name: "SextantKit",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "Hitch", targets: ["Hitch"]),
        .library(name: "Spanker", targets: ["Spanker"]),
        .library(name: "Sextant", targets: ["Sextant"]),
    ],
    targets: [
        .target(name: "Hitch"),
        .target(name: "Spanker", dependencies: ["Hitch"]),
        .target(name: "Sextant", dependencies: ["Hitch", "Spanker"]),
    ]
)
