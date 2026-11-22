/*
 * test_screen_gate.swift — W32 读屏门禁伪时钟单测（零 sleep、零 TCC、授权状态 mock）
 *
 * 被测对象：macos/w12/src/W12ScreenCapture.swift（W12ScreenGate / W12ScreenAccess）+
 * macos/w12/src/W12C1Collector.swift（采集入口门禁）+ W12Privacy 读屏显式开关
 * （ContextCore 源码同编译单元，swiftc 独立编译，见 build/w32-test-screen-gate.sh）。
 *
 * 硬约束（W27 弹窗风暴事故防复发）：
 *   - 时间一律伪时钟注入（collector.clock），禁止 Thread.sleep 真实等待；
 *   - 录屏授权状态注入 mock（W12ScreenAccess），全程零 CGRequest/零 TCC 交互；
 *   - 断言「CGRequestScreenCaptureAccess 一次性授权请求的唯一发起点 = ⌥M 开关打开动作」
 *     ——所有采集路径 requestCalls 恒 0。
 *
 * 用例覆盖：门禁真值表（开关×授权）/ autoclosure 短路（开关关零探活）/
 * ⌥M 状态行文案（未授权必含「读屏未授权」）/ 默认态零权限零采集 / 未授权跳过读屏 /
 * 授权后读屏入库（摘要不落原文）/ 伪时钟防抖集成（窗内合并、出窗恢复）/
 * 开关中途开↔关（默认 OFF 的机制保证）/ requestAccess 唯一发起点 /
 * 文件源（探针等价帧）不涉 TCC 门禁 / 显式开关语义（不显式确认拒绝开启）。
 */
import Foundation
import AppKit
import CoreGraphics

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

/// 用例组隔离：组内 guard 失败 return 只弃本组，不吞后续组的报告。
func runGroup(_ body: () -> Void) { body() }

/// 伪时钟：手动推进，零真实等待。
final class FakeClock {
  var now: TimeInterval = 1000.0
  func advance(_ dt: TimeInterval) { now += dt }
}

/// mock 录屏授权：状态可注入；计数 preflight/request 调用次数（断言零自动请求）。
final class MockScreenAccess {
  var authorized = false
  var preflightCalls = 0
  var requestCalls = 0
  /// requestAccess 返回后置 authorized=true（模拟用户在系统弹窗里同意）。
  var grantOnRequest = true
  func make() -> W12ScreenAccess {
    W12ScreenAccess(
      preflight: { [self] in preflightCalls += 1; return authorized },
      requestAccess: { [self] in
        requestCalls += 1
        if grantOnRequest { authorized = true }
        return authorized
      })
  }
}

/// autoclosure 惰性探针计数（门禁短路验证）。
final class LazyProbe {
  var calls = 0
  func bump() -> Bool { calls += 1; return true }
}

/// 测试夹具：一张「截屏帧」CGImage（同一 OCR→摘要链路的输入源）。
func makeTestCGImage(text: String) throws -> CGImage {
  let img = NSImage(size: NSSize(width: 600, height: 160))
  img.lockFocus()
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: 600, height: 160).fill()
  let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black]
  (text as NSString).draw(at: NSPoint(x: 16, y: 60), withAttributes: attrs)
  img.unlockFocus()
  return NSBitmapImageRep(data: img.tiffRepresentation!)!.cgImage!
}

/// 新建独立测试桥（临时 sqlite，组尾清理）。
func makeBridge() -> (W12EventBridge, String) {
  let db = NSTemporaryDirectory() + "w32-gate-\(UUID().uuidString).db"
  return (W12EventBridge(path: db), db)
}

@main
struct TestScreenGate {
  static func main() {
    runAllTests()
    print("== W32 读屏门禁单测（伪时钟，零 sleep，mock 授权，零 TCC）==")
    print("== 结果：\(failed == 0 ? "ALL PASS" : "FAILED") — \(passed)/\(passed + failed) ==")
    exit(failed == 0 ? 0 : 1)
  }
}

