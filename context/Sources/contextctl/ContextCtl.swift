import ContextCore
import Foundation

// contextctl —— W9 上下文引擎 MVP 命令行入口：
//   collect app|inject|clipboard|status   C0 采集（NSWorkspace / 入库 API / 剪贴板默认关）
//   log count|list|export|clear|prune|schema   交互日志：可查可导可一键清空
//   breaker status|trip|reset             熔断开关（全局，跨进程持久）
//   suggest                               Hub /v1/suggest SSE 或 Null 后端（流式）
//   hub-token                             /v1/auth 注册+取 token（demo 用）
//   prompter                              动态提词器流式面板演示（增量输入→实时刷新→Tab 采纳）

@main
struct ContextCtl {
    static func main() async {
        let args = Args(Array(CommandLine.arguments.dropFirst()))
        let dbPath = args.flag("db")
            ?? ProcessInfo.processInfo.environment["MINE_INTERACTION_DB"]
            ?? (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/mine-input/interaction.db")

        do {
            let store = try InteractionStore(path: dbPath)
            let breaker = CircuitBreaker(store: store)
            let collector = C0Collector(store: store, breaker: breaker)
            if args.boolFlag("commit-retention") {
                collector.commitTextRetention = true
            }

            guard let cmd = args.positional.first else {
                print(usage)
                return
            }
            switch cmd {
            case "init":
                print("store ready: \(store.path)")
                print("device_id=\(collector.deviceId) breaker=\(breaker.isTripped ? "TRIPPED" : "off")")
            case "collect":
                try await runCollect(args: args, store: store, breaker: breaker, collector: collector)
            case "log":
                try runLog(args: args, store: store)
            case "breaker":
                runBreaker(args: args, breaker: breaker)
            case "suggest":
                try await runSuggest(args: args)
            case "hub-token":
                try await runHubToken(args: args)
            case "prompter":
                try await runPrompter(args: args, store: store, breaker: breaker, collector: collector)
            case "help", "--help", "-h":
                print(usage)
            default:
                fputs("unknown command: \(cmd)\n\n\(usage)\n", stderr)
                exit(2)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    // ------------------------------------------------------------ collect

    static func runCollect(
        args: Args, store: InteractionStore,
        breaker: CircuitBreaker, collector: C0Collector
    ) async throws {
        guard let sub = args.positional.count > 1 ? args.positional[1] : nil else {
            fputs("collect: need subcommand app|inject|clipboard|status\n", stderr)
            exit(2)
        }
        switch sub {
        case "app":
            let app = C0Collector.frontmostApp()
            print("frontmost_app: \(app.localizedName)")
            print("frontmost_app_id: \(app.bundleId)")

        case "inject":
            // 输入会话事件入库 API（供 W7 上报）：kind ∈ key_session/voice_session/
            // candidate_pick/suggestion_feedback（与 hub EventKind 同枚举）。
            let kind = EventKind(rawValue: args.flag("kind") ?? "key_session") ?? .keySession
            let result = collectorInject(
                collector: collector, kind: kind, args: args)
            switch result {
            case .stored(let id):
                print("stored: event_id=\(id) kind=\(kind.rawValue)")
            case .refused(let err):
                print("refused: \(err)")
                exit(3)
            }

        case "clipboard":
            if args.boolFlag("enable-explicit") {
                let ok = collector.enableClipboardCollection(explicitConfirm: true)
                print("clipboard_collection: explicit-enabled=\(ok)（仅记摘要与长度，不记内容）")
            } else {
                print("clipboard_collection: \(collector.clipboardCollectionEnabled ? "on" : "off")（默认关，需 --enable-explicit 显式开启）")
            }
            if collector.clipboardCollectionEnabled {
                switch collector.recordClipboardSample() {
                case .stored(let id):
                    print("clipboard sample stored: event_id=\(id)（digest/len only）")
                case .refused(let err):
                    print("clipboard sample refused: \(err)")
                    exit(3)
                }
            }

        case "status":
            let app = C0Collector.frontmostApp()
            print("db: \(store.path)")
            print("device_id: \(collector.deviceId)")
            print("frontmost_app: \(app)")
            print("breaker: \(breaker.isTripped ? "TRIPPED（一切采集已停）" : "off")")
            print("clipboard_collection: \(collector.clipboardCollectionEnabled ? "on" : "OFF（默认关）")")
            print("commit_text_retention: \(collector.commitTextRetention ? "on" : "off（默认关）")")
            print("events_total: \(store.count())")

        default:
            fputs("collect: unknown subcommand \(sub)\n", stderr)
            exit(2)
        }
    }

    static func collectorInject(
        collector: C0Collector, kind: EventKind, args: Args
    ) -> InteractionStore.InsertResult {
        let secure = args.boolFlag("secure-input")
        let textIn = args.flag("text-in") ?? ""
        let textOut = args.flag("text-out") ?? ""
        let cadence = args.flag("cadence").flatMap(Double.init)
        let shown = args.flag("shown").flatMap(Int.init)
        let taken = args.flag("taken").flatMap(Int.init)
        let appId = args.flag("app-id")
        let ts = args.flag("ts").flatMap(Int64.init) // 事件时间（Unix 毫秒），回放/配对演示用
        switch kind {
        case .voiceSession:
            return collector.recordVoiceSession(
                textIn: textIn, textOut: textOut,
                suggestionShown: shown, suggestionTaken: taken,
                appId: appId, secureInput: secure, ts: ts)
        case .candidatePick:
            return collector.recordCandidatePick(
                textIn: textIn, textOut: textOut,
                keystrokeCadence: cadence, appId: appId, secureInput: secure, ts: ts)
        case .suggestionFeedback:
            return collector.recordSuggestionFeedback(
                shown: shown ?? 0, taken: taken ?? 0,
                textIn: textIn, adoptedText: textOut, appId: appId, ts: ts)
        case .keySession:
            return collector.recordKeySession(
                textIn: textIn, textOut: textOut,
                keystrokeCadence: cadence,
                suggestionShown: shown, suggestionTaken: taken,
                appId: appId, secureInput: secure, ts: ts)
        }
    }

    // ------------------------------------------------------------ log

    static func runLog(args: Args, store: InteractionStore) throws {
        guard let sub = args.positional.count > 1 ? args.positional[1] : nil else {
            fputs("log: need subcommand count|list|export|clear|prune|schema\n", stderr)
            exit(2)
        }
        switch sub {
        case "count":
            let kind = args.flag("kind").flatMap(EventKind.init(rawValue:))
            print("events: \(store.count(kind: kind))")
        case "list":
            var q = InteractionStore.Query()
            q.limit = args.flag("limit").flatMap(Int.init) ?? 20
            q.kind = args.flag("kind").flatMap(EventKind.init(rawValue:))
            for ev in store.query(q) {
                print("\(ev.ts) \(ev.kind.rawValue) app=\(ev.appId) " +
                    "in=\(ev.textIn) out=\(ev.textOut) " +
                    "cadence=\(ev.keystrokeCadence.map { String(format: "%.1f", $0) } ?? "-") " +
                    "shown=\(ev.suggestionShown.map(String.init) ?? "-") " +
                    "taken=\(ev.suggestionTaken.map(String.init) ?? "-")")
            }
        case "export":
            let format = args.flag("format") ?? "jsonl"
            let text = format == "csv" ? store.exportCSV() : store.exportJSONL()
            if let out = args.flag("out") {
                try text.write(toFile: out, atomically: true, encoding: .utf8)
                print("exported(\(format)): \(out)")
            } else {
                print(text, terminator: "")
            }
        case "clear":
            let n = store.clearAll()
            print("cleared: \(n) events removed（一键清空完成；meta 保留）")
        case "prune":
            let days = args.flag("days").flatMap(Int.init) ?? 30
            let n = store.prune(olderThanDays: days)
            print("pruned: \(n) events older than \(days)d removed（30 天滚动）")
        case "schema":
            print(store.schemaSQL())
        default:
            fputs("log: unknown subcommand \(sub)\n", stderr)
            exit(2)
        }
    }

    // ------------------------------------------------------------ breaker

    static func runBreaker(args: Args, breaker: CircuitBreaker) {
        guard let sub = args.positional.count > 1 ? args.positional[1] : nil else {
            fputs("breaker: need subcommand status|trip|reset\n", stderr)
            exit(2)
        }
        switch sub {
        case "trip":
            breaker.trip()
            print("breaker: TRIPPED（一切采集立即停；日志保留不新增）")
        case "reset":
            breaker.reset()
            print("breaker: off（采集恢复）")
        case "status":
            breaker.refresh()
            print("breaker: \(breaker.isTripped ? "TRIPPED" : "off")")
        default:
            fputs("breaker: unknown subcommand \(sub)\n", stderr)
            exit(2)
        }
    }

    // ------------------------------------------------------------ suggest

    static func makeBackend(args: Args) async throws -> (SuggestBackend, String) {
        let kind = args.flag("backend") ?? "null"
        switch kind {
        case "hub":
            let hub = URL(string: args.flag("hub")
                ?? ProcessInfo.processInfo.environment["MINE_HUB_URL"]
                ?? "http://localhost:8088")!
            var token = args.flag("token")
                ?? ProcessInfo.processInfo.environment["MINE_HUB_TOKEN"]
            if token == nil {
                let user = args.flag("username") ?? "w9-demo"
                let pass = args.flag("password") ?? "w9-demo-pass"
                token = try await HubAuth.token(
                    baseURL: hub, username: user, password: pass)
            }
            return (HubSuggestBackend(baseURL: hub, token: token!), "hub \(hub.absoluteString)")
        default:
            return (NullSuggestBackend(), "null（离线兜底）")
        }
    }

    static func runSuggest(args: Args) async throws {
        let (backend, label) = try await makeBackend(args: args)
        let timeout = (args.flag("timeout-ms").flatMap(Double.init) ?? 800) / 1000
        let text = args.flag("text") ?? ""
        let ctx = SuggestContext(
            beforeCursor: text,
            appId: args.flag("app-id") ?? "",
            fromVoice: args.boolFlag("from-voice"),
            contextDigest: args.flag("digest") ?? "")
        print("suggest backend: \(label)  timeout=\(Int(timeout * 1000))ms（超时弃本轮，NFR3）")
        print("ctx: before_cursor=\(text) from_voice=\(ctx.fromVoice)")
        let result = await SuggestRound.run(backend: backend, ctx: ctx, timeout: timeout)
        _ = result
    }

    // ------------------------------------------------------------ hub-token

    static func runHubToken(args: Args) async throws {
        let hub = URL(string: args.flag("hub")
            ?? ProcessInfo.processInfo.environment["MINE_HUB_URL"]
            ?? "http://localhost:8088")!
        let user = args.flag("username") ?? "w9-demo"
        let pass = args.flag("password") ?? "w9-demo-pass"
        let token = try await HubAuth.token(baseURL: hub, username: user, password: pass)
        print(token)
    }

    // ------------------------------------------------------------ prompter

    /// 动态提词器流式面板演示（FR5 / §8.2 三唤起之「⌥Esc 流式面板」与「语音随转写刷新」）：
    /// 输入行 = 转写/上下文增量（每行触发一轮 suggest 流式刷新）；
    /// `\t` 行 / `tab` / `/tab` = Tab 采纳（只建议不上屏，Tab/数字/点按才采纳）；
    /// `/1..9` = 选择候选；`/q` 退出。
    static func runPrompter(
        args: Args, store: InteractionStore,
        breaker: CircuitBreaker, collector: C0Collector
    ) async throws {
        let (backend, label) = try await makeBackend(args: args)
        let timeout = (args.flag("timeout-ms").flatMap(Double.init) ?? 800) / 1000
        let fromVoice = args.boolFlag("from-voice")

        print("══ 动态提词器 · 终端流式面板演示 ══")
        print("感应点：⌥Esc（IME 热键唤起流式面板；语音中随转写 300–500ms 增量刷新）")
        print("backend: \(label)  timeout=\(Int(timeout * 1000))ms")
        print("命令：<文本>=转写/上下文增量  \\t|tab=Tab 采纳  /1-9=选中  /q=退出")
        print("")

        var ctx = SuggestContext(beforeCursor: "", fromVoice: fromVoice)
        var lastCandidates: [Candidate] = []
        var selected = 0
        var roundNo = 0

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "/q" { print("· 退出提词器"); break }

            let isTab = line == "\t" || trimmed == "tab" || trimmed == "/tab"
            if isTab {
                guard !lastCandidates.isEmpty else {
                    print("[TAB] 无可采纳建议（当前面板为空）")
                    continue
                }
                let idx = min(selected, lastCandidates.count - 1)
                let pick = lastCandidates[idx]
                print("[TAB] 采纳 → \(pick.text)  (score=\(String(format: "%.2f", pick.score)) source=\(pick.source))")
                // 只建议不上屏：采纳才写日志（suggestion_feedback，taken=1）。
                let res = collector.recordSuggestionFeedback(
                    shown: lastCandidates.count, taken: 1,
                    textIn: String(ctx.beforeCursor.suffix(16)),
                    adoptedText: pick.text)
                switch res {
                case .stored(let id):
                    print("        · 采纳事件已入库 event_id=\(id)（kind=suggestion_feedback）")
                case .refused(let err):
                    print("        · 入库被拒：\(err)")
                }
                ctx.beforeCursor += pick.text
                selected = 0
                continue
            }

            if trimmed.hasPrefix("/"), let n = Int(trimmed.dropFirst()), (1...9).contains(n) {
                if n <= lastCandidates.count {
                    selected = n - 1
                    print("[选中] 候选 \(n)：\(lastCandidates[selected].text)")
                } else {
                    print("[选中] 无候选 \(n)（当前 \(lastCandidates.count) 条）")
                }
                continue
            }

            // 转写/上下文增量 → 建议实时刷新
            roundNo += 1
            ctx.beforeCursor += line
            print("── 刷新 #\(roundNo) · 增量「\(line)」（上下文累计 \(ctx.beforeCursor.count) 字）──")
            let result = await SuggestRound.run(
                backend: backend, ctx: ctx, timeout: timeout,
                prefix: "  ")
            lastCandidates = result.candidates
            selected = 0

            // 增量事件入库（C0：输入历史；语音转写增量记 voice_session，打字增量记 key_session）。
            let res: InteractionStore.InsertResult = fromVoice
                ? collector.recordVoiceSession(
                    textIn: line, suggestionShown: lastCandidates.count, suggestionTaken: 0)
                : collector.recordKeySession(
                    textIn: line, suggestionShown: lastCandidates.count, suggestionTaken: 0)
            switch res {
            case .stored(let id):
                print("  · 增量事件入库 event_id=\(id)（kind=\(fromVoice ? "voice_session" : "key_session")）")
            case .refused(let err):
                print("  · 增量事件入库被拒：\(err)")
            }
        }
        print("提词器演示结束：共 \(roundNo) 轮刷新。")
    }

    // ------------------------------------------------------------ usage

    static let usage = """
    contextctl —— mine-input W9 上下文引擎 MVP（C0 级）
    usage:
      contextctl init [--db PATH]
      contextctl collect app
      contextctl collect inject --kind key_session|voice_session|candidate_pick|suggestion_feedback
                    [--text-in S] [--text-out S] [--cadence X] [--shown N] [--taken N]
                    [--app-id A] [--device-id D] [--secure-input] [--ts MS] [--db PATH]
      contextctl collect clipboard [--enable-explicit] [--db PATH]
      contextctl collect status [--db PATH]
      contextctl log count|list|export|clear|prune|schema [--limit N] [--kind K]
                    [--format jsonl|csv] [--out F] [--days N] [--db PATH]
      contextctl breaker status|trip|reset [--db PATH]
      contextctl suggest --text S [--backend hub|null] [--hub URL] [--token T]
                    [--username U --password P] [--from-voice] [--timeout-ms N]
      contextctl hub-token [--hub URL] [--username U] [--password P]
      contextctl prompter [--backend hub|null] [--hub URL] [--token T] [--from-voice]
                    [--timeout-ms N] [--db PATH] [--commit-retention]
    env: MINE_INTERACTION_DB / MINE_HUB_URL / MINE_HUB_TOKEN / MINE_DEVICE_ID
    """
}

// ------------------------------------------------------------ suggest 轮次（流式打印）

/// 一轮 suggest 的流式消费：先若干 kDelta，后恰好一次终止（kDone/kError/kTimeout）。
enum SuggestRound {
    struct Result {
        var candidates: [Candidate] = []
        var terminal: StreamStatus = .kTimeout
        var elapsedMs: Int = 0
    }

    static func run(
        backend: SuggestBackend, ctx: SuggestContext,
        timeout: TimeInterval, prefix: String = ""
    ) async -> Result {
        let start = Date()
        let state = RoundState()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            state.continuation = cont
            Task {
                await backend.suggest(ctx: ctx, timeout: timeout) { upd in
                    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                    switch upd.status {
                    case .kDelta:
                        for c in upd.candidates {
                            let seq = c.seq.map { "\($0)" } ?? "-"
                            print(String(
                                format: "%@Δ +%4dms [%@] %@  (%.2f %@)",
                                prefix, elapsed, seq, c.text, c.score, c.source))
                        }
                        state.append(upd.candidates)
                    case .kDone:
                        print("\(prefix)✓ done +\(elapsed)ms（建议刷新完成）")
                        state.finish(.kDone, elapsed: elapsed, cont: cont)
                    case .kError:
                        print("\(prefix)✗ error +\(elapsed)ms：\(upd.error)")
                        state.finish(.kError, elapsed: elapsed, cont: cont)
                    case .kTimeout:
                        print("\(prefix)⏱ timeout +\(elapsed)ms：\(upd.error)（弃本轮，NFR3）")
                        state.finish(.kTimeout, elapsed: elapsed, cont: cont)
                    }
                }
            }
        }
        return Result(
            candidates: state.candidates,
            terminal: state.terminal,
            elapsedMs: state.elapsedMs)
    }
}

private final class RoundState {
    private let lock = NSLock()
    private var _candidates: [Candidate] = []
    private var _terminal: StreamStatus?
    private var _elapsed = 0
    var continuation: CheckedContinuation<Void, Never>?

    var candidates: [Candidate] {
        lock.lock(); defer { lock.unlock() }
        return _candidates
    }
    var terminal: StreamStatus {
        lock.lock(); defer { lock.unlock() }
        return _terminal ?? .kTimeout
    }
    var elapsedMs: Int {
        lock.lock(); defer { lock.unlock() }
        return _elapsed
    }

    func append(_ cs: [Candidate]) {
        lock.lock(); _candidates.append(contentsOf: cs); lock.unlock()
    }

    /// 恰好一次终止：重复终止事件丢弃（契约：终止之后的更新必须丢弃）。
    func finish(_ s: StreamStatus, elapsed: Int, cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        guard _terminal == nil else { lock.unlock(); return }
        _terminal = s
        _elapsed = elapsed
        lock.unlock()
        cont.resume()
    }
}

// ------------------------------------------------------------ 参数解析

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    private static let boolFlags: Set<String> = [
        "secure-input", "enable-explicit", "from-voice", "commit-retention",
    ]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let tok = argv[i]
            if tok.hasPrefix("--") {
                let name = String(tok.dropFirst(2))
                if Self.boolFlags.contains(name) {
                    switches.insert(name)
                    i += 1
                } else if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    flags[name] = argv[i + 1]
                    i += 2
                } else {
                    flags[name] = ""
                    i += 1
                }
            } else {
                positional.append(tok)
                i += 1
            }
        }
    }

    func flag(_ name: String) -> String? {
        guard let v = flags[name], !v.isEmpty else { return nil }
        return v
    }

    func boolFlag(_ name: String) -> Bool { switches.contains(name) }
}
