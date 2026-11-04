#!/usr/bin/env python3
"""W16 端到端验收脚本（模拟器 + adb，混输引擎确定性断言）。

流程（对齐 W16 验收项）：
  0. 安装 APK + 清数据（首用部署口径）+ 启用 IME + 启动一次（解除 stopped）
  1. 首用部署：ping_wubi_mixed schema 随 app 部署，设备端编译码表 ≤5s（deploy_ms）
  2. 候选真数据（与 W15/W1 console 输出逐项一致）：
       w→人（五笔一级简码）/ gggg→王（五笔全码）/ pinyin→拼音前移 /
       nihao→你好（拼音词组）/ zni→反查注释含五笔码
  3. 选词上屏走 W5 commit 通道（真输入框：通讯录新建联系人，via=input-connection）
  4. L1 词频/造词：打过的词二次直达（LEARN/LEARN2 direct=true）+ encode_commit_history
     造词成句候选（PHRASE found=true）
  5. NFR1 性能：按键→候选 ≤30ms（w16_bench，单线程排队+processRimeKey+getRimeCandidates 全链路）

用法：python3 android/w16-e2e.py   （需 adb 可见模拟器；先 ./gradlew assembleDebug + fetch-rime-jni.sh）
说明：广播必须显式指定组件（-n com.mineinput.ime/.DebugReceiver）——隐式广播在
      API 34 被 stopped-state/后台限制丢弃（W14 实测）；断言一律先 logcat -c 再触发，
      避免旧日志假阳性（W11/W14 e2e 同教训）。
"""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = os.environ.get("ADB") or os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
DEV = "emulator-5554"
PKG = "com.mineinput.ime"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APK = os.path.join(ROOT, "android/app/build/outputs/apk/debug/app-debug.apk")

results = []


def sh(args, timeout=60):
    r = subprocess.run([ADB, "-s", DEV] + args, capture_output=True, text=True, timeout=timeout)
    return r.stdout + r.stderr


def bcast(*extras):
    """显式组件广播（隐式会被 API 34 丢弃）。"""
    return sh(["shell", "am", "broadcast", "-n", f"{PKG}/.DebugReceiver",
               "-a", f"{PKG}.DEBUG_ACTION"] + list(extras))


def step(name):
    print(f"\n=== {name} ===")


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  {detail}" if detail else ""))


def logcat():
    return sh(["logcat", "-d", "-s", "W16:I"])


def last_line(needle, text=None):
    text = text if text is not None else logcat()
    hits = [l for l in text.splitlines() if needle in l]
    return hits[-1] if hits else ""


def trigger(*extras, needle="", timeout_s=120):
    """清日志 → 广播 → 等新鲜断言行（杜绝旧日志假阳性）。"""
    sh(["logcat", "-c"])
    bcast(*extras)
    return wait_for(needle, timeout_s)


def wait_for(needle, timeout_s=120):
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        line = last_line(needle)
        if line:
            return line
        time.sleep(1)
    return ""


def dump_ui():
    for _ in range(8):
        sh(["shell", "uiautomator", "dump", "/sdcard/w16ui.xml"])
        xml = sh(["shell", "cat", "/sdcard/w16ui.xml"])
        if "<node" in xml:
            return xml
        time.sleep(1)
    return ""


def find_node(xml, pred):
    try:
        root = ET.fromstring(xml[xml.index("<"):])
    except Exception:
        return None
    for n in root.iter("node"):
        attrs = n.attrib
        if pred(attrs):
            b = [int(v) for v in re.findall(r"\d+", attrs.get("bounds", ""))]
            if len(b) == 4:
                return b, attrs
    return None


# ---------- 0. 环境：安装 + 清数据（首用部署口径） + 启动 ----------
step("0. 环境：安装 APK + 清数据（首次启动） + 启用 IME")
r = sh(["install", "-r", APK], timeout=180)
check("adb install", "Success" in r, r.strip().splitlines()[-1] if r.strip() else "")
sh(["shell", "pm", "clear", PKG])          # 清数据 → 首用 fullCheck 部署口径
sh(["shell", "ime", "enable", f"{PKG}/.MineImeService"])
sh(["shell", "ime", "set", f"{PKG}/.MineImeService"])
sh(["shell", "am", "start", "-n", f"{PKG}/.MainActivity"])
time.sleep(2)
sh(["logcat", "-c"])

# ---------- 1. 首用部署（schema 随 app 部署，设备端编译码表 ≤5s） ----------
step("1. 首用部署：ping_wubi_mixed 设备端编译码表（≤5s）")
line = trigger("--es", "cmd", "w16_startup", needle="STARTUP|ok=true", timeout_s=120)
check("引擎启动 + schema 可选中（STARTUP ok）", "STARTUP|ok=true" in line, line[-120:])
m = re.search(r"deploy_ms=(\d+)", line)
if m:
    check("首用部署 ≤5s（NFR 验收项）", int(m.group(1)) <= 5000, f"deploy_ms={m.group(1)}")
