/*
 * W7RecorderTranscript.swift — W31 记录员模式：PTT 录音中实时分段转写（纯 Foundation，零 Squirrel 依赖）
 *
 * 需求（用户原话）：「长按之后，每隔10s或者明显断句时，就应该把之前的内容显示出来
 * （不需要直接写到输入框，只在输入法的界面上能看到内容就可以，因为后面还可以调整），
 * 这样才像一个记录员」。
 *
 * 已定规格：
 *   (1) 分段转写：录音进行中，每 segmentTickSeconds（10.0s，命名常量）或明显断句
 *       （连续静音 ≥ gapSilenceSeconds（0.6s，命名常量）启发式，静音判定在采集侧
 *       RMS 启发式、可与 daemon VAD 结论对齐）触发一次——把**已完成的音频段**送
 *       ptt_daemon 转写（带标点），转写文本追加「显示用实时稿」；音频继续累计不受
 *       影响（切段只推进段界，不打断采集）。
 *       双触发防重：一次切段后未有新语音不再送转写（空段只推进段界）；10s 定时点
 *       同时顺延到本次切段后 10s——tick 与断句同刻齐发只出一段。
 *   (2) 面板显示（不进输入框）：panelLine 文案「🎙 速记：<已完成段｜…>｜正在听…」，
 *       段间「｜」分隔（最新段与前段分隔可见）；超长头部截断 + 「…」；锁定态（W28）
 *       上一行保留锁定提示（逐字沿用 w7ShowLockedHint 文案），速记稿持续更新共存。
 *   (3) 停止语义不变：松手/轻点停止 → 最后一段转写 → 全稿合并 → 一次性
 *       w7CommitVoiceText 上屏。标点拼接规则见 W7RecorderTranscriptFormat.mergedText
 *       （注释即规格）；Esc 全部丢弃；低置信/空段不入稿（沿用 W7 启发式）。
 *   (4) daemon 失败：该段稿面显示「转写暂不可用」，不入合并稿、不阻断录音与后续分段。
 *
 * 可测性（W27-fix/W28 同款硬约束）：时钟注入 clock（伪时钟零 Thread.sleep）、
 * 转写注入 transcribe（单测 mock daemon 回填结果）、音频切段注入 takeSegmentAudio。
 * 生产接线见 W7PttController；单测见 macos/w7/tests/test_recorder_transcript.swift。
 */
import Foundation

// MARK: - 分段转写结果与停止收口

/// 一段已完成音频的转写结果（mock daemon 注入面；生产由 W7VoiceResult 映射）。
struct W7SegmentResult: Equatable {
  var text: String = ""
  var lowConfidence: Bool = true
  var error: String? = nil
}

/// 停止收口结果：全稿合并完成（.commit 已按标点规则拼接）或全稿为空
/// （低置信/空段全被滤掉——沿用 W7 启发式不瞎猜）。
enum W7StopOutcome: Equatable {
  case commit(String)
  case empty
}

// MARK: - 稿面文案与拼接规则（唯一规格源）

enum W7RecorderTranscriptFormat {
  /// 分段触发周期（命名常量）：每 10.0s 送一段已完成音频去转写。
  static let segmentTickSeconds: TimeInterval = 10.0
  /// 明显断句启发式阈值（命名常量）：连续静音 ≥ 0.6s 触发分段。
  static let gapSilenceSeconds: TimeInterval = 0.6
  /// 段间分隔符（最新段与前段「分隔」可见）。
  static let segmentSeparator = "｜"
  /// 稿面正文上限（字符）：超出头部截断 + 「…」（保尾部最新内容）。
  static let bodyMaxChars = 48
  /// daemon 失败段的稿面占位文案（不入合并稿）。
  static let unavailableMarker = "转写暂不可用"
  /// W28 锁定提示行（逐字沿用 w7ShowLockedHint 文案，与速记稿多行共存不冲突）。
  static let lockedHintLine = "🔒 已锁定录音中…（可以松开按键了 · 轻点右⌘ 停止上屏 · Esc 取消）"

