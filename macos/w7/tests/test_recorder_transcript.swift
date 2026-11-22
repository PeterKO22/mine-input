/*
 * test_recorder_transcript.swift — W31 记录员模式伪时钟单测（零 sleep）
 *
 * 被测对象：macos/w7/src/W7RecorderTranscript.swift（纯 Foundation，与本文件同编译单元；
 * 锁定态用例同时编入 W7PttLockMachine.swift 模拟 W28 锁定相位）。
 * 硬约束（W27-fix/W28 前车之鉴）：时间一律伪时钟注入（session.clock / machine.clock），
 * 禁止 Thread.sleep 真实等待——本文件全量用例均推进注入时间；mock daemon 注入转写结果。
 *
 * 运行：bash build/w7-test-recorder-transcript.sh（swiftc 独立编译，
 * 产物 build/w7/tests/test_recorder_transcript，日志 build/logs/w7-test-recorder-transcript.log）。
 *
 * 用例覆盖（对应任务 (1)(2)(3)(4)）：
 *   10s tick 触发分段 / 断句（静音 ≥0.6s）触发分段 / 双触发防重（同刻齐发只出一段）/
 *   稿面累加与头部截断+… / 停止合并上屏内容逐字断言（标点拼接规则）/ Esc 全部丢弃含迟到
 *   转写 / 锁定态速记稿持续更新（W28 锁定提示共存）/ daemon 失败稿面「转写暂不可用」
 *   不阻断录音 / 低置信·空段不入稿 / 常量命名值。
 */
import Foundation

var passed = 0
var failed = 0

func expect(_ cond: Bool, _ name: String) {
  if cond {
    passed += 1
    print("PASS: \(name)")
  } else {
    failed += 1
    print("FAIL: \(name)")
  }
}

func expectEq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
  if got == want {
    passed += 1
    print("PASS: \(name)")
  } else {
    failed += 1
    print("FAIL: \(name) — got \(got), want \(want)")
  }
}

/// 伪时钟：手动推进，零真实等待。
final class FakeClock {
  var now: TimeInterval = 1000.0
  func advance(_ dt: TimeInterval) { now += dt }
}

/// mock daemon：注入转写结果（可同步/可挂起后手动回填），记录调用次数与音频。
final class MockDaemon {
  var queue: [W7SegmentResult] = []
  var deferred: [(W7SegmentResult, (W7SegmentResult) -> Void)] = []
  var deferMode = false
  var callCount = 0
  var audioSeen: [Data] = []
  func transcribe(_ audio: Data, _ done: @escaping (W7SegmentResult) -> Void) {
    callCount += 1
    audioSeen.append(audio)
    let result = queue.isEmpty
      ? W7SegmentResult(text: "", lowConfidence: true, error: "mock 无预置结果")
      : queue.removeFirst()
    if deferMode {
      deferred.append((result, done))
    } else {
      done(result)
    }
  }
  func flushNext() {
    guard !deferred.isEmpty else { return }
    let (result, done) = deferred.removeFirst()
    done(result)
  }
}

func good(_ text: String) -> W7SegmentResult {
  W7SegmentResult(text: text, lowConfidence: false, error: nil)
}

/// 稿面回调记录盒（引用语义，避免闭包捕获 inout 指针）。
final class DisplayLog {
  var lines: [String] = []
}

func makeSession(_ clock: FakeClock, _ mock: MockDaemon,
                 _ log: DisplayLog? = nil) -> W7RecorderTranscriptSession {
  let s = W7RecorderTranscriptSession()
  s.clock = { clock.now }
  s.takeSegmentAudio = { Data([0x11, 0x22, 0x33]) }
  s.transcribe = { audio, done in mock.transcribe(audio, done) }
  s.onDisplay = { line in log?.lines.append(line) }
  return s
}

@main
struct TestRecorderTranscript {
  static func main() {
    runAllTests()
    print("== W31 记录员模式单测（伪时钟，零 sleep，mock daemon）==")
    print("== 结果：\(failed == 0 ? "ALL PASS" : "FAILED") — \(passed)/\(passed + failed) ==")
    exit(failed == 0 ? 0 : 1)
  }
}

