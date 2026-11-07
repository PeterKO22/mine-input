// W26 语音权限修复验收探针（音频注入 → 真机 IME 进程 → daemon 管线 → w7CommitVoiceText 入口）
//
// 背景（W26 根因）：装机 App 的 Info.plist 缺 NSMicrophoneUsageDescription 时，macOS
// 静默拒绝麦克风采集（tccd 零记录），PTT 永远拿到静音。本探针在无法真人出声的环境里
// 以「采集同款形态」的 PCM 注入真机 IME 进程（Squirrel-dev.app），验证整条链到
// w7CommitVoiceText 入口为止，并顺带验证 W26 空音频诊断分支（全零/极短 → 查权限提示）。
//
// 机制（与 macos/w7/src/W7PttController.swift 的 W26Probe 对应）：
//   token 文件 ~/Library/Rime-mine-dev/w7-probe.enabled（测试窗口内创建，结束删除）
//   请求文件 ~/Library/Rime-mine-dev/w7-probe-req.json
//   触发     分布式通知 W7ProbeInjectNotification.dev（deliverImmediately）
//   证据     ~/Library/Rime-mine-dev/w7-probe.log（JSON lines，按 nonce 关联）
//
// 编译：swiftc -O macos/w26/w26_probe.swift -o macos/w26/w26-probe -framework Carbon
// 用法：macos/w26/w26-probe run <s1.wav 路径> [--no-mic]
//       macos/w26/w26-probe select-ims        （切到 dev 输入源，stdout 打印原输入源 id）
//       macos/w26/w26-probe restore-ims <id>  （还原输入源）
import Foundation
import Carbon

let probeDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Rime-mine-dev")
let tokenPath = (probeDir as NSString).appendingPathComponent("w7-probe.enabled")
let requestPath = (probeDir as NSString).appendingPathComponent("w7-probe-req.json")
let logPath = (probeDir as NSString).appendingPathComponent("w7-probe.log")

// W2-REPORT §5 实测值（与 voice/mic/replay_test.py EXPECTED 一致）
let expectedS1 = "今天天气不错，我们下午去公园散步吧。"
let emptyAudioMsg = "未收到声音，请检查麦克风权限"

var passCount = 0
var failCount = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
  if ok { passCount += 1 } else { failCount += 1 }
  print("  [\(ok ? "PASS" : "FAIL")] \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
}

// ---------- 工具 ----------

func jsonLine(_ obj: [String: Any]) {
  if let d = try? JSONSerialization.data(withJSONObject: obj),
     let s = String(data: d, encoding: .utf8) {
    print("    \(s)")
  }
}

func writeRequest(_ obj: [String: Any]) throws {
  try FileManager.default.createDirectory(atPath: probeDir, withIntermediateDirectories: true)
  let d = try JSONSerialization.data(withJSONObject: obj)
  try d.write(to: URL(fileURLWithPath: requestPath))
}

func postTrigger() {
  DistributedNotificationCenter.default()
    .postNotificationName(.init("W7ProbeInjectNotification.dev"), object: nil,
                          userInfo: nil, deliverImmediately: true)
}

/// 读 w7-probe.log 中本 nonce 的证据行。
func readEvents(_ nonce: String) -> [[String: Any]] {
  guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
  return text.split(separator: "\n").compactMap { line in
    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          obj["nonce"] as? String == nonce else { return nil }
    return obj
  }
}

/// 等待终态事件。terminalEvents 之一到达即返回；超时返回已收集事件。
func waitEvents(_ nonce: String, terminal terminalEvents: Set<String>,
                timeout: TimeInterval) -> [[String: Any]] {
  let deadline = Date().addingTimeInterval(timeout)
  var events: [[String: Any]] = []
  var sawReceived = false
  while Date() < deadline {
    events = readEvents(nonce)
    if !sawReceived, events.contains(where: { $0["event"] as? String == "received" }) {
      sawReceived = true
      print("    (IME 已收到触发)")
    }
    if events.contains(where: { terminalEvents.contains($0["event"] as? String ?? "") }) {
      return events
    }
    Thread.sleep(forTimeInterval: 0.2)
  }
  return events
}

/// 简易 WAV 解析：返回 data chunk 的 PCM16 bytes（探针音频不落盘，仅内存）。
func readWavPCM16(_ path: String) -> Data? {
  guard let data = FileManager.default.contents(atPath: path) else { return nil }
  guard data.count > 12, String(data: data.prefix(4), encoding: .ascii) == "RIFF",
        String(data: data[8..<12], encoding: .ascii) == "WAVE" else { return nil }
  var off = 12
  while off + 8 <= data.count {
    let id = String(data: data[off..<off + 4], encoding: .ascii) ?? ""
    let size = Int(data[off + 4]) | Int(data[off + 5]) << 8 | Int(data[off + 6]) << 16 | Int(data[off + 7]) << 24
    if id == "data" {
      let start = off + 8
      let end = min(start + size, data.count)
      return data.subdata(in: start..<end)
    }
    off += 8 + size + (size % 2)
  }
  return nil
}