check("首用口径 first_run=true", "first_run=true" in line, line[-120:])
line = trigger("--es", "cmd", "w16_status", needle="STATUS|", timeout_s=30)
check("w16_status 引擎就绪（schema=ping_wubi_mixed）",
      "state=ready" in line and "schema=ping_wubi_mixed" in line, line[-140:])

# ---------- 2. 候选真数据（W15 回归对齐：形码优先/拼音前移/z 反查） ----------
step("2. 候选真数据断言（w→人 / gggg→王 / pinyin→拼音前移 / nihao→你好 / zni 反查）")
for seq, expect in [("w", "人"), ("gggg", "王"), ("pinyin", "拼音"), ("nihao", "你好")]:
    line = trigger("--es", "cmd", "w16_seq", "--es", "seq", seq, "--es", "expect", expect,
                   needle="EXPECT|", timeout_s=60)
    ok = f"EXPECT|seq={seq}|expect={expect}|got={expect}|match=true" in line
    check(f"{seq} → {expect}", ok, (last_line(f"RESULT|seq={seq}|") or "")[-150:])

line = trigger("--es", "cmd", "w16_seq", "--es", "seq", "zni", needle="RESULT|seq=zni|", timeout_s=60)
check("zni 反查注释含五笔编码", bool(re.search(r"\d+=(你|拟|尼|呢)\([a-z ]*(wq|wqiy|rny|nxv|knx)", line)),
      line[-170:])

# ---------- 3. 选词上屏走 W5 commit 通道（真输入框） ----------
step("3. 真输入框：选词上屏（W5 commit 通道，via=input-connection）")
sh(["shell", "am", "start", "-a", "android.intent.action.INSERT",
    "-d", "content://com.android.contacts/contacts", "--ez", "finishActivityOnSave", "false"])
time.sleep(3)
xml = dump_ui()
hit = find_node(xml, lambda a: "EditText" in a.get("class", "") and a.get("enabled") == "true")
check("找到可输入框（EditText）", hit is not None)
if hit:
    (x1, y1, x2, y2), _ = hit
    sh(["shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2)])
    time.sleep(1.5)
    r = sh(["shell", "dumpsys", "input_method"])
    check("IME 已绑定输入框", "mBoundToMethod=true" in r)
    line = trigger("--es", "cmd", "w16_commit", "--es", "seq", "gggg", "--es", "index", "0",
                   "--es", "expect", "王", needle="COMMIT|", timeout_s=60)
    check("gggg 选第 1 候选 → 王（engine.commit）",
          "text=王" in line and "expect=王|match=true" in line, line[-150:])
    check("经 W5 commit 通道上屏（via=input-connection）", "via=input-connection" in line, line[-150:])
    time.sleep(1)
    xml = dump_ui()
    check("上屏记录：输入框含「王」", xml is not None and "王" in xml)

# ---------- 4. L1 词频/造词（打过的词二次直达） ----------
step("4. L1 词频/造词：打过的词二次直达 + 造词成句候选")
line = trigger("--es", "cmd", "w16_learn", "--es", "seq", "gggg", "--es", "index", "2",
               needle="PHRASE|", timeout_s=60)
learn = last_line("LEARN|seq=")
learn2 = last_line("LEARN2|seq=")
phrase = last_line("PHRASE|")
check("词频学习：点选候选 A 后重打同码 → A 直达首位（LEARN direct）",
      "LEARN|" in learn and "direct=true" in learn, learn[-170:])
check("二次造词直达：点选候选 B 后重打同码 → B 直达首位（LEARN2 direct）",
      "LEARN2|" in learn2 and "direct=true" in learn2, learn2[-170:])
check("造词生效：encode_commit_history 成句候选 A+B 出现在候选栏（PHRASE found）",
      "PHRASE|" in phrase and "found=true" in phrase, phrase[-170:])

# ---------- 5. NFR1 性能：按键→候选 ≤30ms ----------
step("5. NFR1 性能：按键→候选延迟（w16_bench，全链路含引擎单线程排队）")
line = trigger("--es", "cmd", "w16_bench", "--es", "n", "100", "--es", "seq", "gggg",
               needle="BENCH|", timeout_s=120)
m = re.search(r"p95_ms=([\d.]+)", line)
check("BENCH 通过（pass=true）", "pass=true" in line, line[-160:])
if m:
    check("NFR1 按键→候选 p95 ≤30ms", float(m.group(1)) <= 30.0, f"p95_ms={m.group(1)}")

# ---------- 结果 ----------
step("结果")
npass = sum(1 for _, ok in results if ok)
nfail = len(results) - npass
print(f"PASS={npass} FAIL={nfail}")
sys.exit(0 if nfail == 0 else 1)
