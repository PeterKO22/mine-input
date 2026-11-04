// w20ctl —— W20 脚本化实测 CLI（macos/w20 共享源码的独立驱动）。
// 与 Squirrel 内接线走同一套 API（W20MemoryStore / W20ProposalModel / W20MemoryPanel），
// 覆盖验收「脚本化可验部分（数据层操作）」：时间线/搜索/编辑/删除/导出 + 熔断 +
// 提案卡 state 流转（Null 桩 Swift 镜像）+ 界面形态 dump（panel-dump）。
//
// 用法：
//   w20ctl list|show|search|edit|delete|export   记忆 JSONL 数据层操作（--dir 指定目录）
//   w20ctl breaker status|trip|reset             一键熔断（ContextCore 同源，--db 指定库）
//   w20ctl proposal demo                         提案→确认→执行 state 流转演示（红线断言）
//   w20ctl panel-dump                            记忆管理界面形态 dump（含提案卡）
import AppKit
import Foundation

#if canImport(ContextCore)
import ContextCore
#endif
import W20Core

struct Opts {
    var dir: String?
    var id = ""
    var keyword = ""
    var app = ""
    var since = ""
    var situation = ""
    var thread = ""
    var reply = ""
    var mode = ""
    var out = ""
    var db = ""

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            func next() -> String { i += 1; return i < args.count ? args[i] : "" }
            switch a {
            case "--dir": dir = next()
            case "--id": id = next()
            case "--keyword": keyword = next()
            case "--app": app = next()
            case "--since": since = next()
            case "--situation": situation = next()
            case "--thread": thread = next()
            case "--reply": reply = next()
            case "--mode": mode = next()
            case "--out": out = next()
            case "--db": db = next()
            default: break
            }
            i += 1
        }
    }
}

func makeStore(_ opts: Opts) -> W20MemoryStore {
    W20MemoryStore(directory: opts.dir.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
    })
}

