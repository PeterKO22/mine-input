// w12ctl —— W12 脚本化实测 CLI（macos/w12 共享源码的独立驱动）。
// 与 Squirrel 内接线走同一套 API（W12EventBridge / W12C1Collector / W12PrompterModel），
// 用于验收序列：触发采集→OCR 摘要入库→sqlite3 可查→熔断后停止→提词浮层流式刷新演示。
import AppKit
import Foundation

#if canImport(ContextCore)
import ContextCore
#endif
import W12Core

// ------------------------------------------------------------ 参数解析

struct Opts {
    var db: String?
    var appId: String?
    var secureInput = false
    var image: String?
    var wav: String?
    var source = "image"
    var backend = "null"
    var token = ""
    var text = ""
    var adopt = -1
    var fromVoice = false
    var keys = 1
    var url = "http://localhost:8088"
    var username = ""
    var password = ""
    var commitRetention = false

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            func next() -> String { i += 1; return i < args.count ? args[i] : "" }
            switch a {
            case "--db": db = next()
            case "--app-id": appId = next()
            case "--secure-input": secureInput = true
            case "--image": image = next()
            case "--wav": wav = next()
            case "--source": source = next()
            case "--backend": backend = next()
            case "--token": token = next()
            case "--text": text = next()
            case "--adopt": adopt = Int(next()) ?? -1
            case "--from-voice": fromVoice = true
            case "--keys": keys = Int(next()) ?? 1
            case "--url": url = next()
            case "--username": username = next()
            case "--password": password = next()
            case "--commit-retention": commitRetention = true
            default: break
            }
            i += 1
        }
    }
}

func makeBridge(_ opts: Opts) -> W12EventBridge {
    if let db = opts.db { return W12EventBridge(path: (db as NSString).expandingTildeInPath) }
    return W12EventBridge.shared
}

func repoRoot() -> String {
    var dir = FileManager.default.currentDirectoryPath
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: dir + "/voice/mic/ptt_daemon.py") { return dir }
        dir = (dir as NSString).deletingLastPathComponent
    }
    return FileManager.default.currentDirectoryPath
}

func desc(_ o: W12C1Collector.Outcome) -> String {
    switch o {
    case .ingested(let id, let digest):
        return digest.isEmpty ? "stored: event_id=\(id)" : "stored: event_id=\(id) digest=\(digest)"
    case .refused(let r): return "refused: \(r)"
    case .skipped(let r): return "skipped: \(r)"
    }
}

func runAsync(_ body: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task {
        await body()
        sem.signal()
    }
    sem.wait()
}

// ------------------------------------------------------------ 命令

func cmdPrivacy(_ args: [String]) {
    let opts = Opts(args)
    let bridge = makeBridge(opts)
    let sub = args.first ?? "status"
    switch sub {
    case "c1":
        let action = args.count > 1 ? args[1] : "status"
        if action == "on" {
            let ok = W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
            print("c1 explicit enable: \(ok)（meta c1_enabled=1，跨进程生效）")
        } else if action == "off" {
            W12Privacy.disableC1(store: bridge.store)
            print("c1 explicit disable: meta c1_enabled=0")
        }
    default:
        break
    }
    let settings = W12Settings.load()
    let explicit = W12Privacy.isC1ExplicitlyEnabled(store: bridge.store)
    print("== W12 隐私设置 ==")
    print("C1 总开关: \(settings.c1Enabled || explicit)（Info.plist W12C1Enabled=\(settings.c1Enabled) + 显式 meta=\(explicit)；**默认关**）")
    print("  子开关: screen=\(settings.c1Screen) audio=\(settings.c1Audio)")
    print("  触发: 仅输入时（PTT 期间 + 按键触发窗），防抖 \(Int(settings.debounceSeconds))s")
    print("  安全输入（密码框）: 自动停不可关（IsSecureEventInputEnabled）")
    print("  黑名单: \(C0Collector.defaultBlacklist.count) 个敏感应用，命中跳过")
    print("  熔断: breaker=\(bridge.breaker.isTripped ? "TRIPPED" : "off")（trip 后立即停，日志保留不新增）")
    print("  上屏文本留存(L3): \(settings.commitTextRetention ? "on" : "off（默认）")")
    print("  状态条指示色约定: 灰#8E8E8E=采集关 / 青绿#388A83=仅C0 / 金#D4A857=C1采集激活 / 红#C0453E=熔断或安全输入暂停")
}

