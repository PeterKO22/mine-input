// W20ModelControl.swift —— W30 本地模型（7B）显式开关（⌥M 管理浮层「本地模型（7B）」区块数据源）
//
// 需求：加一个显示的开关和配置入口，必须用户打开才会加载本地模型。
// 硬保证（防呆审计全仓自动加载路径，见 macos/W30-REPORT.md §3）：
//   - 默认未加载；除 `setEnabled(true, explicitConfirm:)` 外没有任何代码路径加载模型；
//   - 开启必须 explicitConfirm=true（UI 显式确认弹窗后才传入）——缺确认直接拒绝（防误触硬门）；
//   - 开启 = models/manage-model-service.sh start（启动 + 健康检查 /v1/models 或 /completion）；
//   - 关闭 = models/manage-model-service.sh stop（立即停止 + 清扫遗留 launchd 自启）；
//   - launchd RunAtLoad/KeepAlive 自启路径已整条删除（plist + load/unload/serve），
//     compose restart 策略已停（hub/docker-compose.yml llama: restart: "no"）。
//
// 唯一生产实现 = W20ModelServiceControl（Process → manage-model-service.sh，幂等）；
// 与 w20ctl model 子命令、w30 探针（macos/w20/scripts/w30-probe.sh）同一实现。
import Foundation

/// W30「本地模型（7B）」开关控制抽象（⌥M 管理浮层开关 + 状态显示 + 配置入口的数据源）。
/// 生产实现 = W20ModelServiceControl（W20SquirrelGlue 注入）；w20ctl panel-dump 用桩。
public protocol W20ModelControl: AnyObject {
    /// 当前服务态（true=进程在跑——加载中或就绪）。
    var isServiceRunning: Bool { get }
    /// 状态显示行（未加载/加载中/就绪 + 探活结果）。
    var statusText: String { get }
    /// 首次开启确认标题。
    var consentTitle: String { get }
    /// 首次开启确认文案（资源提示：约 X GB 内存/仅本机推理）。
    var consentText: String { get }
    /// 配置文件绝对路径（config/ai.yaml，唯一配置入口）。
    var configPath: String { get }
    /// 开关：on=启动服务+健康检查（explicitConfirm 必须 true，否则拒绝）；off=立即停止。
    @discardableResult
    func setEnabled(_ on: Bool, explicitConfirm: Bool) -> Bool
}

/// 生产实现：驱动 models/manage-model-service.sh {start|stop|status}（幂等）。
public final class W20ModelServiceControl: W20ModelControl {
    public let rootURL: URL
    public let scriptPath: String

    public init(root: URL? = nil) {
        let r = root ?? Self.resolveRoot()
        self.rootURL = r
        self.scriptPath = r.appendingPathComponent("models/manage-model-service.sh").path
    }

    /// 仓库根定位：MINE_INPUT_ROOT 环境变量 > 编译期源码路径推导（自构建 dev 树）>
    /// ~/Library/Application Support/mine-input（部署形态）。
    public static func resolveRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["MINE_INPUT_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        // macos/w20/src/W20ModelControl.swift → 仓库根 = 4 层上
        var u = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<3 { u = u.deletingLastPathComponent() }
        if FileManager.default.fileExists(
            atPath: u.appendingPathComponent("models/manage-model-service.sh").path) {
            return u
        }
        return URL(fileURLWithPath:
            (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/mine-input"),
            isDirectory: true)
    }

    public var configPath: String {
        rootURL.appendingPathComponent("config/ai.yaml").path
    }

    /// 跑 manage-model-service.sh，返回 (exitCode, stdout)。公开给脚本化实测（w20ctl/探针）
    /// 直接读引擎原话（如「幂等 no-op」），与面板开关走同一条执行路径。
    @discardableResult
    public func runScript(_ args: [String]) -> (Int32, String) {
        guard FileManager.default.isExecutableFile(atPath: scriptPath)
                || FileManager.default.fileExists(atPath: scriptPath) else {
            return (127, "[error] 找不到 manage-model-service.sh：\(scriptPath)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptPath] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
        } catch {
            return (126, "[error] 启动 manage-model-service.sh 失败：\(error)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// 状态快照（manage-model-service.sh status 的 key=value 行 + 末行人读文案）。
    public func statusSnapshot() -> (kv: [String: String], human: String) {
        let (_, out) = runScript(["status"])
        var kv: [String: String] = [:]
        var human = ""
        for line in out.split(separator: "\n") {
            if let eq = line.firstIndex(of: "=") {
                kv[String(line[..<eq])] = String(line[line.index(after: eq)...])
            } else if !line.isEmpty {
                human = String(line)
            }
        }
        return (kv, human)
    }

    // MARK: W20ModelControl

    public var isServiceRunning: Bool {
        let s = statusSnapshot().kv["state"] ?? "not-loaded"
        return s == "loading" || s == "ready"
    }

    public var statusText: String {
        let (kv, human) = statusSnapshot()
        switch kv["state"] ?? "not-loaded" {
        case "ready":
            let via = kv["probe"] ?? "?"
            return "本地模型：就绪（探活 \(via) 通过 · :\(kv["port"] ?? "8092")）"
        case "loading":
            return "本地模型：加载中（进程在，探活未过）"
        default:
            return human.isEmpty ? "本地模型：未加载（默认）" : human
        }
    }

    public var consentTitle: String { "开启「本地模型（7B）」？" }

    public var consentText: String {
        let gb = statusSnapshot().kv["mem_hint_gb"] ?? "5"
        return """
        资源提示：加载 7B Q4_K_M 权重（约 \(gb) GB）到内存并常驻——确认本机内存富余再开。\
        仅本机推理：权重与推理全程不出本机、不调用云端。
        开启后本地起 llama-server（:8092），AI 建议走本地模型；随时在本面板关闭，关闭立即停止并释放。
        默认关闭；只有你确认开启才会加载。
        """
    }

    /// 开关（面板确认弹窗后调用）。on 无 explicitConfirm 拒绝（硬门）。
    @discardableResult
    public func setEnabled(_ on: Bool, explicitConfirm: Bool) -> Bool {
        if on {
            guard explicitConfirm else { return false }  // 未显式确认 = 不加载
            let (code, _) = runScript(["start"])
            return code == 0
        }
        let (code, _) = runScript(["stop"])
        return code == 0
    }
}
