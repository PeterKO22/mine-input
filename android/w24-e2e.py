#!/usr/bin/env python3
"""W24 端到端验收脚本（模拟器 + adb，中/EN 直输与密码框隐私确定性断言）。

流程（对齐 W24 验收项 + 用户确认的症状「只能输入中文」与设计意图「切英文输账号密码」）：
  0. 安装 APK + 清数据 + 启用 IME + 启动 W24 探针 Activity（真实普通框/密码框）+ 引擎部署
  1. 英文态打 hello → 直接上屏 hello（不过引擎：raw 恒空；真输入框 + input-connection）
  2. 英文态账号密码串（大小写 + 数字 + 特殊字符）完整上屏
  3. 切中文 → 出中文候选（nihao→你好）→ 选词上屏；混合场景：中文串中插英文
     （中文态打码未选词 → 切英文 = 原码上屏，Mac commit_code 语义）
  4. 中英往返 3 轮稳定（切中→打码选词→切英→打 ASCII，文本逐段累积断言）
  5. 真实工具栏点按「中/EN」键（w24_layout 坐标 → input tap）→ 模式翻转 + 复原
  6. 密码框自动 EN + 停一切采集（Mac C1 同步）：进密码框→EN 直输、采集探针
     COLLECT_BLOCKED、W11 零采集日志；明文密码框（textVisiblePassword）同口径
  7. 离开密码框 → 恢复原模式 + 采集恢复（探针走通 W11 上报链路）
  8. 持久化：EN 模式跨进程重启保留（force-stop 后重进仍 EN）
  9. AI 智能候选组标记（w24_aimark 演示位 → AI_MARK applied）

用法：python3 android/w24-e2e.py   （需 adb 可见模拟器；先 ./gradlew assembleDebug + fetch-rime-jni.sh）
说明：广播必须显式指定组件（-n com.mineinput.ime/.DebugReceiver）——隐式广播在
      API 34 被 stopped-state/后台限制丢弃（W14 实测）；断言一律先 logcat -c 再触发，
      避免旧日志假阳性（W11/W14/W16 e2e 同教训）。
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


def logcat(tag="W24"):
    return sh(["logcat", "-d", "-s", tag])


def last_line(needle, text=None, tag="W24"):
    text = text if text is not None else logcat(tag)
    hits = [l for l in text.splitlines() if needle in l]
    return hits[-1] if hits else ""


def wait_for(needle, timeout_s=30, tag="W24"):
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        line = last_line(needle, tag=tag)
        if line:
            return line
        time.sleep(1)
    return ""


def trigger(*extras, needle="", timeout_s=60, tag="W24"):
    """清日志 → 广播 → 等新鲜断言行（杜绝旧日志假阳性）。"""
    sh(["logcat", "-c"])
    bcast(*extras)
    return wait_for(needle, timeout_s, tag)


def dump_ui():
    for _ in range(8):
        sh(["shell", "uiautomator", "dump", "/sdcard/w24ui.xml"])
        xml = sh(["shell", "cat", "/sdcard/w24ui.xml"])
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


def ensure_ime():
    """选中本 IME 并断言生效（安装/清数据/force-stop 后系统可能回落 LatinIME）。"""
    for _ in range(3):
        sh(["shell", "ime", "enable", f"{PKG}/.MineImeService"])
        sh(["shell", "ime", "set", f"{PKG}/.MineImeService"])
        time.sleep(1)
        if "mCurMethodId=" + f"{PKG}/.MineImeService" in sh(["shell", "dumpsys", "input_method"]):
            return True
    return False


def tap_probe(which):
    """点按 W24 探针输入框（content-desc=w24_<which>）并等 IME 绑定。"""
    if not ensure_ime():
        return False
    xml = dump_ui()
    hit = find_node(xml, lambda a: a.get("content-desc", "") == f"w24_{which}")
    if not hit:
        return False
    (x1, y1, x2, y2), _ = hit
    sh(["shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2)])
    time.sleep(1.5)
    return "mBoundToMethod=true" in sh(["shell", "dumpsys", "input_method"])


def w24_type(text, clear=True):
    if clear:
        sh(["logcat", "-c"])
    bcast("--es", "cmd", "w24_type", "--es", "text", text)
    return wait_for(f"TYPE|text={text}|", 30)


def w24_status(clear=True):
    if clear:
        sh(["logcat", "-c"])
    bcast("--es", "cmd", "w24_status")
    return wait_for("STATUS|mode=", 30)


def w24_mode(mode, clear=True):
    if clear:
        sh(["logcat", "-c"])
    bcast("--es", "cmd", "w24_mode", "--es", "mode", mode)
    return wait_for("MODE|mode=", 30)


def field_text(which, clear=True):
    if clear:
        sh(["logcat", "-c"])
    bcast("--es", "cmd", "w24_fieldtext", "--es", "which", which)
    line = wait_for(f"FIELD|which={which}|", 30)
    m = re.search(r"\|text=(.*)\|active=", line)
    return m.group(1) if m else None


# ---------- 0. 环境：安装 + 清数据（首用部署口径） + 启动探针 ----------
step("0. 环境：安装 APK + 清数据 + 启用 IME + 探针 Activity + 引擎部署")
r = sh(["install", "-r", APK], timeout=180)
check("adb install", "Success" in r, r.strip().splitlines()[-1] if r.strip() else "")
sh(["shell", "pm", "clear", PKG])          # 清数据 → 默认 cn 模式 + 首用部署口径
check("选中本 IME（ime set 生效）", ensure_ime())
sh(["shell", "am", "start", "-n", f"{PKG}/.W24ProbeActivity"])
time.sleep(2)
sh(["logcat", "-c"])
bcast("--es", "cmd", "w16_startup")         # 引擎部署（中文候选断言前置）
line = wait_for("STARTUP|ok=true", 120, tag="W16")
check("混输引擎就绪（w16_startup STARTUP ok）", "STARTUP|ok=true" in line, line[-120:])
check("探针普通框聚焦 + IME 绑定（服务拉起）", tap_probe("normal"))
line = w24_status()
check("默认中文模式（mode=cn）", "STATUS|mode=cn" in line, line[-140:])

# ---------- 1. 英文态打 hello → 直接上屏 ----------
step("1. 英文态直输 hello（不过引擎，直接上屏）")
check("探针普通框聚焦 + IME 绑定", tap_probe("normal"))
line = w24_mode("en")
check("切 EN（持久状态 persisted=en）", "MODE|mode=en|persisted=en|ok=true" in line, line[-120:])
line = w24_type("hello")
check("hello 逐键走真实按键路径（dispatched=5）",
      "TYPE|text=hello|dispatched=5|mode=en" in line and "via=input-connection" in line, line[-140:])
txt = field_text("normal")
check("英文态直接上屏 hello（字段=hello）", txt == "hello", f"field={txt}")
line = w24_status()
m = re.search(r"\|raw=([^|]*)\|", line)
check("引擎零介入（raw 恒空）", m is not None and m.group(1) == "", line[-140:])
xml = dump_ui()
check("UI 实证：输入框含 hello", "hello" in xml)

# ---------- 2. 英文态账号密码串（大小写 + 数字 + 特殊字符） ----------
step("2. 英文态账号密码串完整上屏（数字/符号直输）")
line = w24_type("User_2026!p@ss")
check("密码串逐键直输（14 键 dispatched）", "TYPE|text=User_2026!p@ss|dispatched=14|mode=en" in line,
      line[-140:])
txt = field_text("normal")
check("账号密码串完整上屏（含数字 _ ! @）", txt == "helloUser_2026!p@ss", f"field={txt}")

# ---------- 3. 切中文 → 中文候选 + 混合场景 ----------
step("3. 切中文出候选（nihao→你好）+ 中文串中插英文")
line = w24_mode("cn")
check("切回中文（mode=cn）", "MODE|mode=cn|persisted=cn|ok=true" in line, line[-120:])
w24_type("nihao")
cands = last_line("CANDS|")
check("中文候选真数据（CANDS 含 你好）", "CANDS|n=" in cands and "你好" in cands, cands[-160:])
sh(["logcat", "-c"])
bcast("--es", "cmd", "w24_pick", "--es", "index", "0")
line = wait_for("PICK|index=0|", 30)
check("选词上屏 你好（via=input-connection）",
      "text=你好" in line and "via=input-connection" in line and "ok=true" in line, line[-140:])
line = w24_type("pinyin")                   # 打码不选词
check("中文态继续打码（composing=pinyin）", "TYPE|text=pinyin|dispatched=6|mode=cn" in line, line[-120:])
line = w24_mode("en")                       # 混合场景：中文串中切英文
check("切英文时原码上屏（commit_code 语义）",
      "MODE|mode=en" in line and "ok=true" in line, line[-120:])
txt = field_text("normal")
check("混合场景文本正确（…你好pinyin）", txt == "helloUser_2026!p@ss你好pinyin", f"field={txt}")
line = w24_type("abc")
txt = field_text("normal")
check("英文段紧随中文段（…pinyinabc）", txt == "helloUser_2026!p@ss你好pinyinabc", f"field={txt}")

# ---------- 4. 中英往返 3 轮稳定 ----------
step("4. 中英往返 3 轮稳定（切中→w→人→切英→X<i>d）")
expected = txt or ""
rounds_ok = True
for i in range(1, 4):
    w24_mode("cn")
    w24_type("w")
    sh(["logcat", "-c"])
    bcast("--es", "cmd", "w24_pick", "--es", "index", "0")
    line = wait_for("PICK|index=0|", 30)
    if "text=人" not in line or "ok=true" not in line:
        rounds_ok = False
    w24_mode("en")
    w24_type(f"X{i}d")
    expected += f"人X{i}d"
    txt = field_text("normal")
    if txt != expected:
        rounds_ok = False
check("3 轮往返全部命中（w→人 + X<i>d 直输）", rounds_ok, f"expected={expected}")
line = w24_status()
check("往返后模式稳定（mode=en）", "STATUS|mode=en" in line, line[-140:])

# ---------- 5. 真实工具栏点按「中/EN」键 ----------
step("5. 真实点按工具栏「中/EN」切换键（MODE_CHIP 坐标）")
sh(["logcat", "-c"])
bcast("--es", "cmd", "w24_layout")
line = wait_for("MODE_CHIP|", 30)
m = re.search(r"x=([\d.]+)\|y=([\d.]+)", line)
check("解析到切换键坐标", m is not None, line[-120:])
if m:
    cx, cy = int(float(m.group(1))), int(float(m.group(2)))
    sh(["shell", "input", "tap", str(cx), str(cy)])
    line = wait_for("MODE|mode=", 30)
    check("点按 → EN 切回中文（mode=cn）", "MODE|mode=cn" in line, line[-120:])
    sh(["shell", "input", "tap", str(cx), str(cy)])
    line = wait_for("MODE|mode=", 30)
    check("再点按 → 切回英文（mode=en）", "MODE|mode=en" in line, line[-120:])

# ---------- 6. 密码框自动 EN + 停一切采集（Mac C1 同步） ----------
step("6. 密码框自动 EN + 采集闸（进密码框→EN 直输且零采集日志）")
w24_mode("cn")                              # 明确 cn 进场，验证自动切换
sh(["logcat", "-c"])                        # 单一观察窗：以下全程零清窗，杜绝假阴性
check("探针密码框聚焦 + IME 绑定", tap_probe("password"))
line = wait_for("PRIVACY|field=password|mode=en|collection=paused", 30)
check("进密码框自动 EN + 采集暂停（PRIVACY 日志）",
      "PRIVACY|field=password|mode=en|collection=paused" in line, line[-140:])
line = w24_status(clear=False)
check("密码框态：mode=en + collection=paused",
      "STATUS|mode=en|password_field=true|collection=paused" in line, line[-140:])
line = w24_mode("cn", clear=False)
check("密码框强制 EN 不可切（ok=false）", "MODE|mode=en" in line and "ok=false" in line, line[-120:])
bcast("--es", "cmd", "w24_collect_probe")
line = wait_for("COLLECT_BLOCKED|reason=password_field", 30)
check("采集探针被拦（COLLECT_BLOCKED password_field）",
      "COLLECT_BLOCKED|reason=password_field" in line, line[-140:])
line = w24_type("Pw123!", clear=False)
check("密码框 EN 直输密码串（dispatched=6）", "TYPE|text=Pw123!|dispatched=6|mode=en" in line, line[-120:])
txt = field_text("password", clear=False)
check("密码完整上屏（进程内读回）", txt == "Pw123!", f"field={txt}")
w11 = logcat("W11")
check("W11 零采集日志（无 INGEST_ENQUEUED/UPLOAD_BLOCKED）",
      "INGEST_ENQUEUED" not in w11 and "UPLOAD_BLOCKED" not in w11,
      f"w11_lines={len(w11.splitlines())}")
check("探针密码框聚焦 + IME 绑定（明文密码框）", tap_probe("visible"))
line = w24_status(clear=False)
check("明文密码框同口径（password_field=true）", "password_field=true" in line, line[-140:])
w24_type("Vis!ble2", clear=False)
txt = field_text("visible", clear=False)
check("明文密码框 EN 直输完整上屏", txt == "Vis!ble2", f"field={txt}")

# ---------- 7. 离开密码框 → 恢复模式 + 采集恢复 ----------
step("7. 离开密码框：恢复原模式 + 采集恢复")
sh(["logcat", "-c"])
check("回到普通框", tap_probe("normal"))
line = wait_for("PRIVACY|field=normal|mode=cn|collection=resumed", 30)
check("离开恢复 cn + 采集恢复（PRIVACY 日志）",
      "PRIVACY|field=normal|mode=cn|collection=resumed" in line, line[-140:])
sh(["logcat", "-c"])
bcast("--es", "cmd", "w24_collect_probe")
time.sleep(2)
w11 = logcat("W11")
check("采集恢复实证（探针走通 W11 上报链路）",
      "INGEST_ENQUEUED" in w11 or "UPLOAD_BLOCKED" in w11, w11.splitlines()[-1][-140:] if w11.splitlines() else "")

# ---------- 8. 持久化：EN 跨进程重启保留 ----------
step("8. 中/EN 持久状态跨进程重启保留")
line = w24_mode("en")
check("设 EN（persisted=en）", "MODE|mode=en|persisted=en" in line, line[-120:])
sh(["shell", "am", "force-stop", PKG])
time.sleep(2)
check("重启后选中本 IME", ensure_ime())
sh(["shell", "am", "start", "-n", f"{PKG}/.W24ProbeActivity"])
time.sleep(2)
check("重启后探针普通框聚焦", tap_probe("normal"))
line = w24_status()
check("重启后仍 EN（持久状态）", "STATUS|mode=en" in line, line[-140:])
w24_mode("cn")                              # 复位

# ---------- 9. AI 智能候选组标记 ----------
step("9. AI 智能候选组标记（cyan 玻璃卡 + AI 角标渲染管道）")
w24_type("w")
line = trigger("--es", "cmd", "w24_aimark", "--es", "n", "2", needle="AI_MARK|", timeout_s=30)
check("AI 组标记演示位生效（AI_MARK applied）", "AI_MARK|n=2|applied=true" in line, line[-120:])
line = w24_status()
check("候选带 AI 标记（demo_ai=2）", "demo_ai=2" in line, line[-120:])

# ---------- 结果 ----------
step("结果")
npass = sum(1 for _, ok in results if ok)
nfail = len(results) - npass
print(f"PASS={npass} FAIL={nfail}")
sys.exit(0 if nfail == 0 else 1)
