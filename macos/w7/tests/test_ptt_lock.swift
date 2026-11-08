/*
 * test_ptt_lock.swift — W28 PTT 锁定态状态机伪时钟单测（零 sleep）
 *
 * 被测对象：macos/w7/src/W7PttLockMachine.swift（纯 Foundation，与本文件同编译单元）。
 * 硬约束（W27-fix 前车之鉴）：阈值/时长测试一律伪时钟（W7PttLockMachine.clock 注入），
 * 禁止 Thread.sleep 真实等待——本文件全量用例均推进注入时间，不含任何真实等待。
 *
 * 运行：bash build/w7-test-ptt-lock.sh（swiftc 独立编译，产物 build/w7/tests/test_ptt_lock，
 * 日志 build/logs/w7-test-ptt-lock.log）。
 *
 * 用例覆盖（对应 macos/W28-REPORT.md 规格①–④）：
 *   9s 松开→停止 / 10.1s→锁定且松开不停 / 锁定中 0.2s 轻点→停止 /
 *   锁定中 5s 松开→停止 / 锁定中 12s→维持锁定后再轻点→停止 / Esc 取消
 *   + 边界与防误停（恰好 10s、9.999s、lock 只触发一次、松手即 10.1s 无 tick、
 *     组合键取消、⌃⌥M 停止、latch 永不锁定）。
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

func makeMachine(_ clock: FakeClock) -> W7PttLockMachine {
  let m = W7PttLockMachine()
  m.clock = { clock.now }
  return m
}

@main
struct TestPttLock {
  static func main() {
    runAllTests()
    print("== W28 PTT 锁定态状态机单测（伪时钟，零 sleep）==")
    print("== 结果：\(failed == 0 ? "ALL PASS" : "FAILED") — \(passed)/\(passed + failed) ==")
    exit(failed == 0 ? 0 : 1)
  }
}

func runAllTests() {

// MARK: - 规格①：按住 <10s 松开 → 停止上屏（现行为不变）

do {
  let clock = FakeClock()
  let m = makeMachine(clock)
  expectEq(m.pressBegan(), .beginRecording, "① 9s：按下开始录音（聆听态）")
  clock.advance(9.0)
  expectEq(m.tick(), .none, "① 9s：未跨阈值，不锁定")
  expectEq(m.phase, .recording, "① 9s：仍在录音")
  expectEq(m.pressEnded(), .stopAndProcess, "① 9s 松开→停止上屏")
  expectEq(m.phase, .idle, "① 9s 松开后回空闲")
}

// MARK: - 规格②：按住 ≥10s → 锁定，松手不停

do {
  let clock = FakeClock()
  let m = makeMachine(clock)
  expectEq(m.pressBegan(), .beginRecording, "② 10.1s：按下开始录音")
  clock.advance(10.1)
  expectEq(m.tick(), .lock, "② 10.1s 跨过阈值→锁定（触发一次锁定事件）")
  expectEq(m.phase, .locked, "② 10.1s：进入 locked 态")
  expectEq(m.tick(), .none, "② 锁定事件只触发一次（重复 tick 无动作）")
  clock.advance(0.1)
  expectEq(m.pressEnded(), .none, "② 锁定后松开→不停")
  expectEq(m.phase, .locked, "② 松开后仍锁定（免手持）")
}

// MARK: - 规格③a：锁定中 0.2s 轻点 → 停止上屏

do {
  let clock = FakeClock()
  let m = makeMachine(clock)
  _ = m.pressBegan()
  clock.advance(10.1)
  _ = m.tick()
  expectEq(m.phase, .locked, "③a 前置：已锁定")
  clock.advance(0.1)  // 松开锁定成因那次长按
  _ = m.pressEnded()
  expectEq(m.pressBegan(), .none, "③a 锁定中再按右⌘（停止手势）")
  clock.advance(0.2)
  expectEq(m.pressEnded(), .stopAndProcess, "③a 锁定中 0.2s 轻点→停止上屏")
  expectEq(m.phase, .idle, "③a 轻点停止后回空闲")
}

// MARK: - 规格③b：锁定中按住 5s 松开 → 停止上屏（<10s）

do {
  let clock = FakeClock()
  let m = makeMachine(clock)
  _ = m.pressBegan()
  clock.advance(10.1)
  _ = m.tick()
  clock.advance(2.0)
  _ = m.pressEnded()  // 锁定成因长按的松手：不停
  expectEq(m.phase, .locked, "③b 前置：松手后仍锁定")
  expectEq(m.pressBegan(), .none, "③b 锁定中再按右⌘")
  clock.advance(5.0)
  expectEq(m.tick(), .none, "③b 5s < 10s 不触发维持锁定")
  expectEq(m.pressEnded(), .stopAndProcess, "③b 锁定中 5s 松开→停止上屏")
  expectEq(m.phase, .idle, "③b 停止后回空闲")
}

// MARK: - 规格③c：锁定中按住 12s → 维持锁定，再轻点 → 停止

do {
  let clock = FakeClock()
  let m = makeMachine(clock)
  _ = m.pressBegan()
  clock.advance(10.1)
  _ = m.tick()
  clock.advance(0.5)
  _ = m.pressEnded()
  expectEq(m.phase, .locked, "③c 前置：已锁定且已松手")
  expectEq(m.pressBegan(), .none, "③c 锁定中再按右⌘（停止手势）")
  clock.advance(12.0)
  expectEq(m.tick(), .relock, "③c 按住 12s≥10s→维持锁定（可再触发锁定提示）")
  expectEq(m.phase, .locked, "③c 维持锁定（不误停）")
  expectEq(m.tick(), .none, "③c relock 也只触发一次")
  clock.advance(0.1)
  expectEq(m.pressEnded(), .none, "③c 维持锁定后松开→不停")
  expectEq(m.phase, .locked, "③c 仍锁定")
  // 再轻点 → 停止
  expectEq(m.pressBegan(), .none, "③c 再轻点按下")
  clock.advance(0.2)
  expectEq(m.pressEnded(), .stopAndProcess, "③c 维持锁定后再轻点→停止上屏")
  expectEq(m.phase, .idle, "③c 最终回空闲")
}

// MARK: - 规格④：Esc 任意态取消（录音 + 锁定）

do {
  let clock = FakeClock()
  let m = makeMachine(clock)
  expectEq(m.escape(), .none, "④ 空闲 Esc→无动作（不拦截）")
  _ = m.pressBegan()
  clock.advance(3.0)
  expectEq(m.escape(), .cancel(.escape), "④ 录音中 Esc→取消")
  expectEq(m.phase, .idle, "④ 录音中 Esc 后回空闲")
  // 锁定态 Esc
  _ = m.pressBegan()
  clock.advance(10.1)
  _ = m.tick()
  clock.advance(1.0)
  _ = m.pressEnded()
  expectEq(m.phase, .locked, "④ 前置：已锁定")
  expectEq(m.escape(), .cancel(.escape), "④ 锁定中 Esc→取消（含锁定态）")
  expectEq(m.phase, .idle, "④ 锁定中 Esc 后回空闲")
}

// MARK: - 边界与防误停

do {
  // 恰好 10.0s：>= 阈值即锁定
  let clock = FakeClock()
  let m = makeMachine(clock)
  _ = m.pressBegan()
  clock.advance(W7PttLockMachine.lockThresholdSeconds)
  expectEq(m.tick(), .lock, "边界：恰好 10.0s→锁定（≥ 阈值）")
  clock.advance(0.1)
  expectEq(m.pressEnded(), .none, "边界：恰好 10s 锁定后松开不停")
}

do {
  // 9.999s：< 阈值不停误锁
  let clock = FakeClock()
  let m = makeMachine(clock)
  _ = m.pressBegan()
  clock.advance(9.999)
  expectEq(m.tick(), .none, "边界：9.999s 不锁定")
  expectEq(m.pressEnded(), .stopAndProcess, "边界：9.999s 松开→停止（现行为不变）")
}

do {
  // tick 未赶上（如定时器延迟）：松手时刻 ≥10s 也算锁定，松手不停
  let clock = FakeClock()
  let m = makeMachine(clock)
  _ = m.pressBegan()
  clock.advance(10.1)
  expectEq(m.pressEnded(), .lock, "边界：无 tick 直接 10.1s 松开→补触发锁定")
  expectEq(m.phase, .locked, "边界：补锁定后进入 locked（松手不停）")
}

do {
  // 阈值常量命名且为 10.0
  expectEq(W7PttLockMachine.lockThresholdSeconds, 10.0, "常量：lockThresholdSeconds == 10.0")
}

do {
  // 组合键取消（锁定态对称）
  let clock = FakeClock()
  let m = makeMachine(clock)
  _ = m.pressBegan()
  clock.advance(10.1)
  _ = m.tick()
  clock.advance(0.1)
  _ = m.pressEnded()
  expectEq(m.comboCancel(), .cancel(.comboKey), "组合键：锁定中出现其它修饰键→取消")
  expectEq(m.phase, .idle, "组合键：取消后回空闲")
  let m2 = makeMachine(clock)
  _ = m2.pressBegan()
  clock.advance(1.0)
  expectEq(m2.comboCancel(), .cancel(.comboKey), "组合键：录音中出现其它修饰键→取消（现行为）")
}

do {
  // ⌃⌥M 显式停止（锁定中）
  let clock = FakeClock()
  let m = makeMachine(clock)
  _ = m.pressBegan()
  clock.advance(10.1)
  _ = m.tick()
  clock.advance(0.1)
  _ = m.pressEnded()
  expectEq(m.stopRequest(), .stopAndProcess, "⌃⌥M：锁定中显式停止→停止上屏")
  expectEq(m.phase, .idle, "⌃⌥M：停止后回空闲")
}

do {
  // latch（⌃⌥M 开始）永不锁定：本就免手持
  let clock = FakeClock()
  let m = makeMachine(clock)
  expectEq(m.beginLatch(), .beginRecording, "latch：⌃⌥M 开始录音")
  clock.advance(30.0)
  expectEq(m.tick(), .none, "latch：30s 无按住→永不锁定")
  expectEq(m.phase, .recording, "latch：仍在录音（未误锁）")
  expectEq(m.pressEnded(), .stopAndProcess, "latch：⌘ 释放→停止上屏（现行为不变）")
}

do {
  // secondsToThreshold（定时器排程依据）
  let clock = FakeClock()
  let m = makeMachine(clock)
  expect(m.secondsToThreshold() == nil, "排程：空闲无阈值")
  _ = m.pressBegan()
  if let remain = m.secondsToThreshold() {
    expect(abs(remain - 10.0) < 0.001, "排程：按下后剩余 ≈ 10s")
  } else {
    expect(false, "排程：按下后剩余 ≈ 10s")
  }
  clock.advance(4.0)
  if let remain = m.secondsToThreshold() {
    expect(abs(remain - 6.0) < 0.001, "排程：4s 后剩余 ≈ 6s")
  } else {
    expect(false, "排程：4s 后剩余 ≈ 6s")
  }
  clock.advance(6.0)
  _ = m.tick()
  expect(m.secondsToThreshold() == nil, "排程：锁定后不再排阈值检查")
}

}  // runAllTests