func runAllTests() {

// MARK: - 常量（命名常量，任务 (1) 指定值）

do {
  expectEq(W7RecorderTranscriptFormat.segmentTickSeconds, 10.0, "常量：segmentTickSeconds == 10.0")
  expectEq(W7RecorderTranscriptFormat.gapSilenceSeconds, 0.6, "常量：gapSilenceSeconds == 0.6")
}

// MARK: - (1) 10s tick 触发分段

do {
  let clock = FakeClock()
  let mock = MockDaemon()
  mock.queue = [good("第一段。")]
  let log = DisplayLog()
  let s = makeSession(clock, mock, log)
  s.start()
  expectEq(log.lines.last, "🎙 速记：正在听…", "tick 分段：开始即空稿面「🎙 速记：正在听…」")
  s.noteAudioChunk(silent: false)          // 语音
  clock.advance(5.0)
  s.noteAudioChunk(silent: false)          // 语音持续（无断句）
  clock.advance(5.0)                        // t = 10.0s
  s.tick()
  expectEq(mock.callCount, 1, "tick 分段：10.0s tick 触发一次转写")
  expectEq(mock.audioSeen.first, Data([0x11, 0x22, 0x33]), "tick 分段：切段音频送达 daemon")
  expectEq(log.lines.last, "🎙 速记：第一段。｜正在听…", "tick 分段：转写文本入稿面（｜分隔 · 正在听…尾）")
  if let remain = s.secondsToNextTick() {
    expect(abs(remain - 10.0) < 0.001, "tick 分段：切段后下次定时 ≈ 10s")
  } else {
    expect(false, "tick 分段：切段后下次定时 ≈ 10s")
  }
}

// MARK: - (1) 断句（静音 ≥ 0.6s）触发分段

do {
  let clock = FakeClock()
  let mock = MockDaemon()
  mock.queue = [good("断句段。")]
  let s = makeSession(clock, mock)
  s.start()
  s.noteAudioChunk(silent: false)          // 语音
  clock.advance(0.3)
  s.noteAudioChunk(silent: true)           // 静音 0.3s
  clock.advance(0.25)
  s.noteAudioChunk(silent: true)           // 静音累计 0.55s
  expectEq(mock.callCount, 0, "断句边界：静音 0.55s 不触发")
  clock.advance(0.3)
  s.noteAudioChunk(silent: true)           // 静音累计 ≈0.85s
  expectEq(mock.callCount, 1, "断句触发：静音 ≥0.6s 触发一次分段转写")
  expectEq(s.panelLine(), "🎙 速记：断句段。｜正在听…", "断句触发：稿面更新")
}

// MARK: - (1) 双触发防重（tick 与断句同刻齐发只出一段）

do {
  // 断句先切（9.6s），10.0s tick 再来 → 不再转写
  let clock = FakeClock()
  let mock = MockDaemon()
  mock.queue = [good("唯一段。")]
  let s = makeSession(clock, mock)
  s.start()
  s.noteAudioChunk(silent: false)
  clock.advance(9.0)
  s.noteAudioChunk(silent: false)
  clock.advance(0.35)
  s.noteAudioChunk(silent: true)
  clock.advance(0.35)
  s.noteAudioChunk(silent: true)           // t=9.7s 断句切段
  expectEq(mock.callCount, 1, "双触发防重：断句切段 1 次")
  clock.advance(0.3)                        // t=10.0s
  s.tick()
  expectEq(mock.callCount, 1, "双触发防重：随后 tick 不再切段（无新语音）")
  s.tick(); s.tick()
  expectEq(mock.callCount, 1, "双触发防重：重复 tick 仍不补段")
}

do {
  // tick 先切（10.0s），紧随的长静音不补段（无新语音）
  let clock = FakeClock()
  let mock = MockDaemon()
  mock.queue = [good("唯一段。")]
  let s = makeSession(clock, mock)
  s.start()
  s.noteAudioChunk(silent: false)
  clock.advance(10.0)
  s.tick()
  expectEq(mock.callCount, 1, "双触发防重（反向）：tick 切段 1 次")
  for _ in 0..<20 {
    clock.advance(0.1)
    s.noteAudioChunk(silent: true)         // 10s→12s 连续静音
  }
  expectEq(mock.callCount, 1, "双触发防重（反向）：长静音不补空段")
}

// MARK: - (2) 稿面累加与头部截断 + …

do {
  let clock = FakeClock()
  let mock = MockDaemon()
  mock.queue = [good("第一段。"), good("第二段。"), good(String(repeating: "A", count: 40)),
                good(String(repeating: "B", count: 20))]
  let s = makeSession(clock, mock)
  s.start()
  s.noteAudioChunk(silent: false)
  clock.advance(10.0); s.tick()            // 段1
  s.noteAudioChunk(silent: false)
  clock.advance(10.0); s.tick()            // 段2
  expectEq(s.panelLine(), "🎙 速记：第一段。｜第二段。｜正在听…", "稿面累加：两段 ｜ 分隔逐字")
  s.noteAudioChunk(silent: false)
  clock.advance(10.0); s.tick()            // 段3（A×40）
  s.noteAudioChunk(silent: false)
  clock.advance(10.0); s.tick()            // 段4（B×20）→ 总长 61 > 48
  let expected = "🎙 速记：…" + String(repeating: "A", count: 27) + "｜"
    + String(repeating: "B", count: 20) + "｜正在听…"
  expectEq(s.panelLine(), expected, "稿面截断：超长头部截断 +「…」保尾部（逐字）")
}

// MARK: - (3) 停止合并上屏内容逐字断言（标点拼接规则）

do {
  let clock = FakeClock()
  let mock = MockDaemon()
  mock.queue = [good("今天天气不错。"), good("我们去公园吧"), good("好啊！")]
  let s = makeSession(clock, mock)
  s.start()
  s.noteAudioChunk(silent: false)
  clock.advance(10.0); s.tick()            // 段1「今天天气不错。」
  s.noteAudioChunk(silent: false)
  clock.advance(10.0); s.tick()            // 段2「我们去公园吧」
  s.noteAudioChunk(silent: false)          // 段3 有语音
  var outcomes: [W7StopOutcome] = []
  s.stop { outcomes.append($0) }
  expectEq(mock.callCount, 3, "停止合并：最后一段也送转写")
  expectEq(outcomes.count, 1, "停止合并：收口回调只来一次")
  expectEq(outcomes.first, .commit("今天天气不错。我们去公园吧，好啊！"),
           "停止合并：上屏内容逐字（。直拼 / 无标点边界插「，」）")
  expectEq(s.panelLine(), "🎙 速记：正在听…", "停止合并：收口后会话复位空稿")
}

do {
  // 拼接规则补例：后段以标点开头 → 直拼
  expectEq(W7RecorderTranscriptFormat.mergedText(["前段", "，后段"]),
           "前段，后段", "拼接规则：后段首字符是标点 → 直拼")
  expectEq(W7RecorderTranscriptFormat.mergedText(["", "甲", "乙"]),
           "甲，乙", "拼接规则：空段跳过 + 无标点边界插「，」")
  expectEq(W7RecorderTranscriptFormat.mergedText([]), "", "拼接规则：全空 → 空串")
}

// MARK: - (3) Esc 全部丢弃（含迟到转写）

do {
  let clock = FakeClock()
  let mock = MockDaemon()
  mock.deferMode = true
  mock.queue = [good("秘密内容。")]
  let s = makeSession(clock, mock)
  s.start()
  s.noteAudioChunk(silent: false)
  clock.advance(10.0); s.tick()            // 段1 转写挂起
  expectEq(mock.callCount, 1, "Esc：分段已送转写")
  s.abort()                                // Esc 取消
  expectEq(s.panelLine(), "🎙 速记：正在听…", "Esc：稿面清空")
  mock.flushNext()                         // 迟到转写结果
  expectEq(s.panelLine(), "🎙 速记：正在听…", "Esc：迟到转写忽略（不回填稿面）")
  var outcomes: [W7StopOutcome] = []
  s.stop { outcomes.append($0) }
  expectEq(outcomes, [.empty], "Esc：取消后 stop 不上屏（无 commit）")
  expectEq(s.isRunning, false, "Esc：会话不再运行")
}

// MARK: - (3) 锁定态（W28）速记稿持续更新（锁定提示共存）

do {
  let clock = FakeClock()
  let mock = MockDaemon()
  mock.queue = [good("第一段。"), good("第二段。")]
  let machine = W7PttLockMachine()
  machine.clock = { clock.now }
  let s = makeSession(clock, mock)
  s.isLocked = { machine.phase == .locked }
  s.start()
  expectEq(machine.pressBegan(), .beginRecording, "锁定态前置：按下开始录音")
  s.noteAudioChunk(silent: false)
  clock.advance(10.1)
  expectEq(machine.tick(), .lock, "锁定态前置：10.1s 锁定（W28 语义）")
  s.tick()                                  // t=10.1 ≥ 10.0 → 切段1
  let line1 = s.panelLine()
  expect(line1.hasPrefix("🔒 已锁定录音中…（可以松开按键了 · 轻点右⌘ 停止上屏 · Esc 取消）\n"),
         "锁定态：W28 锁定提示行在场（逐字）")
  expect(line1.contains("🎙 速记：第一段。｜正在听…"), "锁定态：速记稿随锁定持续更新")
  s.noteAudioChunk(silent: false)
  clock.advance(10.0)
  s.tick()                                  // 切段2
  let line2 = s.panelLine()
  expect(line2.contains("第一段。｜第二段。｜正在听…"), "锁定态：新段落持续累加（最新段 ｜ 分隔）")
  expect(line2.hasPrefix("🔒 已锁定录音中…（可以松开按键了 · 轻点右⌘ 停止上屏 · Esc 取消）\n"),
         "锁定态：持续更新后锁定提示不丢（视觉共存不冲突）")
}

// MARK: - (4) daemon 失败：稿面「转写暂不可用」不阻断录音

do {
  let clock = FakeClock()
  let mock = MockDaemon()
  mock.queue = [W7SegmentResult(text: "", lowConfidence: true, error: "语音守护进程不可用"),
                good("好的。"),
                W7SegmentResult(text: "", lowConfidence: true, error: nil)]
  let s = makeSession(clock, mock)
  s.start()
  s.noteAudioChunk(silent: false)
  clock.advance(10.0); s.tick()            // 段1 daemon 失败
  expect(s.panelLine().contains("转写暂不可用"), "daemon 失败：稿面显示「转写暂不可用」")
  s.noteAudioChunk(silent: false)          // 录音未中断
  clock.advance(10.0); s.tick()            // 段2 正常
  expectEq(s.panelLine(), "🎙 速记：转写暂不可用｜好的。｜正在听…",
           "daemon 失败：后续分段照常入稿（不阻断录音）")
  s.noteAudioChunk(silent: false)
  var outcomes: [W7StopOutcome] = []
  s.stop { outcomes.append($0) }           // 段3 低置信
  expectEq(outcomes, [.commit("好的。")], "daemon 失败：失败段/低置信段不入合并稿")
}

// MARK: - (3) 低置信/空段不入稿（沿用 W7 启发式）

do {
  let clock = FakeClock()
  let mock = MockDaemon()
  mock.queue = [W7SegmentResult(text: "", lowConfidence: true, error: nil),
                W7SegmentResult(text: "", lowConfidence: false, error: nil)]
  let s = makeSession(clock, mock)
  s.start()
  s.noteAudioChunk(silent: false)
  clock.advance(10.0); s.tick()
  s.noteAudioChunk(silent: false)
  clock.advance(10.0); s.tick()
  expectEq(s.panelLine(), "🎙 速记：正在听…", "低置信/空段：不入稿面")
  var outcomes: [W7StopOutcome] = []
  s.stop { outcomes.append($0) }
  expectEq(outcomes, [.empty], "低置信/空段：全稿为空 → 不上屏（.empty）")
}

}  // runAllTests