  /// 面板行合成：
  ///   录音/聆听态：「🎙 速记：<已完成段｜…>｜正在听…」；空稿「🎙 速记：正在听…」；
  ///   稿面超长：头部截断 + 「…」（保尾部）；
  ///   锁定态：上一行 W28 锁定提示 + 换行 + 速记行（同样持续更新）。
  static func panelLine(items: [String], locked: Bool) -> String {
    let joined = items.joined(separator: segmentSeparator)
    let body = joined.count > bodyMaxChars ? "…" + String(joined.suffix(bodyMaxChars)) : joined
    let live = body.isEmpty ? "🎙 速记：正在听…" : "🎙 速记：\(body)\(segmentSeparator)正在听…"
    return locked ? lockedHintLine + "\n" + live : live
  }

  /// 段尾标点（停顿/终止/收引）：前段以此结尾 → 直拼下一段。
  private static let tailPunctuation: Set<Character> =
    ["。", "！", "？", "；", "：", "，", "、", "…", ".", "!", "?", ";", ":", ",",
     "」", "』", "”", "’"]
  /// 段首标点/引括：后段以此开头 → 直拼上一段。
  private static let headPunctuation: Set<Character> =
    ["“", "‘", "「", "『", "（", "(", "《", "【", "[",
     "。", "！", "？", "；", "：", "，", "、", "…", ".", "!", "?", ";", ":", ","]

  /// 标点拼接规则（停止上屏的全稿合并，逐段带标点直拼）：
  ///   ① 空段跳过；② 相邻边界处前段末字符 ∈ 段尾标点、或后段首字符 ∈ 段首标点
  ///   → 直接相连；③ 否则插入「，」（段间本就是语流停顿）。
  ///   例：「今天天气不错。」+「我们去公园吧」+「好啊！」→「今天天气不错。我们去公园吧，好啊！」。
  static func mergedText(_ parts: [String]) -> String {
    var out = ""
    for part in parts where !part.isEmpty {
      guard !out.isEmpty else { out = part; continue }
      if let last = out.last, tailPunctuation.contains(last) { out += part; continue }
      if let first = part.first, headPunctuation.contains(first) { out += part; continue }
      out += "，" + part
    }
    return out
  }
}

// MARK: - 分段转写会话（录音期调度 + 稿面 + 停止收口；主线程使用）

final class W7RecorderTranscriptSession {
  typealias Transcribe = (Data, @escaping (W7SegmentResult) -> Void) -> Void

  /// 伪时钟注入（默认 Date() 墙钟，生产行为不变）——单测零 sleep（W27-fix/W28 模式）。
  var clock: () -> TimeInterval = { Date().timeIntervalSince1970 }
  /// 锁定态查询（W28 状态机相位接线）——panelLine 锁定行多行共存。
  var isLocked: () -> Bool = { false }
  /// 取一段已完成音频（控制器注入环形缓冲切片；每次切段必调——推进段界，
  /// 防止未转写静音段把环形缓冲挤出窗口）。
  var takeSegmentAudio: () -> Data = { Data() }
  /// 转写注入（生产 = ptt_daemon 客户端；单测 mock daemon 注入转写结果）。
  /// 回调可异步；会话状态仅在主线程变更（生产接线处 hop 回主线程）。
  var transcribe: Transcribe = { _, done in
    done(W7SegmentResult(text: "", lowConfidence: true, error: "转写未注入"))
  }
  /// 稿面变化回调（panelLine 全文；每次段落齐/状态变都重发）。
  var onDisplay: (String) -> Void = { _ in }

  private(set) var isRunning = false
  private var stopping = false
  private var stopDone: ((W7StopOutcome) -> Void)?
  private var segmentIndex = 0
  private var displayItems: [Int: String] = [:]  // 段序 → 稿面项（好文本或「转写暂不可用」）
  private var goodTexts: [Int: String] = [:]     // 段序 → 入合并稿文本（低置信/空段不入）
  private var pending = 0
  private var hasSpeechSinceCut = false
  private var silenceRun: TimeInterval = 0
  private var lastChunkAt: TimeInterval = 0
  private var nextTickAt: TimeInterval = 0

  // MARK: 事件

  /// 开始录音：清稿、排下一次 10s 分段定时。
  func start() {
    isRunning = true
    stopping = false
    stopDone = nil
    segmentIndex = 0
    displayItems = [:]
    goodTexts = [:]
    pending = 0
    hasSpeechSinceCut = false
    silenceRun = 0
    let now = clock()
    lastChunkAt = now
    nextTickAt = now + W7RecorderTranscriptFormat.segmentTickSeconds
    emitDisplay()
  }

