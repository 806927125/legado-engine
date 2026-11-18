// swift-tools-version:5.9
import PackageDescription

/// **legado-engine** —— 自研 Legado 兼容规则引擎
///
/// 设计约束（来自用户明确要求「引擎能力一律用 Swift 写」）：
/// - `LegadoCore` 必须是**纯 Foundation** ⇒ Linux 沙盒能 `swiftc` 真编真跑 ⇒ 3 秒出反馈
/// - 不许 import SwiftUI / WebKit / UIKit / Combine（那属于宿主 App 层）
/// - JS 运行时（JSC）属于**可选执行后端**，由 `JSExecutor` 协议隔离，不污染核心
let package = Package(
    name: "LegadoCore",
    // ⭐ 必须显式声明平台版本 —— SwiftPM 默认 macOS 10.13，
    //   而 SwiftSoup 要求 macOS 12.0 ⇒ macOS 上会报
    //   「the library 'LegadoCore' requires macos 10.13, but depends on
    //    the product 'SwiftSoup' which requires macos 12.0」
    // ⇒ **这不是 JSC 代码的问题，是平台声明缺失**（Linux 上不查这个 ⇒ 沙盒里看不出来）
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "LegadoCore", targets: ["LegadoCore"]),
        .library(name: "LegadoHostApple", targets: ["LegadoHostApple"]),
        .executable(name: "conformance", targets: ["Conformance"]),
    ],
    dependencies: [
        // HTML 解析 + CSS 选择器（Jsoup 兼容语义）
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        // ⭐⭐⭐⭐⭐ **vendored 的 MIT 包**（栖阅 / 柴阅的引擎用的就是这套 ⇒ 语义逐字一致）
        //
        // ⚠️⚠️ **为什么是「本包内的 target」而不是「本地 path 依赖的子包」**：
        //   本引擎在轻阅里是**远程 SPM 包**被消费 ⇒ **远程包里不允许有 path 依赖**
        //   ⇒ 子包方案会让轻阅的 SPM 解析直接失败（实测 CI：「Could not resolve package dependencies」）⭐⭐⭐
        //   ⇒ 改成**同包内的三个 target** ⇒ 远程消费时整个包一起被取走 ⇒ 依赖闭合 ✔
        //
        // ⚠️ **为什么必须是三个独立 target（不能合成一个）**：
        //   `Hitch.ValueType` 与 `Spanker.ValueType` **定义不同** ⇒ 同模块会 invalid redeclaration ⭐⭐⭐
        .target(name: "Hitch"),
        .target(name: "Spanker", dependencies: ["Hitch"]),
        .target(name: "Sextant", dependencies: ["Hitch", "Spanker"]),
        .target(name: "LegadoCore", dependencies: [
            .product(name: "SwiftSoup", package: "SwiftSoup"),
            "Sextant",
        ]),
        // ⭐ 参考实现（轻阅的 AnalyzeUrl.swift）—— 只读，用于 URL 规则对拍
        .target(name: "AnalyzeUrlReference", path: "reference/swift"),
        // ⭐⭐ **宿主层参考实现**（UserDefaults / FileManager / 日志 / 提示 / 同步加载器）
        //   —— 核心层保持纯 Foundation ⇒ 这些放**宿主层 target** ⇒ 引擎不污染
        //   ⚠️ 纯 Foundation 部分（UserDefaults / FileManager / PrintLogger）
        //      **Linux 沙盒也能编真跑** ⇒ 跨平台门禁免费获得 ⭐
        //   ⚠️ UIKit / WebKit 部分用 `#if canImport` 包 ⇒ 非 Apple 平台自动跳过
        .target(name: "LegadoHostApple", dependencies: ["LegadoCore"]),
        .executableTarget(name: "Conformance", dependencies: ["LegadoCore", "AnalyzeUrlReference"]),
        .testTarget(name: "LegadoCoreTests", dependencies: ["LegadoCore", "AnalyzeUrlReference"]),
        .testTarget(name: "LegadoHostAppleTests", dependencies: ["LegadoHostApple", "LegadoCore"]),
    ]
)
