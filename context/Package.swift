// swift-tools-version:5.9
// mine-input · W9 context —— 上下文引擎 MVP + 交互日志 + 动态提词器演示（C0 级）
// 只依赖系统库（libsqlite3 / AppKit / Foundation），无第三方包。
import PackageDescription

let package = Package(
    name: "context",
    platforms: [.macOS(.v13)],
    products: [
        // W12（macos/w12）以包依赖方式复用核心（additive，不影响既有测试）
        .library(name: "ContextCore", targets: ["ContextCore"]),
        // W19 memory-jsonl：记忆层（JSONL 对话记忆库，§15.1）
        .library(name: "MemoryCore", targets: ["MemoryCore"]),
        .executable(name: "contextctl", targets: ["contextctl"]),
        .executable(name: "memoryctl", targets: ["memoryctl"]),
    ],
    targets: [
        .target(
            name: "ContextCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // W19：记忆层 store（§15.1 schema / 配对 / 隐私联动 / 同步挂钩）
        .target(name: "MemoryCore", dependencies: ["ContextCore"]),
        .executableTarget(
            name: "contextctl",
            dependencies: ["ContextCore"]
        ),
        .executableTarget(
            name: "memoryctl",
            dependencies: ["MemoryCore", "ContextCore"]
        ),
        .testTarget(
            name: "ContextCoreTests",
            dependencies: ["ContextCore"]
        ),
        .testTarget(
            name: "MemoryCoreTests",
            dependencies: ["MemoryCore", "ContextCore"]
        ),
    ]
)
