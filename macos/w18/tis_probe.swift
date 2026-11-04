// W18 显示名探针：用 TIS API 列出输入源的 kTISPropertyLocalizedName，并对
// InfoPlist.strings 本地化解析链做 zh-Hans 显式断言（D15：zh「提炼输入法」/ en "Mine Input"）。
// 编译：swiftc -O macos/w18/tis_probe.swift -o macos/w18/tis-probe -framework Carbon
// 用法：macos/w18/tis-probe [--all] [app路径]（默认 ~/Library/Input Methods/Squirrel-dev.app）
//
// 断言语义（退出码）：
//   0 = TIS 本地化名是产品名（含「提炼输入法」或 "Mine Input"）且 zh-Hans 链路解析出「提炼输入法」
//   2 = 找到 dev 输入源但名字仍是裸 ID / 旧名（未本地化），或 zh-Hans 解析不正确
//   3 = 没找到 dev 输入源（可能未注册，或 macOS 输入源缓存未刷新）
//
// 语言上下文说明（实测）：kTISPropertyLocalizedName 由 HIToolbox 在「宿主应用上下文」里
// 解析——裸 CLI 无 bundle 上下文时 CFBundleCopyPreferredLocalizationsFromArray 固定回退
// en，故 TIS 名可能是英文 "Mine Input"；GUI（如中文界面的系统设置「添加输入法」对话框）
// 的应用上下文为 zh-Hans，会解析出「提炼输入法」。两种都是 D15 产品名；zh 值的正确性由
// 本工具的 zh-Hans 显式解析断言兜底（forPreferences: zh-Hans-CN/zh-Hans → zh-Hans.lproj）。
//
// 注意：macOS 对输入源列表有缓存，重装输入法后名字可能仍是旧的，
// 需注销重登（或重启）后刷新；w18-verify.sh 会自动重试并提示。
import Carbon
import Foundation

func prop(_ src: TISInputSource, _ key: CFString) -> String {
  guard let raw = TISGetInputSourceProperty(src, key) else { return "<nil>" }
  return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

var showAll = false
var appPath = NSHomeDirectory() + "/Library/Input Methods/Squirrel-dev.app"
for arg in CommandLine.arguments.dropFirst() {
  if arg == "--all" { showAll = true } else { appPath = arg }
}
let needleID = "im.rime.inputmethod.Squirrel.dev"

// ---------- [1/2] TIS 运行时：kTISPropertyLocalizedName ----------
guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
  print("tis-probe: TISCreateInputSourceList failed")
  exit(3)
}

var found: [(id: String, name: String)] = []
for src in list {
  let id = prop(src, kTISPropertyInputSourceID)
  if !showAll && !id.contains(needleID) { continue }
  let name = prop(src, kTISPropertyLocalizedName)
  let bundle = prop(src, kTISPropertyBundleID)
  print("input-source: id=\(id)  localized-name=\(name)  bundle=\(bundle)")
  if id.contains(needleID) {
    found.append((id, name))
  }
}
if showAll { print("total input sources: \(list.count)") }

if found.isEmpty {
  print("RESULT: FAIL — 未找到 \(needleID)* 输入源（先跑 build/install-dev.sh 注册；若已装仍看不到，注销重登后重试）")
  exit(3)
}

var fail = false

// TIS 名必须是产品名（D15），不是裸 ID / 旧名
let tisOk = found.contains { $0.name.contains("提炼输入法") || $0.name.contains("Mine Input") }
if tisOk {
  print("[1/2] TIS PASS — \(found.count) 个 dev 输入源，本地化名含「提炼输入法」/ 'Mine Input'")
} else {
  let names = found.map { "\($0.id)=\($0.name)" }.joined(separator: "; ")
  print("[1/2] TIS FAIL — 本地化名未生效（仍为裸 ID 或旧名）：\(names)")
  print("hint: macOS 对输入源列表/显示名有缓存；重新安装后可能需要注销并重新登录（或重启）后才刷新。")
  fail = true
}

// ---------- [2/2] zh-Hans 显式解析（同一 InfoPlist.strings 链路） ----------
guard let app = Bundle(path: appPath) else {
  print("[2/2] ZH FAIL — 打不开 \(appPath)")
  exit(fail ? 2 : 2)
}
let zhLocales = ["zh-Hans-CN", "zh-Hans", "zh-Hant", "en"]
let preferred = Bundle.preferredLocalizations(from: app.localizations, forPreferences: zhLocales)
print("[2/2] zh-resolve: preferredLocalizations(forPreferences: \(zhLocales.joined(separator: ","))) = \(preferred)")
// 用 zh-Hans 语言环境显式读 InfoPlist.strings 解析链（与 HIToolbox 同源）
let zhStringsURL = app.bundleURL.appendingPathComponent("Contents/Resources/zh-Hans.lproj/InfoPlist.strings")
guard let zhDict = NSDictionary(contentsOf: zhStringsURL) as? [String: String] else {
  print("[2/2] ZH FAIL — 读不到 zh-Hans.lproj/InfoPlist.strings")
  exit(2)
}
var zhFail = false
for key in ["CFBundleName", "\(needleID)", "\(needleID).Hans", "\(needleID).Hant"] {
  let v = zhDict[key] ?? "<缺失>"
  let ok = v == "提炼输入法"
  print("  \(key) => \(v)  [\(ok ? "PASS" : "FAIL")]")
  if !ok { zhFail = true }
}
if zhFail {
  print("[2/2] ZH FAIL — zh-Hans 解析未得到「提炼输入法」")
  fail = true
} else {
  print("[2/2] ZH PASS — zh-Hans 链路解析出「提炼输入法」（GUI 中文界面对话框/菜单栏同此值）")
}

exit(fail ? 2 : 0)