/// 极短杂音（0.1s@16k，确定性 LCG，与 replay_test 的 0.3s 噪音案例同族但更短）。
func shortNoisePCM16() -> Data {
  var x: UInt64 = 7
  var out = Data(capacity: 1600 * 2)
  for _ in 0..<1600 {
    x = (x &* 1103515245 &+ 12345) & 0x7fff_ffff
    var le = Int16(Int(x % 801) - 400).littleEndian
    withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
  }
  return out
}

func zerosPCM16() -> Data { Data(count: 16000 * 2) }  // 1s 全零

// ---------- 输入源切换（会话准备；尽力而为） ----------

func tisProp(_ src: TISInputSource, _ key: CFString) -> String {
  guard let raw = TISGetInputSourceProperty(src, key) else { return "" }
  return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func selectIMS(_ id: String) -> Bool {
  guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
    return false
  }
  for src in list where tisProp(src, kTISPropertyInputSourceID) == id {
    return TISSelectInputSource(src) == noErr
  }
  return false
}

// ---------- 案例 ----------

func runCases(s1Path: String, withMic: Bool) {
  // 案例 1：注入 s1.wav（采集同款 16k mono PCM16）→ 期望命中转写 → 到达 w7CommitVoiceText 入口
  print("-- 案例 1：注入 s1.wav → 期望到达 w7CommitVoiceText 入口 --")
  if let pcm = readWavPCM16(s1Path) {
    let nonce = "w26-\(Int(Date().timeIntervalSince1970 * 1000))-s1"
    try? writeRequest(["nonce": nonce, "action": "inject",
                       "pcm16_b64": pcm.base64EncodedString()])
    postTrigger()
    // 首次触发会同步加载 daemon 模型（SenseVoice int8 + 标点 + 热词），放宽超时
    let events = waitEvents(nonce, terminal: ["commit", "status", "error"], timeout: 120)
    for e in events { jsonLine(e) }
    let hit = events.first(where: { $0["event"] as? String == "commit" })
    let text = hit?["text"] as? String ?? ""
    check("s1 注入 → w7CommitVoiceText 入口（commit 事件）", hit != nil,
          hit != nil ? "controller=\(hit?["controller"] ?? false)" : "未到 commit（见上证据行）")
    check("s1 转写逐字命中 W2 期望", text == expectedS1, "text=\(text)")
  } else {
    check("s1.wav 读取", false, s1Path)
  }

  // 案例 2：1s 全零 → W26 空音频诊断应给「查权限」提示（不再误导成「没听清」）
  print("-- 案例 2：注入 1s 全零 PCM → 期望空音频诊断提示 --")
  let nonceZ = "w26-\(Int(Date().timeIntervalSince1970 * 1000))-zeros"
  try? writeRequest(["nonce": nonceZ, "action": "inject",
                     "pcm16_b64": zerosPCM16().base64EncodedString()])
  postTrigger()
  let evZ = waitEvents(nonceZ, terminal: ["status", "commit", "error"], timeout: 30)
  for e in evZ { jsonLine(e) }
  let stZ = evZ.first(where: { $0["event"] as? String == "status" })
  check("全零 PCM → 「未收到声音，请检查麦克风权限」",
        stZ?["text"] as? String == emptyAudioMsg, "text=\(stZ?["text"] ?? "—")")

  // 案例 3：0.1s 极短杂音 → 同样归空音频诊断（区分「真没听清」）
  print("-- 案例 3：注入 0.1s 极短杂音 → 期望同为空音频诊断 --")
  let nonceS = "w26-\(Int(Date().timeIntervalSince1970 * 1000))-short"
  try? writeRequest(["nonce": nonceS, "action": "inject",
                     "pcm16_b64": shortNoisePCM16().base64EncodedString()])
  postTrigger()
  let evS = waitEvents(nonceS, terminal: ["status", "commit", "error"], timeout: 30)
  for e in evS { jsonLine(e) }
  let stS = evS.first(where: { $0["event"] as? String == "status" })
  check("极短 PCM → 「未收到声音，请检查麦克风权限」",
        stS?["text"] as? String == emptyAudioMsg, "text=\(stS?["text"] ?? "—")")

  if withMic {
    // 案例 4：真采集 1.2s（AVAudioEngine）→ 回报帧数/峰值/RMS。
    // 首次运行会触发系统麦克风授权弹窗（NSMicrophoneUsageDescription 生效的实证）；
    // 弹窗未点掉前 engine.start 阻塞在授权流程上，故此处放宽等待并提示用户。
    print("-- 案例 4：真采集 1.2s（首次运行会弹系统麦克风授权框；若弹窗在屏幕上请点「允许」） --")
    let nonceM = "w26-\(Int(Date().timeIntervalSince1970 * 1000))-mic"
    try? writeRequest(["nonce": nonceM, "action": "mic", "duration_ms": 1200.0])
    postTrigger()
    let evM = waitEvents(nonceM, terminal: ["mic", "error"], timeout: 120)
    for e in evM { jsonLine(e) }
    let mic = evM.first(where: { $0["event"] as? String == "mic" })
    let frames = mic?["frames"] as? Int ?? 0
    check("采集链路可用（AVAudioEngine 跑通）", mic != nil && frames > 0,
          "frames=\(frames) peak=\(mic?["peak"] ?? "—") rms=\(mic?["rms"] ?? "—") silent=\(mic?["silent"] ?? "—")")
    if mic == nil {
      print("    注：120s 内未见采集结果——多半是系统麦克风授权弹窗还没点「允许」。")
      print("    点掉弹窗（或 系统设置→隐私与安全性→麦克风 允许「提炼输入法」）后重跑本探针。")
    } else if mic?["silent"] as? Bool == true {
      print("    注：采集为全零——未获麦克风授权（弹窗待用户点「允许」）或环境完全无声。")
      print("    授权后重跑本探针，或真人按右⌘说话做最终上屏实测。")
    }

    // 案例 5：真实麦克风样本端到端——外放 s1.wav → 采集 → 转写 → w7CommitVoiceText 入口
    if mic != nil {
      print("-- 案例 5：外放 s1.wav + 真实采集 → 期望 commit（真实麦克风样本端到端） --")
      let nonceMT = "w26-\(Int(Date().timeIntervalSince1970 * 1000))-micasr"
      try? writeRequest(["nonce": nonceMT, "action": "mic_transcribe", "duration_ms": 6500.0])
      postTrigger()
      // 等 IME 确认收到（采集已启动）再外放——否则外放错过采集窗口
      let deadline = Date().addingTimeInterval(30)
      while Date() < deadline,
            !readEvents(nonceMT).contains(where: { $0["event"] as? String == "received" }) {
        Thread.sleep(forTimeInterval: 0.2)
      }
      Thread.sleep(forTimeInterval: 0.3)
      let afplay = Process()
      afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
      afplay.arguments = [s1Path]
      try? afplay.run()  // 外放样音（音量过小则转写拿不到文本，届时以案例 1 为准）
      let evMT = waitEvents(nonceMT, terminal: ["commit", "status", "error"], timeout: 120)
      for e in evMT { jsonLine(e) }
      let hitMT = evMT.first(where: { $0["event"] as? String == "commit" })
      let textMT = hitMT?["text"] as? String ?? ""
      check("真实麦克风样本 → 到达 w7CommitVoiceText 入口（commit 事件）", hitMT != nil,
            hitMT != nil ? "controller=\(hitMT?["controller"] ?? false)" : "未到 commit（见上证据行）")
      check("真实样本转写逐字命中 W2 期望", textMT == expectedS1, "text=\(textMT)")
    } else {
      print("-- 案例 5：跳过（采集未跑通，先解决案例 4 的麦克风授权） --")
    }
  }
}