  /// 音频块观测（静音判定在采集侧 RMS 启发式，见 W7AudioCapture.silenceRMS）。
  /// 连续静音 ≥ gapSilenceSeconds 且本段已有语音 → 断句分段。
  func noteAudioChunk(silent: Bool) {
    guard isRunning, !stopping else { return }
    let now = clock()
    if silent {
      silenceRun += max(0, now - lastChunkAt)
    } else {
      hasSpeechSinceCut = true
      silenceRun = 0
    }
    lastChunkAt = now
    if hasSpeechSinceCut, silenceRun >= W7RecorderTranscriptFormat.gapSilenceSeconds {
      cut()
    }
  }

  /// 10s 分段定时（生产由 W7PttController 定时器驱动；单测伪时钟直调，零 sleep）。
  func tick() {
    guard isRunning, !stopping else { return }
    guard clock() >= nextTickAt else { return }
    cut()
  }

  /// 距下一次 10s 分段定时还剩多少秒（定时器排程用）；未录音/收口中 → nil。
  func secondsToNextTick() -> TimeInterval? {
    guard isRunning, !stopping else { return nil }
    return max(0, nextTickAt - clock())
  }

  /// 停止收口：最后一段转写 → 等全部段落齐 → 全稿合并 → 一次性回调（只回一次）。
  func stop(_ done: @escaping (W7StopOutcome) -> Void) {
    guard isRunning else { done(.empty); return }
    stopping = true
    stopDone = done
    cut()           // 最后一段（含尾部音频）
    finishIfReady() // 同步 mock 时上面已收口，此处幂等
  }

  /// Esc/组合键：全部丢弃（稿面清空、迟到转写忽略、停止回调不再来）。
  func abort() {
    isRunning = false
    stopping = false
    stopDone = nil
    displayItems = [:]
    goodTexts = [:]
    pending = 0
    hasSpeechSinceCut = false
    silenceRun = 0
  }

  /// 当前稿面行（panelLine 全文）。
  func panelLine() -> String {
    W7RecorderTranscriptFormat.panelLine(items: orderedItems(), locked: isLocked())
  }

  // MARK: 私有

  private func orderedItems() -> [String] {
    displayItems.sorted { $0.key < $1.key }.map { $0.value }
  }

  private func emitDisplay() { onDisplay(panelLine()) }

  /// 切段：推进段界（takeSegmentAudio 必调）；本段有新语音才送转写
  /// （空段不入稿不送转写 = 双触发防重：tick 与断句同刻齐发只出一段）。
  private func cut() {
    nextTickAt = clock() + W7RecorderTranscriptFormat.segmentTickSeconds
    silenceRun = 0
    let audio = takeSegmentAudio()
    guard hasSpeechSinceCut else { return }
    hasSpeechSinceCut = false
    let index = segmentIndex
    segmentIndex += 1
    pending += 1
    transcribe(audio) { [weak self] result in
      self?.handleResult(index: index, result: result)
    }
  }

  private func handleResult(index: Int, result: W7SegmentResult) {
    guard isRunning || stopping else { return }  // abort 后迟到结果：丢弃
    pending -= 1
    if result.error != nil {
      // daemon 失败：稿面显示「转写暂不可用」，不入合并稿、不阻断录音
      displayItems[index] = W7RecorderTranscriptFormat.unavailableMarker
    } else if !result.lowConfidence, !result.text.isEmpty {
      goodTexts[index] = result.text
      displayItems[index] = result.text
    }
    // 低置信/空段不入稿（沿用 W7 启发式）：稿面也不占位
    emitDisplay()
    finishIfReady()
  }

  private func finishIfReady() {
    guard stopping, pending == 0, let done = stopDone else { return }
    stopDone = nil
    isRunning = false
    let merged = W7RecorderTranscriptFormat.mergedText(
      goodTexts.sorted { $0.key < $1.key }.map { $0.value })
    displayItems = [:]   // 收口即复位（上屏已一次性交付）
    goodTexts = [:]
    done(merged.isEmpty ? .empty : .commit(merged))
  }
}