func cmdC1(_ args: [String]) {
    let opts = Opts(args)
    let bridge = makeBridge(opts)
    let collector = W12C1Collector(
        bridge: bridge, settings: {
            var s = W12Settings.load()
            s.commitTextRetention = opts.commitRetention
            return s
        }())
    let sub = args.first ?? "status"
    let appId = opts.appId ?? "com.apple.TextEdit"

    switch sub {
    case "status":
        print("C1 enabled: \(collector.isC1Enabled)（显式开关，默认关）")
        print("screen: \(collector.settings.c1Screen)  audio: \(collector.settings.c1Audio)")
        print("debounce: \(collector.settings.debounceSeconds)s（防抖，仅输入时触发）")
        print("breaker: \(bridge.breaker.isTripped ? "TRIPPED" : "off")")
        let color = W12StatusColor.current(
            c1Enabled: collector.isC1Enabled, breakerTripped: bridge.breaker.isTripped,
            secureInputPaused: false, c1Active: false)
        print("status color: \(color.rawValue)（\(color)）")

    case "gen-image":
        // 测试夹具：生成一张含中文的「截屏帧」PNG（同一条 OCR→摘要→入库 链路的输入源）
        let path = opts.image ?? (args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "/tmp/w12-test.png")
        let img = NSImage(size: NSSize(width: 800, height: 220))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 220).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        ("会议纪要 W12 上下文采集测试 2026-11-04" as NSString)
            .draw(at: NSPoint(x: 20, y: 80), withAttributes: attrs)
        img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: path))
        print("test image written: \(path) (\(png.count) bytes)")

    case "ocr":
        // OCR 摘要入库（--image 文件源 = 等价截屏帧；--source screen 走 ScreenCaptureKit）
        guard let imagePath = opts.image else {
            print("usage: w12ctl c1 ocr --image <png> [--app-id X] [--secure-input]")
            exit(2)
        }
        let source: W12CaptureSource = opts.source == "screen"
            ? .screen : .imageFile(URL(fileURLWithPath: (imagePath as NSString).expandingTildeInPath))
        print("capture source: \(opts.source == "screen" ? "screen (ScreenCaptureKit)" : "image file（等价截屏帧）")")
        runAsync {
            let t = await collector.captureAndIngest(
                source: source, kind: .keySession,
                appId: appId, secureInput: opts.secureInput)
            print(desc(t))
        }

    case "capture":
        // 真 ScreenCaptureKit 屏幕快照（需屏幕录制 TCC；未授权→明确报错，不伪造）
        runAsync {
            let t = await collector.captureAndIngest(
                source: .screen, kind: .keySession,
                appId: appId, secureInput: opts.secureInput)
            print(desc(t))
        }

    case "asr":
        // 音频 → W2 管线（voice/mic/ptt_daemon）→ asr_digest 入库（仅摘要/长度）
        guard let wavPath = opts.wav else {
            print("usage: w12ctl c1 asr --wav <wav> [--app-id X] [--secure-input]")
            exit(2)
        }
        let root = repoRoot()
        let client = W12AsrClient(
            pythonPath: ProcessInfo.processInfo.environment["MINE_VOICE_PYTHON"]
                ?? root + "/voice/.venv/bin/python",
            daemonPath: root + "/voice/mic/ptt_daemon.py",
            hotwords: root + "/voice/poc/hotwords.txt")
        do {
            let pcm = try W12AsrClient.loadPCM16_16k(
                url: URL(fileURLWithPath: (wavPath as NSString).expandingTildeInPath))
            print("wav loaded: \(wavPath) pcm16=\(pcm.count) bytes（16k mono，内存）")
            let t = collector.transcribeAndIngest(
                pcm16: pcm, client: client, appId: appId, secureInput: opts.secureInput)
            print(desc(t))
        } catch {
            print("refused: wav load failed: \(error)")
            exit(1)
        }

    case "trigger":
        // 防抖 2s + 仅输入时触发的判定演示（模拟 N 次按键）；--image 时触发轮真实入库
        let debounce = collector.settings.debounceSeconds
        var now = Date().timeIntervalSince1970
        var lastCapture: TimeInterval? = nil
        var lastKey: TimeInterval? = nil
        print("模拟按键 ×\(opts.keys)（防抖 \(Int(debounce))s，仅输入时触发）：")
        var captured = 0
        let t0 = now
        for k in 1...opts.keys {
            lastKey = now
            let d = W12C1Collector.decideTrigger(
                now: now, lastCaptureAt: lastCapture, lastKeyAt: lastKey,
                pttActive: false, debounce: debounce)
            print("  key#\(k) t+\(String(format: "%.1f", now - t0))s → capture=\(d.shouldCapture) (\(d.reason))")
            if d.shouldCapture {
                lastCapture = now
                captured += 1
                if let imagePath = opts.image {
                    runAsync {
                        let t = await collector.captureAndIngest(
                            source: .imageFile(URL(fileURLWithPath: imagePath)),
                            kind: .keySession, appId: appId, secureInput: opts.secureInput)
                        print("    → \(desc(t))")
                    }
                }
            }
            now += 1.0  // 每秒一次按键
        }
        print("触发采集 \(captured)/\(opts.keys) 轮（防抖收敛）")

    default:
        print("unknown c1 subcommand: \(sub)")
        exit(2)
    }
}

