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

// ------------------------------------------------------------ W32 读屏门禁（显式 opt-in）

/// W32 录屏 TCC 授权探针/请求（CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess）。
/// 默认实现走系统 API；单测/探针注入 mock（授权状态可注入），门禁逻辑伪时钟可测。
///
/// 硬规则（W27 弹窗风暴事故根治）：
///   - **采集路径只用 `preflight` 探活**（CGPreflightScreenCaptureAccess 不弹窗、不请求）；
///   - **`requestAccess` 唯一发起点 = ⌥M「读取屏幕内容以增强候选（需授权）」开关打开动作**
///     （一次性授权请求，弹系统 TCC 确认框）；打字/语音路径绝不调用（零权限请求）。
public struct W12ScreenAccess {
    /// 探活：当前进程是否已获录屏授权（不弹窗、不发起请求）。
    public var preflight: () -> Bool
    /// 发起一次性授权请求（弹系统 TCC「想要录制此电脑的屏幕」；仅 ⌥M 开关打开时调用）。
    public var requestAccess: () -> Bool

    public init(preflight: @escaping () -> Bool, requestAccess: @escaping () -> Bool) {
        self.preflight = preflight
        self.requestAccess = requestAccess
    }

    /// 生产实现（CoreGraphics TCC 桥）。
    public static func live() -> W12ScreenAccess {
        W12ScreenAccess(
            preflight: { CGPreflightScreenCaptureAccess() },
            requestAccess: { CGRequestScreenCaptureAccess() })
    }
}

/// W32 读屏门禁纯逻辑（零副作用、零 TCC 调用；单测真值表全覆盖）。
///
/// 语义：屏幕上下文**默认 OFF**——只有 ⌥M 显式开关（持久 `c1_screen`）打开才读屏；
/// 开关开但系统未授权 → **跳过读屏**（绝不自动发起授权请求），⌥M 状态行显示「读屏未授权」。
public enum W12ScreenGate {
    public enum Decision: Equatable {
        /// 允许读屏（开关开 + 已授权）。
        case readScreen
        /// 读屏开关关（默认）→ 跳过读屏。
        case skipSwitchOff
        /// 开关开但未授权 → 跳过读屏（绝不自动请求授权）。
        case skipNotAuthorized
    }

    /// 跳过原因（采集日志/探针逐字断言锚点）。
    public static let skipSwitchOffReason =
        "读屏开关关（默认关；⌥M「读取屏幕内容以增强候选（需授权）」开启才读屏）"
    public static let skipNotAuthorizedReason =
        "读屏未授权（CGPreflightScreenCaptureAccess=false；跳过读屏，绝不自动发起授权请求）"

    /// 门禁判定（`screenAuthorized` 为 @autoclosure：开关关时**不触碰**授权探针——
    /// 默认态零权限交互）。
    public static func decide(
        screenSwitchOn: Bool,
        screenAuthorized: @autoclosure () -> Bool
    ) -> Decision {
        guard screenSwitchOn else { return .skipSwitchOff }
        guard screenAuthorized() else { return .skipNotAuthorized }
        return .readScreen
    }

    /// ⌥M 状态行文案（未授权必含「读屏未授权」）。
    public static func statusText(screenSwitchOn: Bool, screenAuthorized: Bool) -> String {
        guard screenSwitchOn else {
            return "读屏：关（默认；「读取屏幕内容以增强候选（需授权）」开启才读屏）"
        }
        return screenAuthorized
            ? "读屏：开（已授权）"
            : "读屏未授权（系统设置→隐私与安全性→屏幕录制 允许「提炼输入法」；授权后 pkill+open 重启生效）"
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
