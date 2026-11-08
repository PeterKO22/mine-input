/*
 * W7PttLockMachine.swift — W28 PTT 锁定态状态机（纯 Foundation，零 Squirrel 依赖）
 *
 * 需求（用户原话）：「按住右⌘ 10秒以上，就锁住（界面要有变化，提示可以松开按键了），
 * 等再次按一次，且少于10秒才停止。防止长时间说话要一直按着」。
 *
 * 已定规格（歧义处按对称性定死）：
 *   ① 按住 <10s 松开 → 停止上屏（现行为不变）
 *   ② 按住 ≥10s → 锁住：面板立刻变锁定态（文案「可以松开按键了」），后续松手不停
 *   ③ 锁定中再按右⌘：本次按下 <10s 松开 → 停止上屏；又按住 ≥10s → 维持锁定
 *      （可再触发锁定提示），随后仍需一次 <10s 轻点才停止
 *   ④ Esc 随时取消（录音 + 锁定）
 *
 * 可测性（W27-fix 同款硬约束）：阈值/时长一律走注入伪时钟（clock: () -> TimeInterval，
 * 默认 Date() 生产不变），单测零 Thread.sleep。
 *
 * 状态图见 macos/W28-REPORT.md。
 */
import Foundation

// MARK: - 状态与事件

/// PTT 相位：空闲 / 录音中（聆听态）/ 已锁定（免手持）。
enum W7PttPhase: Equatable {
  case idle
  case recording
  case locked
}

enum W7PttCancelReason: Equatable {
  case escape    // Esc
  case comboKey  // 录音/锁定中出现其它修饰键（组合键用途，取消放行）
}

/// 状态机输出动作（W7PttController.handle(_:) 把它翻译成副作用）。
enum W7PttAction: Equatable {
  case none
  case beginRecording            // 开始录音（面板聆听态 🎙）
  case lock                      // 首次锁定（触发一次：面板锁定态 🔒「可以松开按键了」）
  case relock                    // 维持锁定（可再触发锁定提示）
  case stopAndProcess            // 停止并走既有转写上屏链
  case cancel(W7PttCancelReason) // 丢弃音频
}

// MARK: - 状态机

final class W7PttLockMachine {
  /// 锁定阈值（命名常量）：按住右⌘ 持续 ≥ 该秒数 → 进入 locked。
  static let lockThresholdSeconds: TimeInterval = 10.0

  /// W27-fix 同款时钟注入（默认 `Date()` 墙钟，生产行为不变）：单测传伪时间，
  /// 消除「用真实 sleep 模拟按住时长」的时序竞态。
  var clock: () -> TimeInterval = { Date().timeIntervalSince1970 }

  private(set) var phase: W7PttPhase = .idle
  /// 当前是否有物理按住（右⌘ 按下未松）。⌃⌥M latch 开始的录音为 false——
  /// latch 本就免手持，不计按住时长、永不触发锁定。
  private(set) var pressActive = false
  /// 本次按下的起点（伪时钟时间轴）。
  private(set) var pressBeganAt: TimeInterval = 0
  /// 本次按下发生在 locked 态 =「停止手势」（<10s 松开→停止；≥10s→维持锁定）。
  private var pressIsStopGesture = false
  /// 本次按下已触发过 lock/relock 提示（一次按住只触发一次）。
  private var thresholdNotified = false

  // MARK: 事件（时间一律取自 clock()）

  /// 右⌘ 按下。
  ///   idle → recording（①/② 的起点）；locked → 记为停止手势（③）。
  func pressBegan() -> W7PttAction {
    let now = clock()
    switch phase {
    case .idle:
      phase = .recording
      pressActive = true
      pressBeganAt = now
      pressIsStopGesture = false
      thresholdNotified = false
      return .beginRecording
    case .recording:
      return .none  // 按住期间重复 flagsChanged，忽略
    case .locked:
      // ③ 锁定中再按右⌘：开始停止手势（本次 <10s 松开→停止；≥10s→维持锁定）
      pressActive = true
      pressBeganAt = now
      pressIsStopGesture = true
      thresholdNotified = false
      return .none
    }
  }

