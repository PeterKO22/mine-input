import CryptoKit
import Foundation

/// W12 摘要工具（隐私红线：**仅摘要/长度，绝不落原文/原图/转写全文**）。
///
/// C1 采集产物（OCR 文本 / ASR 转写）只允许以「摘要 + 长度」形态进交互日志
/// （技术方案 §8.2 的 ocr_digest / asr_digest 列，W9 已预留、默认 NULL）：
///   - 摘要：SHA-256 前 16 hex（内容指纹，用于「是否变化」比对，不可逆推原文）；
///   - 长度：字符数 / 行数（量级信息）。
/// 原始截屏位图、OCR 全文、ASR 全文在摘要计算后即丢弃，任何路径都不落库、不落盘。
public enum W12Digest {
    /// 摘要串格式（存入 ocr_digest / asr_digest 列）：`sha256:<16hex> len:<n> lines:<m>`。
    /// ASR 单行文本可用 lines 缺省。
    public static func summary(_ text: String, lines: Int? = nil) -> String {
        let hex = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
        var s = "sha256:\(hex) len:\(text.count)"
        if let lines { s += " lines:\(lines)" }
        return s
    }

    /// 校验摘要串只含摘要/长度字段（防回归：绝不允许内容混进 digest 列）。
    public static func isSummaryOnly(_ digest: String) -> Bool {
        digest.range(
            of: "^sha256:[0-9a-f]{16} len:[0-9]+( lines:[0-9]+)?$",
            options: .regularExpression) != nil
    }
}
