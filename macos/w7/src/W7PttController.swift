/*
 * W7PttController.swift — PTT 语音上屏 + 候选重排挂点的 Swift 侧（W7 macos 集成）
 *
 * 任务 (a) PTT 语音上屏：
 *   - 右⌘ 按住说话（单修饰键，flagsChanged 级监听）；松开 → 处理 → commit 上屏；
 *   - 兜底组合键开关：⌃⌥M（latch 模式：按一下开始、再按一下结束上屏）；
 *   - 录音中 Esc 取消（丢弃音频）；录音中出现其它修饰键 = 组合键用途，取消录音放行；
 *   - AVAudioEngine 采集 → 16k mono 环形缓冲（纯内存，音频不落盘）→
 *     voice/mic/ptt_daemon.py（W2 管线常驻：Silero VAD→SenseVoice int8→
 *     CT-Transformer 标点→hotwords.txt 热词）→ 文本经 SquirrelInputController 上屏；
 *   - 低置信不瞎猜：启发式判低置信时不 commit，面板提示「没听清，请重说」。
 *
 * 任务 (b) 的 Swift 侧在 SquirrelInputController.swift（build/squirrel-w7.patch 注入的
 * w7ShowWithRescore/w7MergeSmart）+ W7RescoreBridge（ObjC++ 桥 → macos/w7/W7RescoreHook）。
 *
 * 配置（resources/Info.plist）：
 *   W7VoiceEnabled / W7RescoreEnabled（Bool）、W7VoicePython / W7VoiceDaemon /
 *   W7Hotwords（路径，~ 展开）、W7SmartTopK（Int，智能组条数，默认 3）。
 */
import AppKit
import AVFoundation

// MARK: - 配置

enum W7Config {
  static func path(_ key: String) -> String? {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String)
      .map { ($0 as NSString).expandingTildeInPath }
  }
  static var voiceEnabled: Bool {
    (Bundle.main.object(forInfoDictionaryKey: "W7VoiceEnabled") as? Bool) ?? false
  }
  static var rescoreEnabled: Bool {
    (Bundle.main.object(forInfoDictionaryKey: "W7RescoreEnabled") as? Bool) ?? false
  }
  static var smartTopK: Int {
    (Bundle.main.object(forInfoDictionaryKey: "W7SmartTopK") as? Int) ?? 3
  }
}

enum W7KeyCode {
  static let rightCommand: UInt16 = 0x36  // kVK_RightCommand
  static let escape: UInt16 = 0x35        // kVK_Escape
  static let mKey: UInt16 = 0x2E          // kVK_ANSI_M
}

// MARK: - 16k mono 环形缓冲（音频不落盘：只在内存）

final class W7RingBuffer {
  private var buf: [Float]
  private var head = 0    // 下一写入位
  private var count = 0
  private let lock = NSLock()

  init(capacity: Int) { buf = [Float](repeating: 0, count: capacity) }

  func reset() {
    lock.lock(); defer { lock.unlock() }
    head = 0; count = 0
  }

  /// 满则覆盖最旧（环形语义）；capacity = 60s@16k，超长录音自动丢最旧段。
  func append(_ samples: UnsafePointer<Float>, count n: Int) {
    lock.lock(); defer { lock.unlock() }
    for i in 0..<n {
      buf[head] = samples[i]
      head = (head + 1) % buf.count
      if count < buf.count { count += 1 }
    }
  }

  /// 导出为 16k mono PCM16LE（内存 bytes，交 daemon → 管线，全程不落盘）。
  func pcm16Data() -> Data {
    lock.lock(); defer { lock.unlock() }
    var data = Data(capacity: count * 2)
    let start = (head - count + buf.count) % buf.count
    for i in 0..<count {
      let s = max(-1.0 as Float, min(1.0 as Float, buf[(start + i) % buf.count]))
      var le = Int16(s * 32767.0).littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    return data
  }
}

// MARK: - AVAudioEngine 采集（16k mono）

final class W7AudioCapture {
  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private let ring = W7RingBuffer(capacity: 16000 * 60)  // 60s 上限
  private var running = false

  func start() throws {
    guard !running else { return }
    ring.reset()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0,
          let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                        channels: 1, interleaved: false),
          let conv = AVAudioConverter(from: inputFormat, to: outFormat) else {
      throw NSError(domain: "w7.voice", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "音频格式转换器初始化失败（无麦克风输入？）"])
    }
    converter = conv
    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      self?.consume(buffer)
    }
    engine.prepare()
    try engine.start()
    running = true
  }

  private func consume(_ buffer: AVAudioPCMBuffer) {
    guard let converter else { return }
    let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
    var error: NSError?
    var consumed = false
    converter.convert(to: out, error: &error) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }
    if error == nil, let ch = out.floatChannelData {
      ring.append(ch[0], count: Int(out.frameLength))
    }
  }

  func stop() -> Data {
    if running {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      running = false
    }
    return ring.pcm16Data()
  }
}

