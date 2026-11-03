import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// W12 屏幕快照源（任务书 (a)：ScreenCaptureKit 屏幕快照 → Vision OCR）。
///
/// - `.screen`：ScreenCaptureKit 全屏快照（需系统 屏幕录制 TCC 授权；
///   未授权时抛 `W12CaptureError.screenRecordingDenied`，**绝不静默绕过**）；
/// - `.imageFile`：等价「一帧截屏」的文件源——与 `.screen` 走完全相同的
///   OCR→摘要→入库链路（脚本化实测在无 TCC 会话中用它验证链路本身）。
public enum W12CaptureSource {
    case screen
    case imageFile(URL)
}

public enum W12CaptureError: Error, CustomStringConvertible {
    case screenRecordingDenied(String)
    case noDisplay
    case imageLoadFailed(String)
    case captureFailed(String)
    public var description: String {
        switch self {
        case .screenRecordingDenied(let m):
            return "screen recording TCC denied: \(m)"
        case .noDisplay:
            return "no display available for capture"
        case .imageLoadFailed(let m):
            return "image load failed: \(m)"
        case .captureFailed(let m):
            return "capture failed: \(m)"
        }
    }
}

public enum W12ScreenCapture {
    /// 取一帧 CGImage（屏幕快照或文件源）。
    public static func captureCGImage(_ source: W12CaptureSource) async throws -> CGImage {
        switch source {
        case .imageFile(let url):
            return try loadCGImage(url)
        case .screen:
            return try await captureScreenCGImage()
        }
    }

    /// 文件源加载（bmp/png/jpeg 均可，NSBitmapImageRep 解码）。
    public static func loadCGImage(_ url: URL) throws -> CGImage {
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data),
              let img = rep.cgImage else {
            throw W12CaptureError.imageLoadFailed(url.path)
        }
        return img
    }

    /// ScreenCaptureKit 全屏快照：SCShareableContent → 首个显示器 → 一帧位图。
    /// TCC 未授权（本沙盒/远程会话常见）→ 明确抛错，由调用方上报（诚实 blocker，不伪造）。
    public static func captureScreenCGImage() async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            throw W12CaptureError.screenRecordingDenied("\(error)")
        }
        guard let display = content.displays.first else {
            throw W12CaptureError.noDisplay
        }
        if #available(macOS 14.0, *) {
            do {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.showsCursor = false
                config.capturesAudio = false
                return try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
            } catch {
                throw W12CaptureError.captureFailed("\(error)")
            }
        } else {
            throw W12CaptureError.captureFailed(
                "SCScreenshotManager requires macOS 14+ (deployment 13 fallback not implemented in MVP)")
        }
    }
}