func runAllTests() {

// MARK: - (1) 门禁真值表：开关 × 授权
runGroup {
  expectEq(W12ScreenGate.decide(screenSwitchOn: false, screenAuthorized: false),
           .skipSwitchOff, "真值表：开关关+未授权 → skipSwitchOff（默认态）")
  expectEq(W12ScreenGate.decide(screenSwitchOn: false, screenAuthorized: true),
           .skipSwitchOff, "真值表：开关关+已授权 → 仍 skipSwitchOff（开关才是闸门）")
  expectEq(W12ScreenGate.decide(screenSwitchOn: true, screenAuthorized: false),
           .skipNotAuthorized, "真值表：开关开+未授权 → skipNotAuthorized（跳过读屏）")
  expectEq(W12ScreenGate.decide(screenSwitchOn: true, screenAuthorized: true),
           .readScreen, "真值表：开关开+已授权 → readScreen")

  let lazy = LazyProbe()
  _ = W12ScreenGate.decide(screenSwitchOn: false, screenAuthorized: lazy.bump())
  expectEq(lazy.calls, 0, "autoclosure 短路：开关关时授权探针零调用（默认态零权限交互）")
  _ = W12ScreenGate.decide(screenSwitchOn: true, screenAuthorized: lazy.bump())
  expectEq(lazy.calls, 1, "开关开才探活一次（CGPreflight 级，不弹窗不请求）")
}

// MARK: - (2) ⌥M 状态行文案
runGroup {
  let off = W12ScreenGate.statusText(screenSwitchOn: false, screenAuthorized: false)
  expect(off.contains("读屏：关"), "状态行：开关关 →「读屏：关（默认…）」：\(off)")
  let on = W12ScreenGate.statusText(screenSwitchOn: true, screenAuthorized: true)
  expectEq(on, "读屏：开（已授权）", "状态行：已授权 →「读屏：开（已授权）」")
  let denied = W12ScreenGate.statusText(screenSwitchOn: true, screenAuthorized: false)
  expect(denied.contains("读屏未授权"), "状态行：未授权 → 含「读屏未授权」逐字：\(denied)")
}

// MARK: - (3) W12Privacy 读屏显式开关（持久 meta，默认关）
runGroup {
  let (bridge, db) = makeBridge()
  defer { try? FileManager.default.removeItem(atPath: db) }
  expect(!W12Privacy.isC1ScreenEnabled(store: bridge.store), "读屏显式开关默认关（meta 空）")
  expectEq(W12Privacy.enableC1Screen(store: bridge.store, explicitConfirm: false),
           false, "不显式确认 → 拒绝开启（enableC1Screen explicitConfirm:false）")
  expect(!W12Privacy.isC1ScreenEnabled(store: bridge.store), "拒绝开启后 meta 仍关")
  expectEq(W12Privacy.enableC1Screen(store: bridge.store, explicitConfirm: true),
           true, "显式确认 → 开启")
  expect(W12Privacy.isC1ScreenEnabled(store: bridge.store), "开启后 meta c1_screen=1")
  W12Privacy.disableC1Screen(store: bridge.store)
  expect(!W12Privacy.isC1ScreenEnabled(store: bridge.store), "disableC1Screen → 关（随时可关）")
}

// MARK: - (4) 默认态：打字零权限请求、零采集（W27 弹窗风暴根治实证）
runGroup {
  let (bridge, db) = makeBridge()
  defer { try? FileManager.default.removeItem(atPath: db) }
  let clock = FakeClock()
  let mock = MockScreenAccess()
  let collector = W12C1Collector(bridge: bridge, settings: W12Settings())
  collector.clock = { clock.now }
  collector.screenAccess = mock.make()
  W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)  // 连 C1 都开了

  let out = fire(collector, .keystroke)
  guard case .skipped(let r) = out else {
    return expect(false, "默认态应 skipped（实际 \(out)）")
  }
  expectEq(r, W12ScreenGate.skipSwitchOffReason, "默认态按键 → skipped 逐字 skipSwitchOffReason")
  expectEq(mock.preflightCalls, 0, "默认态：CGPreflight 零调用（连探活都不做）")
  expectEq(mock.requestCalls, 0, "默认态：CGRequest 零调用（打字零权限请求）")
  expectEq(bridge.store.count(), 0, "默认态 → 零采集零入库")
}

// MARK: - (5) 开关开但未授权：跳过读屏（只探活，绝不自动请求）
runGroup {
  let (bridge, db) = makeBridge()
  defer { try? FileManager.default.removeItem(atPath: db) }
  let mock = MockScreenAccess()   // authorized = false
  let collector = W12C1Collector(bridge: bridge, settings: W12Settings())
  collector.screenAccess = mock.make()
  W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
  W12Privacy.enableC1Screen(store: bridge.store, explicitConfirm: true)

  let out = syncCapture(collector, .screen)
  guard case .skipped(let r) = out else {
    return expect(false, "未授权应 skipped（实际 \(out)）")
  }
  expectEq(r, W12ScreenGate.skipNotAuthorizedReason,
           "未授权 → skipped 逐字 skipNotAuthorizedReason（含「读屏未授权」）")
  expectEq(mock.preflightCalls, 1, "未授权：CGPreflight 探活恰好一次")
  expectEq(mock.requestCalls, 0, "未授权：CGRequest 零调用——绝不自动发起授权请求")
  expectEq(bridge.store.count(), 0, "未授权 → 零入库")
  expect(W12ScreenGate.statusText(screenSwitchOn: true, screenAuthorized: false)
           .contains("读屏未授权"), "⌥M 状态行「读屏未授权」与门禁同源")
}

