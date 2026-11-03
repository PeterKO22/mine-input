import Foundation

#if canImport(ContextCore)
import ContextCore
#endif

/// W12 配置与隐私设置（FR4/FR8 隐私红线的「开关显式」约定）。
///
/// C1 开关语义（**默认关，必须显式开启**，与 W9 剪贴板开关同构）：
///   - Info.plist `W12C1Enabled`（dev 构建可置 true，等价显式开启）；
///   - 运行时持久开关（store meta `c1_enabled`）：只接受
///     `W12Privacy.enableC1(explicitConfirm: true)` 显式开启，`disableC1()` 关闭；
///   - 两者任一为开才允许 C1 采集；C0（输入历史/应用名）不受影响。
///
/// 子开关：`W12C1Screen`（屏幕快照→OCR）、`W12C1Audio`（音频→W2 管线→ASR），
/// 均默认 true（在 C1 总开关打开的前提下生效）。
public struct W12Settings {
    public var c1Enabled: Bool
    public var c1Screen: Bool
    public var c1Audio: Bool
    public var prompterEnabled: Bool
    public var prompterBackend: String  // "hub" | "null"
    public var hubBaseURL: String
    /// C1 触发防抖（秒）：输入触发窗内至多一轮采集（任务书：防抖 2s）。
    public var debounceSeconds: TimeInterval
    /// 上屏文本留存（L3，默认关；与 W9 commitTextRetention 同语义）。
    public var commitTextRetention: Bool

    public init(
        c1Enabled: Bool = false,
        c1Screen: Bool = true,
        c1Audio: Bool = true,
        prompterEnabled: Bool = true,
        prompterBackend: String = "null",
        hubBaseURL: String = "http://localhost:8088",
        debounceSeconds: TimeInterval = 2.0,
        commitTextRetention: Bool = false
    ) {
        self.c1Enabled = c1Enabled
        self.c1Screen = c1Screen
        self.c1Audio = c1Audio
        self.prompterEnabled = prompterEnabled
        self.prompterBackend = prompterBackend
        self.hubBaseURL = hubBaseURL
        self.debounceSeconds = debounceSeconds
        self.commitTextRetention = commitTextRetention
    }

    /// 从 Info.plist（Squirrel 进程）读取；CLI/测试无键时取默认值（C1 默认关）。
    /// 环境变量可覆盖（脚本化实测用）：MINE_W12_C1 / MINE_W12_PROMPTER_BACKEND / MINE_W12_HUB_URL。
    public static func load(bundle: Bundle = .main) -> W12Settings {
        var s = W12Settings()
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            (bundle.object(forInfoDictionaryKey: key) as? Bool) ?? fallback
        }
        func str(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String)
                .map { ($0 as NSString).expandingTildeInPath }
        }
        s.c1Enabled = bool("W12C1Enabled", false)   // 默认关：显式开启才采 C1
        s.c1Screen = bool("W12C1Screen", true)
        s.c1Audio = bool("W12C1Audio", true)
        s.prompterEnabled = bool("W12PrompterEnabled", true)
        s.prompterBackend = str("W12PrompterBackend") ?? "null"
        s.hubBaseURL = str("W12HubURL") ?? "http://localhost:8088"
        if let v = str("W12DebounceSeconds"), let d = Double(v) { s.debounceSeconds = d }

        let env = ProcessInfo.processInfo.environment
        if let v = env["MINE_W12_C1"] { s.c1Enabled = (v == "1" || v.lowercased() == "true") }
        if let v = env["MINE_W12_PROMPTER_BACKEND"], !v.isEmpty { s.prompterBackend = v }
        if let v = env["MINE_W12_HUB_URL"], !v.isEmpty { s.hubBaseURL = v }
        return s
    }
}

/// C1 显式开关（持久在 InteractionStore meta，跨进程生效；默认关）。
/// 语义与 W9 `enableClipboardCollection(explicitConfirm:)` 同构：不显式确认就拒绝开启。
public enum W12Privacy {
    /// 显式开启 C1 采集（explicitConfirm 必须为 true，模拟「用户知情同意」）。
    @discardableResult
    public static func enableC1(store: InteractionStore, explicitConfirm: Bool) -> Bool {
        guard explicitConfirm else { return false }
        store.metaSet("c1_enabled", "1")
        return true
    }

    public static func disableC1(store: InteractionStore) {
        store.metaSet("c1_enabled", "0")
    }

    /// 运行时显式开关状态（meta）。
    public static func isC1ExplicitlyEnabled(store: InteractionStore) -> Bool {
        store.metaGet("c1_enabled") == "1"
    }
}

/// 状态条指示色约定（**文档化**，任务书 (d)；菜单栏/浮层状态点统一取色）：
///
/// | 状态 | 色值 | 含义 |
/// |---|---|---|
/// | `.off` 灰 | `#8E8E8E` | C1 关（仅 C0 或全关，无快照/转写采集） |
/// | `.c0` 青绿 | `#388A83` | 采集正常（C0：输入历史/应用名） |
/// | `.active` 金 | `#D4A857` | C1 采集激活（快照/转写进行中） |
/// | `.paused` 红 | `#C0453E` | 熔断开启 / 安全输入（密码框）暂停 |
///
/// 设计语言色板对齐 design-language（青 `#388A83`、金 `#D4A857`）。
public enum W12StatusColor: String {
    case off = "#8E8E8E"
    case c0 = "#388A83"
    case active = "#D4A857"
    case paused = "#C0453E"

    /// 由当前采集状态取色（优先级：暂停 > 激活 > C0 > 关）。
    public static func current(
        c1Enabled: Bool, breakerTripped: Bool,
        secureInputPaused: Bool, c1Active: Bool
    ) -> W12StatusColor {
        if breakerTripped || secureInputPaused { return .paused }
        if c1Enabled && c1Active { return .active }
        if c1Enabled { return .c0 }
        return .off
    }
}
