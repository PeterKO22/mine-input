import AppKit
import CryptoKit
import Foundation
import Vision

/// W12 OCR —— ScreenCaptureKit 快照帧（或任意 CGImage 源）→ Vision OCR → **摘要**。
///
/// 隐私红线：OCR 全文只在内存参与摘要计算，随即丢弃；摘要串只含
/// `sha256:<16hex> len:<n> lines:<m>`（W12Digest），**不落原图、不落全文**。
public enum W12OCR {
    public struct Result {
        /// OCR 全文（仅内存，调用方不得落库/落盘；仅用于摘要与即时上下文）。
        public let text: String
        /// 摘要串（可入库：ocr_digest 列）。
        public let digestSummary: String
        public let lines: Int
        public let elapsedMs: Double
    }

    /// Vision 文字识别（accurate + 中文简体/英文，语言纠错开）。
    public static func recognize(cgImage: CGImage) throws -> Result {
        let t0 = Date()
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        return Result(
            text: text,
            digestSummary: W12Digest.summary(text, lines: lines.count),
            lines: lines.count,
            elapsedMs: Date().timeIntervalSince(t0) * 1000)
    }
}