// MARK: - voice/mic/ptt_daemon.py 客户端（JSON-line 协议，模型常驻）

struct W7VoiceResult {
  var text: String = ""
  var lowConfidence: Bool = true
  var reason: String = ""
  var elapsedMs: Double = 0
  var error: String? = nil
}

final class W7VoiceDaemonClient {
  private let pythonPath: String
  private let daemonPath: String
  private let hotwords: String?
  private let repoRoot: String
  private let queue = DispatchQueue(label: "w7.voice.daemon")
  private var proc: Process?
  private var stdinFH: FileHandle?
  private var stdoutFH: FileHandle?
  private var readBuffer = Data()
  private var nextId = 0
  private var completedId = 0
  private var timedOutIds = Set<Int>()

  init(pythonPath: String, daemonPath: String, hotwords: String?) {
    self.pythonPath = pythonPath
    self.daemonPath = daemonPath
    self.hotwords = hotwords
    // daemon 位于 <root>/voice/mic/ptt_daemon.py
    let micDir = (daemonPath as NSString).deletingLastPathComponent
    let voiceDir = (micDir as NSString).deletingLastPathComponent
    self.repoRoot = (voiceDir as NSString).deletingLastPathComponent
  }

  func warmup() {
    queue.async { _ = try? self.ensureRunning() }
  }

  /// pcm16: 16k mono PCM16LE（内存）。回调在内部队列线程。
  func transcribe(_ pcm16: Data, completion: @escaping (W7VoiceResult) -> Void) {
    queue.async {
      do {
        try self.ensureRunning()
        self.nextId += 1
        let myId = self.nextId
        var req: [String: Any] = [
          "id": myId, "cmd": "transcribe", "sample_rate": 16000,
          "pcm16_b64": pcm16.base64EncodedString(),
        ]
        if let hotwords = self.hotwords { req["hotwords"] = hotwords }
        try self.writeRequest(req)

        // 看门狗：管线正常 <1s；20s 未响应 → 判失败并重启守护进程（不挂死 IMK）
        self.queue.asyncAfter(deadline: .now() + 20) {
          if self.completedId < myId && !self.timedOutIds.contains(myId) {
            self.timedOutIds.insert(myId)
            completion(W7VoiceResult(error: "语音识别超时，请重试"))
            self.restart()
          }
        }

        guard let line = self.readLineLocked() else {
          if !self.timedOutIds.contains(myId) {
            self.timedOutIds.insert(myId)
            completion(W7VoiceResult(error: "语音守护进程已退出，请重试"))
          }
          self.restart()
          return
        }
        guard !self.timedOutIds.contains(myId) else { return }  // 已判超时，丢弃迟到结果
        self.completedId = myId
        completion(self.parseResult(line))
      } catch {
        completion(W7VoiceResult(error: "语音守护进程不可用：\(error.localizedDescription)"))
      }
    }
  }

  // MARK: 私有（均为内部队列线程上调用）

  private func ensureRunning() throws {
    if let proc, proc.isRunning { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: pythonPath)
    p.arguments = [daemonPath]
    var env = ProcessInfo.processInfo.environment
    env["PYTHONPATH"] = repoRoot + (env["PYTHONPATH"].map { ":" + $0 } ?? "")
    p.environment = env
    let inPipe = Pipe()
    let outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = FileHandle.standardError
    try p.run()
    proc = p
    stdinFH = inPipe.fileHandleForWriting
    stdoutFH = outPipe.fileHandleForReading
    readBuffer = Data()
    // 启动即预热（warmup 的响应必须消费掉，保持严格请求/响应配对）
    var warmup: [String: Any] = ["id": 0, "cmd": "warmup"]
    if let hotwords { warmup["hotwords"] = hotwords }
    try writeRequest(warmup)
    _ = readLineLocked()
  }

  private func restart() {
    proc?.terminate()
    proc = nil
  }

  private func writeRequest(_ req: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: req)
    data.append(UInt8(ascii: "\n"))
    guard let stdinFH else { throw NSError(domain: "w7.voice", code: 2) }
    try stdinFH.write(contentsOf: data)
  }

  private func readLineLocked() -> String? {
    while true {
      if let idx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
        let line = readBuffer.prefix(upTo: idx)
        readBuffer = Data(readBuffer.suffix(from: readBuffer.index(after: idx)))
        return String(data: line, encoding: .utf8)
      }
      guard let stdoutFH else { return nil }
      let chunk = stdoutFH.availableData
      if chunk.isEmpty { return nil }
      readBuffer.append(chunk)
    }
  }

  private func parseResult(_ line: String) -> W7VoiceResult {
    var result = W7VoiceResult()
    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
      result.error = "响应解析失败"
      return result
    }
    if let ok = obj["ok"] as? Bool, !ok {
      result.error = (obj["error"] as? String) ?? "识别失败"
      return result
    }
    result.text = (obj["text"] as? String) ?? ""
    result.lowConfidence = (obj["low_confidence"] as? Bool) ?? true
    result.reason = (obj["reason"] as? String) ?? ""
    result.elapsedMs = (obj["elapsed_ms"] as? Double) ?? 0
    return result
  }
}

