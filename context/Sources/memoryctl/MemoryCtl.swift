import ContextCore
import Foundation
import MemoryCore

// memoryctl —— W19 记忆层（JSONL 对话记忆库，§15.1）命令行入口：
//   pair                W9 事件流 → 「情境→回复」配对落盘（一次输入会话=一条记忆，取消不记）
//   query               检索（回忆）：--keyword / --app / --since
//   recent              最近 N 条（suggest 上下文注入接口）
//   edit | delete       手工编辑（重写当日文件）/ 删除（物理移除行）
//   clear               一键清空（事件层+记忆层同清）
//   sync export|enqueue 同步挂钩：W8 同构事件体 JSONL（直进 ingest 队列）
//   status              状态（目录/条数/熔断）

@main
struct MemoryCtl {
    static func main() {
        let args = Args(Array(CommandLine.arguments.dropFirst()))
        let dbPath = args.flag("db")
            ?? ProcessInfo.processInfo.environment["MINE_INTERACTION_DB"]
            ?? (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/mine-input/interaction.db")
        let memDir = args.flag("memory-dir")
            ?? ProcessInfo.processInfo.environment["MINE_MEMORY_DIR"]
            ?? MemoryStore.defaultRoot()

        do {
            let events = try InteractionStore(path: dbPath)
            let memory = MemoryStore(rootDir: memDir, interactionStore: events)

            guard let cmd = args.positional.first else {
                print(usage)
                return
            }
            switch cmd {
            case "pair":
                try runPair(args: args, events: events, memory: memory)
            case "query":
                runQuery(args: args, memory: memory)
            case "recent":
                runRecent(args: args, memory: memory)
            case "edit":
                try runEdit(args: args, memory: memory)
            case "delete":
                try runDelete(args: args, memory: memory)
            case "clear":
                runClear(args: args, events: events, memory: memory)
            case "sync":
                try runSync(args: args, memory: memory, events: events)
            case "status":
                runStatus(events: events, memory: memory, dbPath: dbPath)
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

    // ------------------------------------------------------------ pair（事件流→记忆）

    /// 从 W9 事件流配对「情境→回复」并落盘：一次输入会话=一条记忆；取消不记；
    /// session_id 确定性生成 → 重放幂等（已记会话跳过）。
    static func runPair(args: Args, events: InteractionStore, memory: MemoryStore) throws {
        var q = InteractionStore.Query()
        q.limit = 1_000_000
        let stream = events.query(q) // DESC → pair 内部按 ts 正序
        var options = MemoryPairing.Options()
        if let gap = args.flag("gap-ms").flatMap(Int64.init) { options.sessionGapMs = gap }
        if let dev = args.flag("device"), !dev.isEmpty { options.device = dev }

        let outcome = MemoryPairing.pair(events: stream, options: options)
        var appended = 0
        var skipped = 0
        for rec in outcome.memories {
            if memory.hasSession(rec.meta.sessionId) {
                skipped += 1
                continue
            }
            switch memory.append(rec) {
            case .appended(let id):
                appended += 1
                print("memory: id=\(id) session=\(rec.meta.sessionId)")
                print("  \(try rec.jsonLine())")
            case .refused(let err):
                print("refused: \(err)")
                exit(3)
            }
        }
        print(
            "paired: \(outcome.sessionCount) sessions → \(outcome.memories.count) memories " +
            "(\(outcome.cancelledCount) cancelled not recorded; appended=\(appended) dedup-skipped=\(skipped))")
    }

    // ------------------------------------------------------------ query（--keyword/--app/--since）

    static func runQuery(args: Args, memory: MemoryStore) {
        let records = memory.query(
            keyword: args.flag("keyword"),
            app: args.flag("app"),
            since: parseSince(args.flag("since")),
            limit: args.flag("limit").flatMap(Int.init) ?? 50)
        printRecords(records, jsonl: args.boolFlag("jsonl"))
        print("matched: \(records.count)")
    }

    // ------------------------------------------------------------ recent（suggest 注入接口）

    static func runRecent(args: Args, memory: MemoryStore) {
        let n = args.flag("limit").flatMap(Int.init) ?? 5
        if args.boolFlag("for-suggest") {
            // 供 suggest 上下文注入（§15.1：最近 N 条自动注入 suggest 上下文）。
            for line in memory.recentForSuggest(n) { print(line) }
        } else {
            printRecords(memory.recent(n), jsonl: args.boolFlag("jsonl"))
        }
    }

    // ------------------------------------------------------------ edit / delete（N8 手工调整）

    static func runEdit(args: Args, memory: MemoryStore) throws {
        guard let id = args.flag("id") else {
            fputs("edit: need --id\n", stderr)
            exit(2)
        }
        let updated = try memory.edit(
            id: id,
            beforeCursor: args.flag("before-cursor"),
            thread: args.flag("thread").map { $0.components(separatedBy: "|") },
            replyText: args.flag("reply"),
            mode: args.flag("mode").flatMap(MyReply.Mode.init(rawValue:)))
        print("edited: id=\(updated.id)（当日文件已重写）")
        print(try updated.jsonLine())
    }

    static func runDelete(args: Args, memory: MemoryStore) throws {
        guard let id = args.flag("id") else {
            fputs("delete: need --id\n", stderr)
            exit(2)
        }
        let removed = try memory.delete(id: id)
        print("deleted: id=\(removed.id)（物理移除该行，导出/同步不再包含）")
    }

    // ------------------------------------------------------------ clear（一键清空：同清）

    static func runClear(args: Args, events: InteractionStore, memory: MemoryStore) {
        if args.boolFlag("memory-only") {
            let m = memory.clearAll()
            print("cleared: \(m) memories removed（记忆层）")
            return
        }
        let (m, e) = MemoryPrivacy.clearAll(memory: memory, events: events)
        print("cleared: \(m) memories + \(e) events removed（一键清空：事件层+记忆层同清）")
    }

    // ------------------------------------------------------------ sync（W8 同构事件体）

    static func runSync(args: Args, memory: MemoryStore, events: InteractionStore) throws {
        guard let sub = args.positional.count > 1 ? args.positional[1] : nil else {
            fputs("sync: need subcommand export|enqueue\n", stderr)
            exit(2)
        }
        let deviceId = args.flag("device") ?? events.deviceId()
        let records = memory.query(
            keyword: args.flag("keyword"),
            app: args.flag("app"),
            since: parseSince(args.flag("since")),
            limit: args.flag("limit").flatMap(Int.init) ?? 1_000_000)
        switch sub {
        case "export":
            let text = MemorySync.exportIngestJSONL(records, deviceId: deviceId)
            if let out = args.flag("out") {
                try text.write(toFile: out, atomically: true, encoding: .utf8)
                print("exported: \(records.count) events → \(out)（W8 同构事件体，可直进 ingest 队列）")
            } else {
                print(text, terminator: "")
            }
        case "enqueue":
            guard let qf = args.flag("queue-file") else {
                fputs("sync enqueue: need --queue-file\n", stderr)
                exit(2)
            }
            let sink = JSONLQueueSink(path: qf)
            let n = try sink.enqueueAll(records, deviceId: deviceId)
            print("enqueued: \(n) events → \(qf)（JSONL 直进 ingest 队列）")
        default:
            fputs("sync: unknown subcommand \(sub)\n", stderr)
            exit(2)
        }
    }

    // ------------------------------------------------------------ status

    static func runStatus(events: InteractionStore, memory: MemoryStore, dbPath: String) {
        print("memory_dir: \(memory.rootDir)")
        print("db: \(dbPath)")
        print("memories_total: \(memory.count())")
        print("events_total: \(events.count())")
        let breaker = CircuitBreaker(store: events)
        breaker.refresh()
        print("breaker: \(breaker.isTripped ? "TRIPPED（记忆停记、采集停）" : "off")")
    }

    // ------------------------------------------------------------ 工具

    static func printRecords(_ records: [MemoryRecord], jsonl: Bool) {
        for r in records {
            if jsonl {
                if let line = try? r.jsonLine() { print(line) }
            } else {
                print("\(r.ts) [\(r.id)] app=\(r.appId) mode=\(r.myReply.mode.rawValue)")
                print("  情境: \(r.situation.beforeCursor)")
                print("  我回: \(r.myReply.text)")
                if !r.situation.thread.isEmpty {
                    print("  thread: \(r.situation.thread.joined(separator: " / "))")
                }
            }
        }
    }

    /// --since 解析：YYYY-MM-DD（本地日起点）| 7d/Nd（N 天前）| ISO8601。
    static func parseSince(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        if s.hasSuffix("d"), let n = Int(s.dropLast()) {
            return Date().addingTimeInterval(TimeInterval(-n) * 24 * 3600)
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        if let d = df.date(from: s) { return d }
        return MemoryRecord.date(fromISO: s)
    }

    static let usage = """
    memoryctl —— mine-input W19 记忆层（JSONL 对话记忆库，技术方案 §15.1）
    usage:
      memoryctl pair [--db PATH] [--memory-dir DIR] [--gap-ms N] [--device D]
      memoryctl query [--keyword K] [--app A] [--since YYYY-MM-DD|7d] [--limit N] [--jsonl]
      memoryctl recent [--limit N] [--for-suggest] [--jsonl]
      memoryctl edit --id UUID [--before-cursor S] [--reply S] [--mode text|voice] [--thread "对方:…|我:…"]
      memoryctl delete --id UUID
      memoryctl clear [--memory-only]          # 默认一键清空：事件层+记忆层同清
      memoryctl sync export [--out F] [--since …] [--limit N]
      memoryctl sync enqueue --queue-file F    # JSONL 直进 ingest 队列
      memoryctl status
    env: MINE_INTERACTION_DB / MINE_MEMORY_DIR / MINE_DEVICE_ID
    隐私红线：熔断停记（breaker trip 后记忆保留不新增）；删除=物理移除行；
              一键清空事件层+记忆层同清；C1 摘要只落摘要/长度不落原文。
    """
}

// ------------------------------------------------------------ 参数解析（与 contextctl 同构）

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    private static let boolFlags: Set<String> = [
        "jsonl", "for-suggest", "memory-only",
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