func cmdBridge(_ args: [String]) {
    let opts = Opts(args)
    let bridge = makeBridge(opts)
    let appId = opts.appId ?? "com.apple.TextEdit"
    print("== W7×W9 接线：W7 事件 → W9 InteractionStore（同一 API，Squirrel 调用点相同）==")
    let r1 = bridge.reportKeySession(
        textIn: "ni hao", textOut: "你好", cadence: 3.2, appId: appId)
    print("输入会话 key_session: \(desc(mapInsert(r1)))")
    let r2 = bridge.reportVoiceSession(
        textIn: "", textOut: "今天开会。", appId: appId)
    print("语音会话 voice_session: \(desc(mapInsert(r2)))")
    let r3 = bridge.reportCandidatePick(
        textIn: "zni", textOut: "智能", cadence: 2.8, appId: appId)
    print("候选选择 candidate_pick: \(desc(mapInsert(r3)))")
}

func mapInsert(_ r: InteractionStore.InsertResult) -> W12C1Collector.Outcome {
    switch r {
    case .stored(let id): return .ingested(id: id, digest: "")
    case .refused(let e): return .refused("\(e)")
    }
}

func cmdPrompter(_ args: [String]) {
    let opts = Opts(args)
    let bridge = makeBridge(opts)
    let settings = W12Settings.load()
    let backend: SuggestBackend = opts.backend == "hub"
        ? HubSuggestBackend(
            baseURL: URL(string: opts.url.isEmpty ? settings.hubBaseURL : opts.url)!,
            token: opts.token)
        : NullSuggestBackend()
    let text = opts.text.isEmpty ? "今天开会" : opts.text
    let ctx = SuggestContext(
        beforeCursor: text, appId: opts.appId ?? "com.apple.TextEdit",
        fromVoice: opts.fromVoice)

    print("══ ⌥Esc 提词浮层 · 流式刷新演示（W12PrompterModel，与 NSPanel 浮层同一模型）══")
    print("感应点：⌥Esc（IME 热键唤起 NSPanel 流层；语音中随转写增量刷新）")
    print("backend: \(opts.backend == "hub" ? "hub \(opts.url)" : "null（离线兜底）")  timeout=800ms（超时弃本轮，NFR3）")

    let model = W12PrompterModel()
    runAsync {
        await model.run(ctx: ctx, backend: backend, timeout: 0.8) { frame in
            if frame.status == .kDelta, let line = model.refreshLog.last {
                print(line)
                // 实时刷新：每帧 Δ 重绘浮层快照（NSPanel 同数据源）
                print(model.renderPanel().components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n"))
            }
        }
        if let last = model.refreshLog.last { print(last) }
    }

    let idx = opts.adopt
    if idx >= 0 || opts.adopt == -1 {
        // Tab 采纳（默认第 1 条）：suggestion_feedback 入库 + 返回上屏文本
        if let chosen = model.adopt(index: max(idx, 0), textIn: text, appId: ctx.appId, bridge: bridge) {
            print("[TAB] 采纳 → \(chosen.text)  (score=\(String(format: "%.2f", chosen.score)) source=\(chosen.source))")
            print("        · suggestion_feedback 已入库（shown=\(model.candidates.count) taken=1）")
        } else {
            print("[TAB] 无可采纳候选")
        }
    }
}

func cmdBreaker(_ args: [String]) {
    let opts = Opts(args)
    let bridge = makeBridge(opts)
    switch args.first ?? "status" {
    case "trip":
        bridge.breaker.trip()
        print("breaker: TRIPPED（一切采集立即停；日志保留不新增）")
    case "reset":
        bridge.breaker.reset()
        print("breaker: off（采集恢复）")
    default:
        print("breaker: \(bridge.breaker.isTripped ? "TRIPPED" : "off")")
    }
}

func cmdHubToken(_ args: [String]) {
    let opts = Opts(args)
    runAsync {
        do {
            let token = try await HubAuth.token(
                baseURL: URL(string: opts.url)!,
                username: opts.username.isEmpty ? "w12" : opts.username,
                password: opts.password.isEmpty ? "w12pass" : opts.password)
            print(token)  // stdout 只出 token（demo 脚本捕获用；本地 dev 凭证）
        } catch {
            FileHandle.standardError.write(Data("hub-token failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

// ------------------------------------------------------------ main

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("""
    usage: w12ctl <privacy|c1|bridge|prompter|breaker|hub-token> ...
      privacy status | privacy c1 on|off
      c1 status | c1 gen-image <png> | c1 ocr --image <png> | c1 capture --source screen
      c1 asr --wav <wav> | c1 trigger --keys N [--image <png>]
      bridge demo
      prompter --backend hub|null [--token T] [--text S] [--adopt N] [--from-voice]
      breaker trip|reset|status
      hub-token --username u --password p [--url http://localhost:8088]
    全局: --db <sqlite 路径>（默认 ~/Library/Application Support/mine-input/interaction.db）
    """)
    exit(0)
}
let rest = Array(args.dropFirst())
switch cmd {
case "privacy": cmdPrivacy(rest)
case "c1": cmdC1(rest)
case "bridge": cmdBridge(rest)
case "prompter": cmdPrompter(rest)
case "breaker": cmdBreaker(rest)
case "hub-token": cmdHubToken(rest)
default:
    print("unknown command: \(cmd)")
    exit(2)
}