// MARK: - PTT 状态机

final class W7PttController {
  static let shared = W7PttController()

  weak var controller: SquirrelInputController?

  private let capture = W7AudioCapture()
  private lazy var daemon = W7VoiceDaemonClient(
    pythonPath: W7Config.path("W7VoicePython") ?? "",
    daemonPath: W7Config.path("W7VoiceDaemon") ?? "",
    hotwords: W7Config.path("W7Hotwords")
  )
  private(set) var isCapturing = false

  private init() {
    daemon.warmup()  // 首次触碰即预热模型，松开→上屏只等管线推理
  }

  static var voiceEnabled: Bool { W7Config.voiceEnabled }
  static var rescoreEnabled: Bool { W7Config.rescoreEnabled }
  static var smartTopK: Int { W7Config.smartTopK }

  /// SquirrelInputController.handle() 的 PTT 拦截入口。
  /// 返回 true = 事件被 PTT 消费（不再进 rime / 不再给客户端）。
  func intercept(event: NSEvent, last: NSEvent.ModifierFlags, now: NSEvent.ModifierFlags,
                 controller: SquirrelInputController) -> Bool {
    guard Self.voiceEnabled else { return false }
    self.controller = controller
    switch event.type {
    case .flagsChanged:
      return interceptFlags(event, last: last, now: now)
    case .keyDown:
      return interceptKey(event, now: now)
    default:
      return false
    }
  }

  private func interceptFlags(_ event: NSEvent, last: NSEvent.ModifierFlags,
                              now: NSEvent.ModifierFlags) -> Bool {
    let changes = last.symmetricDifference(now)
    // 录音中出现其它修饰键 → 组合键用途（如 ⌘C），取消录音并放行该事件
    if isCapturing, changes.contains(.shift) || changes.contains(.control) || changes.contains(.option) {
      cancelCapture(reason: "已取消录音（检测到组合键）")
      return false
    }
    let soleCommandNow = now.subtracting([.command, .capsLock]).isEmpty
    let soleCommandLast = last.subtracting([.command, .capsLock]).isEmpty
    // 右⌘ 按下（单修饰键）→ 开始采集
    if event.keyCode == W7KeyCode.rightCommand, !last.contains(.command), now.contains(.command),
       soleCommandNow, soleCommandLast {
      startCapture()
      return true
    }
    // ⌘ 释放（含右⌘）→ 结束采集并上屏（仅当由本控制器开启的录音）
    if isCapturing, last.contains(.command), !now.contains(.command) {
      stopAndProcess()
      return true
    }
    return false
  }

  private func interceptKey(_ event: NSEvent, now: NSEvent.ModifierFlags) -> Bool {
    // 录音中 Esc → 取消（丢弃音频，不 commit）
    if isCapturing, event.keyCode == W7KeyCode.escape {
      cancelCapture(reason: "已取消录音（Esc）")
      return true
    }
    // 兜底组合键开关：⌃⌥M（latch：按一下开始，再按一下结束上屏）
    if event.keyCode == W7KeyCode.mKey,
       now.subtracting(.capsLock) == [NSEvent.ModifierFlags.control, .option] {
      if isCapturing {
        stopAndProcess()
      } else {
        startCapture()
      }
      return true
    }
    return false
  }

  private func startCapture() {
    guard !isCapturing else { return }
    do {
      try capture.start()
      isCapturing = true
      controller?.w7ShowRecordingHint()
    } catch {
      controller?.w7ShowVoiceStatus("无法启动麦克风采集（检查麦克风权限）：\(error.localizedDescription)")
    }
  }

  private func stopAndProcess() {
    guard isCapturing else { return }
    isCapturing = false
    let pcm = capture.stop()  // 环形缓冲导出（内存），随后即弃
    controller?.w7ShowVoiceStatus("识别中…")
    daemon.transcribe(pcm) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        if let err = result.error {
          self.controller?.w7ShowVoiceStatus(err)
        } else if result.lowConfidence || result.text.isEmpty {
          // 低置信不瞎猜：不 commit，提示重说
          self.controller?.w7ShowVoiceStatus("没听清，请重说")
        } else {
          self.controller?.w7CommitVoiceText(result.text)
        }
      }
    }
  }

  private func cancelCapture(reason: String) {
    guard isCapturing else { return }
    isCapturing = false
    _ = capture.stop()  // 丢弃，不送识别
    controller?.w7ShowVoiceStatus(reason)
  }
}
