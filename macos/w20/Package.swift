// swift-tools-version:5.9
// mine-input · W20 proposal-ui —— 提案契约 v2 UI + 记忆管理界面（N7/N8）
// 共享源码 macos/w20/src（同一份源码既编进 Squirrel.dev，也编成本包供脚本化实测）。
// 依赖：context/（W9 ContextCore：熔断 CircuitBreaker 同源），零第三方包。
// 提案引擎：SwiftPM 独立构建用 W20NullProposalEngine（Null 桩 Swift 镜像）；
// Squirrel.app 内经 ObjC++ 桥接 C++ NullProposalAgent（macos/w20/bridge/，仅编进 app）。
import PackageDescription

let package = Package(
    name: "w20",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../context"),
    ],
    targets: [
        .target(
            name: "W20Core",
            dependencies: [.product(name: "ContextCore", package: "context")],
            path: "src",
            swiftSettings: [.define("W20_STANDALONE")]
        ),
        .executableTarget(
            name: "w20ctl",
            dependencies: ["W20Core"],
            path: "tools/w20ctl",
            swiftSettings: [.define("W20_STANDALONE")]
        ),
        .testTarget(
            name: "W20CoreTests",
            dependencies: ["W20Core"],
            path: "tests/W20CoreTests",
            swiftSettings: [.define("W20_STANDALONE")]
        ),
    ]
)
