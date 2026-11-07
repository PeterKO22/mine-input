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

// ------------------------------------------------------------ W27 e2e 注入探针

/// 捕获后端：断言推荐链请求（SuggestContext）真实携带 screen_text。
final class W27CaptureBackend: SuggestBackend {
    var seen: SuggestContext?
    func suggest(ctx: SuggestContext, timeout: TimeInterval,
                 onUpdate: @escaping (SuggestUpdate) -> Void) async {
        seen = ctx
        onUpdate(SuggestUpdate(status: .kDone))
    }
}

/// W27-fix 探针伪时钟：防抖时序完全由注入时间驱动（零真实 sleep、零墙钟竞态）。
final class W27ProbeClock {
    var now: TimeInterval = 1_000.0
    func advance(_ s: TimeInterval) { now += s }
}

/// W27 验收探针（注入式，W27-fix 确定性版）：同一 onInputEvent → 快照→Vision OCR→
/// 上下文存储→推荐链全链路，逐案例断言**采集次数与时机**（与 Squirrel 内接线同一
/// API，同一落库路径；探针零 open/launch、文件源等价帧零 TCC——构建树 Squirrel.app
/// 绝不运行，真机 IME 只用装机版 Squirrel-dev.app，红线见 W27-REPORT.md §9.5）：
///   1. 开 C1 后「打字」（注入按键事件 + 等价截屏帧）→ 首键即采集入库（screen+OCR 条目
///      且 SuggestContext 带屏幕文本）；同会话同刻 5 键 → 0 新增（逐键 debounced 断言）；
///      注入时间推进出防抖窗 → 恢复采集（窗口外每窗最多一轮）；
///   2. 关 C1 → 零采集；  3. 密码框 → 零采集；  4. 熔断 → 零采集；
///   5. PTT 语音触发（右⌘/⌃⌥M 同一入口）→ **防抖窗内仍即时读屏**（绕防抖实锤），
///      pttEnd 收口零采集。
/// W27-fix 确定性化（原 18/18 时序脆弱不可重现，勘误见 W27-REPORT.md §9）：
///   - 防抖时序走 `W12C1Collector.clock` 注入伪时间（案例间 advance 推移，零真实 sleep）；
///   - 探针独立库（固定路径每轮重建，起止复位 C1/熔断）：消除共享 interaction.db 的
///     c1_enabled meta 跨轮泄漏与 Query limit 行数饱和两大不可重现主因；
///   - 注入帧固定文件名：输出跨轮逐字一致。
func cmdW27E2E(_ args: [String]) {
    let opts = Opts(args)
    // 探针独立库：固定路径、每轮重建（sqlite 侧文件同清）；--db 显式指定时不重建。
    let probeDB = NSTemporaryDirectory() + "w27-e2e-probe.db"
    let bridge: W12EventBridge
    if let db = opts.db {
        bridge = W12EventBridge(path: (db as NSString).expandingTildeInPath)
    } else {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: probeDB + suffix)
        }
        bridge = W12EventBridge(path: probeDB)
    }
    // 状态起止复位：C1 显式开关/熔断绝不跨案例、跨轮泄漏。
    W12Privacy.disableC1(store: bridge.store)
    bridge.breaker.reset()
    var failures = 0
    func check(_ ok: Bool, _ label: String) {
        print("\(ok ? "PASS" : "FAIL"): \(label)")
        if !ok { failures += 1 }
    }
    let rows = { bridge.store.query(InteractionStore.Query(limit: 1000)) }

    // 注入等价截屏帧（同一 OCR→摘要→入库链路；真实 ScreenCaptureKit 需 TCC，另行实测）
    let imagePath: URL
    do {
        imagePath = try W27ProbeImage.make(marker: "W27SCREENMARK TextEdit meeting notes 2026")
    } catch {
        print("FAIL: 生成注入截屏帧失败: \(error)")
        exit(1)
    }
    let clock = W27ProbeClock()
    let collector = W12C1Collector(bridge: bridge, settings: W12Settings(debounceSeconds: 0.6))
    collector.screenContext = ScreenTextContext()   // 探针独立环，不污染进程单例
    collector.captureSourceOverride = .imageFile(imagePath)
    collector.clock = { clock.now }                 // W27-fix：防抖时钟注入（伪时间）
    let appId = opts.appId ?? "com.apple.TextEdit"

    func fireEvent(_ trigger: W12InputTrigger, secureInput: Bool) -> W12C1Collector.Outcome {
        let sem = DispatchSemaphore(value: 0)
        var out: W12C1Collector.Outcome = .skipped("none")
        collector.onInputEvent(trigger, appId: appId, secureInput: secureInput) {
            out = $0; sem.signal()
        }
        sem.wait()
        return out
    }

    print("== W27 e2e 注入探针（onInputEvent → 快照→OCR→上下文存储→推荐链；W27-fix 确定性版）==")
    print("db: \(bridge.store.path ?? "(default)")（\(opts.db == nil ? "探针独立库·每轮重建" : "调用方指定")）  image: \(imagePath.path)")
    print("时钟: 注入伪时间 t0=1000.0s（案例间 advance 推移，零真实 sleep）")

    // ---- 场景 2：C1 默认关 → 零采集
    let base0 = bridge.store.count()
    let out0a = fireEvent(.keystroke, secureInput: false)
    let out0b = fireEvent(.keystroke, secureInput: false)
    check(bridge.store.count() == base0, "关 C1（默认关）→ 零采集（count \(base0) 不变）")
    if case .refused(let r) = out0a, r.contains("disabled"), case .refused = out0b {
        check(true, "关 C1 拒收原因：\(r)")
    } else {
        check(false, "关 C1 应 refused(disabled)（实际 \(out0a) / \(out0b)）")
    }

    // ---- 场景 1：开 C1 → 打字 → screen+OCR 条目 + SuggestContext 带屏幕文本
    W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
    // 首键触发采集（异步 OCR）；同会话**同一伪时刻**连打 5 键（t+0.0s，必落防抖窗内
    // ——确定性合并断言，不再依赖真实打字速度/OCR 耗时）。
    let sem1 = DispatchSemaphore(value: 0)
    var out1: W12C1Collector.Outcome = .skipped("none")
    collector.onInputEvent(.keystroke, appId: appId, secureInput: false) {
        out1 = $0; sem1.signal()
    }
    var mergeReasons: [String] = []
    for _ in 0..<5 {
        collector.onInputEvent(.keystroke, appId: appId, secureInput: false) { o in
            if case .skipped(let r) = o { mergeReasons.append(r) }
        }
    }
    sem1.wait()
    guard case .ingested(let id, let digest) = out1 else {
        check(false, "开 C1 打字 → 采集入库（实际 \(out1)）")
        exit(1)
    }
    check(id > 0 && W12Digest.isSummaryOnly(digest), "采集入库 event_id=\(id) digest=摘要（不含全文）")
    let mergeOK = mergeReasons.count == 5
        && mergeReasons.allSatisfy { $0 == "debounced (0.0s < 0.6s)" }
    check(mergeOK, "同一输入会话内合并（t+0.0s 同刻 5 键 → debounced ×\(mergeReasons.count)/5，0 新增）")
    check(bridge.store.count() == base0 + 1, "合并后采集计数（时机）：6 键 → 1 轮（count \(base0) → \(base0 + 1)）")
    let ocrRows = rows().filter { $0.ocrDigest != nil }
    check(ocrRows.count == 1, "采集日志出现 screen+OCR 条目（ocrDigest 非空 ×\(ocrRows.count)）")
    check(ocrRows.allSatisfy { $0.textIn.isEmpty && $0.textOut.isEmpty }, "OCR 条目原文零落库（text_in/out 空）")
    check(!ocrRows.contains { $0.ocrDigest!.contains("W27SCREENMARK") }, "digest 列绝不含 OCR 全文")

    // ---- 场景 1b（时机）：注入时间 +0.7s 推出防抖窗（0.7s > 0.6s）→ 恢复采集
    clock.advance(0.7)
    let base1 = bridge.store.count()
    let out1b = fireEvent(.keystroke, secureInput: false)
    if case .ingested(let id1b, let d1b) = out1b, id1b > 0, W12Digest.isSummaryOnly(d1b) {
        check(true, "出防抖窗（t+0.7s > 0.6s）→ 恢复采集 event_id=\(id1b)（窗口外每窗最多一轮）")
    } else {
        check(false, "出窗按键应 ingested（实际 \(out1b)）")
    }
    check(bridge.store.count() == base1 + 1, "出窗采集计数（时机）：+1（count \(base1) → \(base1 + 1)）")

    // SuggestContext 带屏幕文本（提词浮层/智能候选请求链捕获断言）
    let ctx = collector.makeSuggestContext(
        beforeCursor: "开会", appId: appId, fromVoice: false, secureInput: false)
    check(!ctx.screenText.isEmpty, "SuggestContext.screenText 非空（近期 OCR 摘要）")
    check(ctx.screenText.contains("W27SCREENMARK"), "screenText 含屏幕 OCR 内容（截断拼接策略生效）")
    let backend = W27CaptureBackend()
    runAsync {
        await W12PrompterModel().run(ctx: ctx, backend: backend, timeout: 0.8)
    }
    check(backend.seen?.screenText == ctx.screenText && !(backend.seen?.screenText.isEmpty ?? true),
          "⌥Esc 提词浮层请求链捕获到 screen_text（注入探针断言）")

    // ---- 场景 3：密码框 → 零采集（+0.7s 出窗触发 → 拒收原因逐字断言，非 debounced）
    clock.advance(0.7)
    let base2 = bridge.store.count()
    let out3 = fireEvent(.keystroke, secureInput: true)
    check(bridge.store.count() == base2, "密码框（secure input）→ 零采集")
    if case .refused(let r) = out3 { check(r.contains("secure"), "密码框拒收原因：\(r)") }
    else { check(false, "密码框应 refused（实际 \(out3)）") }
    let ctxSecure = collector.makeSuggestContext(
        beforeCursor: "密码", appId: appId, secureInput: true)
    check(ctxSecure.screenText.isEmpty, "密码框 → SuggestContext.screenText 空（零带出）")

    // ---- 场景 4：熔断 → 零采集
    clock.advance(0.7)
    bridge.breaker.trip()
    let base3 = bridge.store.count()
    let out4 = fireEvent(.keystroke, secureInput: false)
    check(bridge.store.count() == base3, "熔断 → 零采集")
    if case .refused(let r) = out4 { check(r.contains("circuit breaker"), "熔断拒收原因：\(r)") }
    else { check(false, "熔断应 refused（实际 \(out4)）") }
    let ctxBreaker = collector.makeSuggestContext(beforeCursor: "x", appId: appId)
    check(ctxBreaker.screenText.isEmpty, "熔断 → SuggestContext.screenText 空")
    bridge.breaker.reset()

    // ---- 场景 5：PTT 语音触发（右⌘/⌃⌥M 同一入口）→ 即时读屏（绕防抖实锤）
    // W27-fix：+0.1s **故意落在防抖窗内**（0.1s < 0.6s，距上一采集判定仅 0.1s）——
    // pttStart 必须即时入库；产品缺陷修复前此处被 debounced（旧探针靠 sleep 落窗外才绿）。
    clock.advance(0.1)
    let base4 = bridge.store.count()
    let out5 = fireEvent(.pttStart, secureInput: false)
    check(bridge.store.count() == base4 + 1,
          "PTT 语音触发（onInputEvent .pttStart）防抖窗内（0.1s < 0.6s）→ 即时读屏入库（绕防抖）")
    if case .ingested = out5 {} else { check(false, "pttStart 应 ingested（实际 \(out5)）") }
    let out5end = fireEvent(.pttEnd, secureInput: false)
    check(bridge.store.count() == base4 + 1, "pttEnd 收口触发窗（不采集）")
    if case .skipped(let r) = out5end { check(r.contains("ptt end"), "pttEnd 收口原因：\(r)") }
    else { check(false, "pttEnd 应 skipped（实际 \(out5end)）") }

    // 起止复位：不留跨轮状态（独立库下亦保持卫生习惯）
    W12Privacy.disableC1(store: bridge.store)
    bridge.breaker.reset()
    print("== 结果：\(failures == 0 ? "ALL PASS" : "\(failures) FAILED") ==")
    exit(failures == 0 ? 0 : 1)
}