// ---------- main ----------

let args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else {
  print("用法：w26-probe run <s1.wav> [--no-mic] | select-ims | restore-ims <id>")
  exit(64)
}

switch sub {
case "select-ims":
  let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
  let prevID = current.map { tisProp($0, kTISPropertyInputSourceID) } ?? ""
  print(prevID)  // stdout 仅此一行（供包装脚本捕获）
  let ok = selectIMS("im.rime.inputmethod.Squirrel.dev.Hans") || selectIMS("im.rime.inputmethod.Squirrel.dev")
  FileHandle.standardError.write(Data("select-ims: \(ok ? "switched to dev" : "FAILED（dev 输入源未注册/未启用？）")\n".utf8))
  exit(ok ? 0 : 3)

case "restore-ims":
  let id = args.dropFirst().first ?? ""
  if id.isEmpty {
    FileHandle.standardError.write(Data("restore-ims: 空 id，跳过\n".utf8))
    exit(0)
  }
  let ok = selectIMS(id)
  FileHandle.standardError.write(Data("restore-ims: \(id) \(ok ? "ok" : "FAILED")\n".utf8))
  exit(ok ? 0 : 3)

case "run":
  var s1Path = ""
  var withMic = true
  for a in args.dropFirst() {
    if a == "--no-mic" { withMic = false } else { s1Path = a }
  }
  guard !s1Path.isEmpty else {
    print("run: 缺 s1.wav 路径"); exit(64)
  }
  // arm：创建 token（W26Probe 安全门；结束必删）
  try FileManager.default.createDirectory(atPath: probeDir, withIntermediateDirectories: true)
  try "w26-probe \(Date().timeIntervalSince1970)".write(toFile: tokenPath, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(atPath: tokenPath) }
  runCases(s1Path: s1Path, withMic: withMic)
  print("\n== W26 注入探针汇总: PASS \(passCount) / FAIL \(failCount) ==")
  print("（本探针验证到 w7CommitVoiceText 入口为止；真人右⌘→说话→上屏未实测，见 macos/W26-REPORT.md）")
  exit(failCount == 0 ? 0 : 1)

default:
  print("未知子命令：\(sub)")
  exit(64)
}