  /// ⌃⌥M latch 开始（兜底组合键）：不计按住时长（pressActive=false），
  /// 不触发锁定——latch 已免手持，锁定语义只属于「按住右⌘」场景。
  func beginLatch() -> W7PttAction {
    guard phase == .idle else { return .none }
    phase = .recording
    pressActive = false
    pressIsStopGesture = false
    thresholdNotified = false
    return .beginRecording
  }

  /// ⌘ 释放。
  func pressEnded() -> W7PttAction {
    let now = clock()
    switch phase {
    case .idle:
      return .none
    case .recording:
      guard pressActive else {
        // latch 录音中的 ⌘ 释放：现行为不变（停止上屏）
        return .stopAndProcess
      }
      pressActive = false
      if now - pressBeganAt >= Self.lockThresholdSeconds {
        // tick 未赶上的边界：按对称性定死——按住 ≥10s 即算锁定，松手不停（②）
        phase = .locked
        thresholdNotified = true
        return .lock
      }
      phase = .idle
      return .stopAndProcess  // ①
    case .locked:
      guard pressActive else { return .none }
      pressActive = false
      guard pressIsStopGesture else {
        return .none  // ② 锁定成因那次长按的松手：不停
      }
      // ③ 停止手势松开
      if now - pressBeganAt >= Self.lockThresholdSeconds {
        if !thresholdNotified {
          thresholdNotified = true
          return .relock  // 又按住 ≥10s → 维持锁定（补触发一次锁定提示）
        }
        return .none      // 维持锁定（提示已触发过）
      }
      phase = .idle
      return .stopAndProcess  // ③ 本次 <10s → 停止上屏
    }
  }

  /// 阈值检查（生产由定时器驱动；单测伪时钟直调，零 sleep）。
  /// 录音按住跨过阈值 → locked（lock 只触发一次）；
  /// 锁定中停止手势按住跨过阈值 → 维持锁定（relock 只触发一次）。
  func tick() -> W7PttAction {
    guard pressActive, clock() - pressBeganAt >= Self.lockThresholdSeconds else { return .none }
    switch phase {
    case .idle:
      return .none
    case .recording:
      phase = .locked
      thresholdNotified = true
      return .lock  // ② 跨过阈值即锁定（触发一次锁定事件）
    case .locked:
      guard pressIsStopGesture, !thresholdNotified else { return .none }
      thresholdNotified = true
      return .relock  // ③ 又按住 ≥10s → 维持锁定（可再触发锁定提示）
    }
  }

  /// ④ Esc：任意非 idle 态取消（录音 + 锁定），丢弃音频。
  func escape() -> W7PttAction { cancelAll(.escape) }

  /// 录音/锁定中出现其它修饰键（组合键用途）→ 取消放行（沿用 W7 现行为，锁定态对称）。
  func comboCancel() -> W7PttAction { cancelAll(.comboKey) }

  /// ⌃⌥M 显式停止（latch 再按 / 锁定中按 ⌃⌥M）→ 停止上屏。
  func stopRequest() -> W7PttAction {
    guard phase != .idle else { return .none }
    toIdle()
    return .stopAndProcess
  }

  /// 距本次按下跨过锁定阈值还剩多少秒（定时器排程用）。
  /// 无按住 / 已触发过 / 空闲 → nil。
  func secondsToThreshold() -> TimeInterval? {
    guard phase != .idle, pressActive, !thresholdNotified else { return nil }
    return Self.lockThresholdSeconds - (clock() - pressBeganAt)
  }

  /// 强制回空闲（采集启动失败等异常路径）。
  func reset() { toIdle() }

  // MARK: 私有

  private func cancelAll(_ reason: W7PttCancelReason) -> W7PttAction {
    guard phase != .idle else { return .none }
    toIdle()
    return .cancel(reason)
  }

  private func toIdle() {
    phase = .idle
    pressActive = false
    pressIsStopGesture = false
    thresholdNotified = false
  }
}