/// 注入截屏帧生成（等价一帧截屏；同一 OCR→摘要→入库链路的输入源）。
enum W27ProbeImage {
    static func make(marker: String) throws -> URL {
        let img = NSImage(size: NSSize(width: 800, height: 200))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 200).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black]
        (marker as NSString).draw(at: NSPoint(x: 20, y: 80), withAttributes: attrs)
        img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        // W27-fix：固定文件名（原 UUID 名跨轮漂移，破坏输出逐字一致；每轮覆盖写）
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "w27-probe-frame.png")
        try png.write(to: url)
        return url
    }
}

// ------------------------------------------------------------ main

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("""
    usage: w12ctl <privacy|c1|bridge|prompter|breaker|hub-token|w27-e2e> ...
      privacy status | privacy c1 on|off
      c1 status | c1 gen-image <png> | c1 ocr --image <png> | c1 capture --source screen
      c1 asr --wav <wav> | c1 trigger --keys N [--image <png>]
      bridge demo
      prompter --backend hub|null [--token T] [--text S] [--adopt N] [--from-voice]
      breaker trip|reset|status
      hub-token --username u --password p [--url http://localhost:8088]
      w27-e2e  （W27 注入探针·确定性版：开C1打字→screen+OCR+屏幕文本 / 关C1 / 密码框 / 熔断 / PTT 绕防抖；注入伪时钟、逐案例断言采集次数与时机）
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
case "w27-e2e": cmdW27E2E(rest)
default:
    print("unknown command: \(cmd)")
    exit(2)
}