// MARK: - (6) 授权后读屏入库（摘要不落原文；采集路径仍零 request）
runGroup {
  let (bridge, db) = makeBridge()
  defer { try? FileManager.default.removeItem(atPath: db) }
  let clock = FakeClock()
  let mock = MockScreenAccess()
  mock.authorized = true
  let collector = W12C1Collector(bridge: bridge, settings: W12Settings())
  collector.clock = { clock.now }
  collector.screenAccess = mock.make()
  collector.captureImageOverride = { _ in try makeTestCGImage(text: "W32 SCREEN MARKER ALPHA") }
  W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
  W12Privacy.enableC1Screen(store: bridge.store, explicitConfirm: true)

  let out = syncCapture(collector, .screen)
  guard case .ingested(let id, let digest) = out else {
    return expect(false, "已授权应 ingested（实际 \(out)）")
  }
  expect(id > 0, "已授权 → 读屏入库 event_id=\(id)")
  expect(W12Digest.isSummaryOnly(digest), "digest 仅摘要/长度（不落 OCR 全文）")
  expectEq(mock.preflightCalls, 1, "采集前 CGPreflight 探活恰好一次")
  expectEq(mock.requestCalls, 0, "采集路径 CGRequest 零调用（授权请求只在 ⌥M 开关）")
  let rows = bridge.store.query(InteractionStore.Query(limit: 10))
  expectEq(rows.count, 1, "入库恰一条 key_session")
  expect(rows[0].ocrDigest != nil && rows[0].textIn.isEmpty && rows[0].textOut.isEmpty,
         "ocr_digest 在库、原文零落库")
  expect(!(rows[0].ocrDigest ?? "").contains("W32 SCREEN MARKER"), "digest 列绝不含 OCR 全文")
}

// MARK: - (7) 伪时钟防抖集成（onInputEvent 全链路，零 sleep）
runGroup {
  let (bridge, db) = makeBridge()
  defer { try? FileManager.default.removeItem(atPath: db) }
  let clock = FakeClock()
  let mock = MockScreenAccess()
  mock.authorized = true
  let collector = W12C1Collector(bridge: bridge, settings: W12Settings())
  collector.clock = { clock.now }
  collector.screenAccess = mock.make()
  collector.captureImageOverride = { _ in try makeTestCGImage(text: "W32 DEBOUNCE MARK") }
  W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
  W12Privacy.enableC1Screen(store: bridge.store, explicitConfirm: true)

  guard case .ingested = fire(collector, .keystroke) else {
    return expect(false, "t+0.0s 首键应 ingested")
  }
  clock.advance(0.5)
  guard case .skipped(let r) = fire(collector, .keystroke) else {
    return expect(false, "t+0.5s 窗内键应 skipped")
  }
  expect(r.contains("debounced"), "防抖窗内合并（伪时钟 t+0.5s < 2s）：\(r)")
  expectEq(bridge.store.count(), 1, "窗内按键合并为 1 轮（0 新增）")
  clock.advance(2.0)   // t+2.5s 出窗
  guard case .ingested = fire(collector, .keystroke) else {
    return expect(false, "出窗键应 ingested")
  }
  expectEq(bridge.store.count(), 2, "出防抖窗恢复采集（窗口外每窗最多一轮）")
  expectEq(mock.requestCalls, 0, "全链路 CGRequest 恒 0（打字零权限请求）")
}

// MARK: - (8) 开关中途开↔关：默认 OFF 的机制保证（含 SuggestContext 屏幕上下文）
runGroup {
  let (bridge, db) = makeBridge()
  defer { try? FileManager.default.removeItem(atPath: db) }
  let clock = FakeClock()
  let mock = MockScreenAccess()
  mock.authorized = true
  let screenRing = ScreenTextContext()
  let collector = W12C1Collector(bridge: bridge, settings: W12Settings())
  collector.clock = { clock.now }
  collector.screenAccess = mock.make()
  collector.screenContext = screenRing
  collector.captureImageOverride = { _ in try makeTestCGImage(text: "W32 TOGGLE MARK") }
  W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)

  // 开关关（默认）→ 跳过读屏
  guard case .skipped(let r1) = fire(collector, .keystroke) else {
    return expect(false, "开关关应 skipped")
  }
  expectEq(r1, W12ScreenGate.skipSwitchOffReason, "开关关 → 逐字 skipSwitchOffReason")
  // ⌥M 开关打开（唯一 request 发起点见 (9)；此处 mock 直接给授权）
  W12Privacy.enableC1Screen(store: bridge.store, explicitConfirm: true)
  expect(collector.isScreenEnabled, "开关打开 → isScreenEnabled")
  guard case .ingested = fire(collector, .keystroke) else {
    return expect(false, "开关开后按键应 ingested（skip 轮不占防抖窗）")
  }
  expectEq(screenRing.count, 1, "读屏进屏幕上下文环")
  expect(!collector.makeSuggestContext(beforeCursor: "x").screenText.isEmpty,
         "开关开 → SuggestContext.screenText 带屏幕上下文")
  // 开关关闭（随时可关）→ 立即停读屏 + 屏幕上下文默认 OFF
  clock.advance(3.0)
  W12Privacy.disableC1Screen(store: bridge.store)
  expect(!collector.isScreenEnabled, "开关关闭 → isScreenEnabled false")
  guard case .skipped(let r2) = fire(collector, .keystroke) else {
    return expect(false, "开关关后按键应 skipped")
  }
  expectEq(r2, W12ScreenGate.skipSwitchOffReason, "关闭后再按键 → 逐字 skipSwitchOffReason")
  expect(collector.makeSuggestContext(beforeCursor: "x").screenText.isEmpty,
         "开关关 → SuggestContext.screenText 空（屏幕上下文默认 OFF 机制保证）")
}

