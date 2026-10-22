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
    products: [
        .library(name: "LegadoCore", targets: ["LegadoCore"]),
        .executable(name: "conformance", targets: ["Conformance"]),
    ],
    dependencies: [
        // HTML 解析 + CSS 选择器（Jsoup 兼容语义）
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .target(name: "LegadoCore", dependencies: [
            .product(name: "SwiftSoup", package: "SwiftSoup")
        ]),
        .executableTarget(name: "Conformance", dependencies: ["LegadoCore"]),
        .testTarget(name: "LegadoCoreTests", dependencies: ["LegadoCore"]),
    ]
)
