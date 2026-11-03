import AVFoundation
import Foundation

/// W12 ASR 客户端 —— 复用 W2 管线（voice/mic/ptt_daemon.py JSON-line 协议，
/// 与 macos/w7/src/W7PttController.swift 的 W7VoiceDaemonClient 同协议）。
///
/// 链路：系统音频环回/麦克风/音频文件 → 16k mono PCM16（内存）→ daemon（Silero VAD →
/// SenseVoice int8 → CT-Transformer 标点 → 热词）→ 转写文本 → **asr_digest 摘要入库**
///（仅摘要/长度；转写全文不落库，W12Digest）。
public struct W12AsrResult {
    public var text: String = ""
    public var lowConfidence: Bool = true
    public var reason: String = ""
    public var elapsedMs: Double = 0
    public var error: String? = nil
}

/// daemon 客户端（阻塞式；调用方自行放后台线程）。音频全程内存传递，不落盘。
public final class W12AsrClient {
    private let pythonPath: String
    private let daemonPath: String
    private let hotwords: String?
    private let queue = DispatchQueue(label: "w12.asr.daemon")
    private var proc: Process?
    private var stdinFH: FileHandle?
    private var stdoutFH: FileHandle?
    private var readBuffer = Data()
    private var nextId = 0

    public init(pythonPath: String? = nil, daemonPath: String? = nil, hotwords: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.pythonPath = pythonPath ?? env["MINE_VOICE_PYTHON"] ?? ""
        self.daemonPath = daemonPath ?? ""
        self.hotwords = hotwords
    }

    public func warmup() throws -> String {
        try queue.sync {
            try ensureRunning()
            return "ok"
        }
    }

    /// pcm16: 16k mono PCM16LE（内存 bytes）。
    public func transcribe(_ pcm16: Data) -> W12AsrResult {
        queue.sync {
            do {
                try ensureRunning()
                nextId += 1
                let myId = nextId
                var req: [String: Any] = [
                    "id": myId, "cmd": "transcribe", "sample_rate": 16000,
                    "pcm16_b64": pcm16.base64EncodedString(),
                ]
                if let hotwords { req["hotwords"] = hotwords }
                try writeRequest(req)
                guard let line = readLineLocked() else {
                    return W12AsrResult(error: "daemon closed stdout")
                }
                return parse(line)
            } catch {
                return W12AsrResult(error: "daemon unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// WAV 文件 → 16k mono PCM16LE（AVAudioFile + AVAudioConverter，内存）。
    public static func loadPCM16_16k(url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw NSError(domain: "w12.asr", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "converter init failed"])
        }
        let frames = AVAudioFrameCount(file.length)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames) else {
            throw NSError(domain: "w12.asr", code: 2)
        }
        try file.read(into: srcBuf)
        let ratio = 16000 / srcFormat.sampleRate
        let cap = AVAudioFrameCount(Double(frames) * ratio) + 32
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: cap) else {
            throw NSError(domain: "w12.asr", code: 3)
        }
        var error: NSError?
        var consumed = false
        conv.convert(to: dstBuf, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return srcBuf
        }
        if let error { throw error }
        let n = Int(dstBuf.frameLength)
        guard let ch = dstBuf.int16ChannelData else {
            throw NSError(domain: "w12.asr", code: 4)
        }
        return Data(bytes: ch[0], count: n * 2)
    }

    // MARK: 私有（内部队列线程）

    private func ensureRunning() throws {
        if let proc, proc.isRunning { return }
        guard !pythonPath.isEmpty, !daemonPath.isEmpty else {
            throw NSError(domain: "w12.asr", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "python/daemon path not configured"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = [daemonPath]
        var env = ProcessInfo.processInfo.environment
        // daemon 位于 <root>/voice/mic/ptt_daemon.py → PYTHONPATH=<root>
        let micDir = (daemonPath as NSString).deletingLastPathComponent
        let voiceDir = (micDir as NSString).deletingLastPathComponent
        let root = (voiceDir as NSString).deletingLastPathComponent
        env["PYTHONPATH"] = root + (env["PYTHONPATH"].map { ":" + $0 } ?? "")
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
        var warm: [String: Any] = ["id": 0, "cmd": "warmup"]
        if let hotwords { warm["hotwords"] = hotwords }
        try writeRequest(warm)
        _ = readLineLocked()
    }

    private func writeRequest(_ req: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: req)
        data.append(UInt8(ascii: "\n"))
        guard let stdinFH else { throw NSError(domain: "w12.asr", code: 6) }
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

    private func parse(_ line: String) -> W12AsrResult {
        var r = W12AsrResult()
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            r.error = "bad response"
            return r
        }
        if let ok = obj["ok"] as? Bool, !ok {
            r.error = (obj["error"] as? String) ?? "transcribe failed"
            return r
        }
        r.text = (obj["text"] as? String) ?? ""
        r.lowConfidence = (obj["low_confidence"] as? Bool) ?? true
        r.reason = (obj["reason"] as? String) ?? ""
        r.elapsedMs = (obj["elapsed_ms"] as? Double) ?? 0
        return r
    }
}