// MARK: - (9) requestAccess 唯一发起点 = ⌥M 开关打开动作（一次性授权请求）
runGroup {
  let mock = MockScreenAccess()   // authorized = false；grantOnRequest = true
  let access = mock.make()
  expectEq(mock.requestCalls, 0, "初始 requestCalls=0")
  // 模拟 ⌥M 开关打开动作（W20SquirrelScreenControl.setEnabled(true) 的唯一 request 调用）
  _ = access.requestAccess()
  expectEq(mock.requestCalls, 1, "⌥M 开关打开 → 恰好一次 CGRequestScreenCaptureAccess")
  expect(access.preflight(), "一次性请求同意后 preflight=true（探活与请求分离）")
  // 后续任何 preflight/采集都不再 request
  _ = access.preflight()
  expectEq(mock.requestCalls, 1, "后续探活/采集 CGRequest 恒 1（绝不重复/自动请求）")
  // 拒绝场景：grantOnRequest=false（用户在系统弹窗里点取消）
  let mock2 = MockScreenAccess()
  mock2.grantOnRequest = false
  let access2 = mock2.make()
  _ = access2.requestAccess()
  expect(!access2.preflight(), "用户拒绝 → preflight 仍 false（状态行「读屏未授权」，采集跳过读屏）")
  expectEq(mock2.requestCalls, 1, "拒绝后也不自动重请求（要用户再动开关）")
}

// MARK: - (10) 文件源（探针等价帧）不受 TCC 门禁影响（脚本化实测链路保持可用）
runGroup {
  let (bridge, db) = makeBridge()
  defer { try? FileManager.default.removeItem(atPath: db) }
  let mock = MockScreenAccess()
  let collector = W12C1Collector(bridge: bridge, settings: W12Settings())
  collector.screenAccess = mock.make()
  W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
  W12Privacy.enableC1Screen(store: bridge.store, explicitConfirm: true)
  let png = NSTemporaryDirectory() + "w32-gate-\(UUID().uuidString).png"
  let rep = NSBitmapImageRep(cgImage: try! makeTestCGImage(text: "W32 FILE SRC"))
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: png))
  defer { try? FileManager.default.removeItem(atPath: png) }
  let out = syncCapture(collector, .imageFile(URL(fileURLWithPath: png)))
  var fileIngested = false
  if case .ingested = out { fileIngested = true }
  expect(fileIngested, "文件源（等价截屏帧）→ 照常入库（不涉 TCC 门禁）：\(out)")
  expectEq(mock.preflightCalls, 0, "文件源零 preflight（TCC 门禁只管真实读屏）")
  expectEq(mock.requestCalls, 0, "文件源零 request")
}

}  // runAllTests

// ------------------------------------------------------------ 驱动辅助（同步化 async/completion）

/// 同步驱动 onInputEvent（completion 信号量）。
func fire(
  _ collector: W12C1Collector, _ trigger: W12InputTrigger,
  secureInput: Bool = false
) -> W12C1Collector.Outcome {
  let sem = DispatchSemaphore(value: 0)
  var out: W12C1Collector.Outcome = .skipped("none")
  collector.onInputEvent(trigger, appId: "com.apple.TextEdit", secureInput: secureInput) {
    out = $0
    sem.signal()
  }
  sem.wait()
  return out
}

/// 同步驱动 async captureAndIngest。
func syncCapture(
  _ collector: W12C1Collector, _ source: W12CaptureSource
) -> W12C1Collector.Outcome {
  let sem = DispatchSemaphore(value: 0)
  var out: W12C1Collector.Outcome = .skipped("none")
  Task {
    out = await collector.captureAndIngest(
      source: source, kind: .keySession,
      appId: "com.apple.TextEdit", secureInput: false)
    sem.signal()
  }
  sem.wait()
  return out
}
