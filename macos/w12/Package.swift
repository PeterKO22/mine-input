// swift-tools-version:5.9
// mine-input · W12 macos-C1 —— C1 采集 MVP + W7×W9 接线 + ⌥Esc 提词浮层
// 共享源码 macos/w12/src（同一份源码既编进 Squirrel.dev，也编成本包供脚本化实测）。
// 依赖：context/（W9 ContextCore，相对路径包依赖）+ 系统库，零第三方包。
import PackageDescription

let package = Package(
    name: "w12",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../context"),
    ],
    targets: [
        .target(
            name: "W12Core",
            dependencies: [.product(name: "ContextCore", package: "context")],
            path: "src",
            swiftSettings: [.define("W12_STANDALONE")]
        ),
        .executableTarget(
            name: "w12ctl",
            dependencies: ["W12Core"],
            path: "tools/w12ctl",
            swiftSettings: [.define("W12_STANDALONE")]
        ),
        .testTarget(
            name: "W12CoreTests",
            dependencies: ["W12Core"],
            path: "tests/W12CoreTests",
            swiftSettings: [.define("W12_STANDALONE")]
        ),
    ]
)