func makeBreaker(_ opts: Opts) -> CircuitBreaker? {
    let path = opts.db.isEmpty
        ? ((NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/mine-input/interaction.db"))
        : (opts.db as NSString).expandingTildeInPath
    guard let store = try? InteractionStore(path: path) else { return nil }
    return CircuitBreaker(store: store)
}

func printEntry(_ e: W20MemoryEntry, verbose: Bool) {
    print("id=\(e.id)  ts=\(e.ts)  app=\(e.appId ?? "-")  consent=\(e.consent ?? "-")")
    if verbose {
        print("  situation.before_cursor: \(e.situation?.beforeCursor ?? "")")
        print("  situation.thread: \(e.situation?.thread ?? [])")
        print("  my_reply.text: \(e.myReply?.text ?? "")  mode=\(e.myReply?.mode ?? "-")")
    } else {
        print("  my_reply: \(e.myReply?.text ?? "")")
    }
}

func runMemory(_ cmd: String, _ opts: Opts) {
    let store = makeStore(opts)
    switch cmd {
    case "list":
        let days = store.days()
        if days.isEmpty { print("(empty) \(store.directory.path)") }
        for d in days {
            print("\(d)  \(store.entries(day: d).count) 条")
        }
    case "show":
        guard let found = store.find(id: opts.id) else {
            print("not found: \(opts.id)")
            return
        }
        printEntry(found.entry, verbose: true)
    case "search":
        let rs = store.search(
            keyword: opts.keyword.isEmpty ? nil : opts.keyword,
            app: opts.app.isEmpty ? nil : opts.app,
            since: opts.since.isEmpty ? nil : opts.since)
        print("hits=\(rs.count)")
        for e in rs { printEntry(e, verbose: false) }
    case "edit":
        let ok = store.update(
            id: opts.id,
            beforeCursor: opts.situation.isEmpty ? nil : opts.situation,
            thread: opts.thread.isEmpty ? nil
                : opts.thread.split(separator: "|").map(String.init),
            replyText: opts.reply.isEmpty ? nil : opts.reply,
            replyMode: opts.mode.isEmpty ? nil : opts.mode)
        print(ok ? "updated: \(opts.id)" : "update failed: \(opts.id)")
    case "delete":
        let ok = store.delete(id: opts.id)
        print(ok ? "deleted: \(opts.id)" : "delete failed: \(opts.id)")
    case "export":
        let rs = store.search(
            keyword: opts.keyword.isEmpty ? nil : opts.keyword,
            app: opts.app.isEmpty ? nil : opts.app)
        let out = URL(fileURLWithPath: (opts.out as NSString).expandingTildeInPath)
        do {
            try store.export(entries: rs, to: out)
            print("exported \(rs.count) 条 → \(out.path)")
        } catch {
            print("export failed: \(error)")
        }
    default:
        print("unknown memory command: \(cmd)")
    }
}

func runBreaker(_ cmd: String, _ opts: Opts) {
    guard let breaker = makeBreaker(opts) else {
        print("breaker: cannot open interaction store")
        return
    }
    switch cmd {
    case "status":
        print("breaker=\(breaker.isTripped ? "TRIPPED（熔断中，停采集）" : "off（采集中）")")
    case "trip":
        breaker.trip()
        print("breaker=TRIPPED（一键熔断生效）")
    case "reset":
        breaker.reset()
        print("breaker=off（已解除熔断）")
    default:
        print("unknown breaker command: \(cmd)")
    }
}

func runProposalDemo() {
    let engine = W20NullProposalEngine()
    print("== propose（只提案，不执行）==")
    let items = engine.propose(secureInput: false)
    for p in items {
        print("proposal id=\(p.id) kind=\(p.kind.rawValue)")
        print("  title: \(p.title)")
        print("  detail: \(p.detail)")
        for a in p.actions { print("  [action] \(a.id) \(a.title) — \(a.detail)") }
    }
    print("executionCount=\(engine.executionCount) （红线：propose 后必须为 0）")

    print("== 红线：伪造 handle observe 拒绝 ==")
    let forged = W20ExecHandle(id: "exec-forged", proposalID: "prop-null-1", state: .queued)
    let refused = engine.observe(forged) { _ in }
    print("observe(forged)=\(refused ? "ACCEPTED(违红线!)" : "refused ✓")  executionCount=\(engine.executionCount)")

    print("== confirm（用户显式确认 → 执行）==")
    let h = engine.confirm(proposalID: "prop-null-1")
    print("handle id=\(h.id) state=\(h.state.rawValue) progress=\(h.progress)")
    print("== observe（进度/结果回填：state 流转）==")
    _ = engine.observe(h) { snap in
        print("  ← state=\(snap.state.rawValue)  progress=\(snap.progress)  result=\(snap.result)")
    }
    let again = engine.confirm(proposalID: "prop-null-1")
    print("重复 confirm: id=\(again.id)（幂等 ✓）  executionCount=\(engine.executionCount)（应为 1）")
}

func runPanelDump(_ opts: Opts) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let store = makeStore(opts)
    let panel = W20MemoryPanel(store: store, breaker: nil,
                               engine: W20NullProposalEngine())
    panel.show()
    print(panel.debugDump())
    panel.close()
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("""
    usage: w20ctl <cmd> [options]
      list|show|search|edit|delete|export   --dir <memory dir> [--id --keyword --app \
    --since --situation --thread --reply --mode --out]
      breaker status|trip|reset             [--db <interaction.db>]
      proposal demo                         提案卡 state 流转（Null 桩）
      panel-dump                            界面形态 dump
    """)
    exit(1)
}
let opts = Opts(Array(args.dropFirst()))
switch cmd {
case "list", "show", "search", "edit", "delete", "export":
    runMemory(cmd, opts)
case "breaker":
    guard let sub = args.dropFirst().first else {
        print("usage: w20ctl breaker status|trip|reset")
        exit(1)
    }
    runBreaker(sub, opts)
case "proposal":
    runProposalDemo()
case "panel-dump":
    runPanelDump(opts)
default:
    print("unknown command: \(cmd)")
    exit(1)
}
