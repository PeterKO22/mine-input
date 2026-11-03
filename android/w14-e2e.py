#!/usr/bin/env python3
"""W14 端到端验收脚本（模拟器 + adb，转写确定性可断言）。

流程（对齐 W14 验收项）：
  0. 安装 APK、授权麦克风、启用 IME、启动一次（解除 stopped 状态）
  1. 模型首用下载（SHA256 钉死校验）：单文件下载器冒烟（silero_vad.onnx）+ 全量 install
     （SenseVoice tar.bz2 下载→校验→纯 Java 解压→逐文件校验）
  2. DebugReceiver 推 WAV → 转写确定性断言（s1 逐字断言；s3 热词开/关对照）
  3. 分段转写 + 候选区滚动（多段样音）→ 松开上屏（与真实 PTT 同一条 commit 通道；
     断言滚动文本 == 上屏文本）
  4. 上屏记录：真输入框（通讯录新建联系人）→ w14_ptt → 断言文本出现在输入框
  5. 真实 PTT 手势长按（模拟器静音）→ 失败兜底「请重说」（不瞎猜上屏）
  6. 取消：滑出 PTT 键 / 返回键 → 断言 PTT_CANCEL（不上屏）
  7. AudioRecord 实采探针（16k mono 内存缓冲不落盘）

用法：python3 android/w14-e2e.py   （需 adb 可见模拟器；voice/audio 样音已生成）
说明：广播必须显式指定组件（-n com.mineinput.ime/.DebugReceiver）——隐式广播在
      API 34 被 stopped-state/后台限制丢弃（实测 result=0 无 receiver 投递）。
      断言一律先 logcat -c 再触发，避免旧日志假阳性（W11 e2e 同教训）。
"""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = "/Users/you/Library/Android/sdk/platform-tools/adb"
DEV = "emulator-5554"
PKG = "com.mineinput.ime"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APK = os.path.join(ROOT, "android/app/build/outputs/apk/debug/app-debug.apk")
AUDIO = os.path.join(ROOT, "voice/audio")

S1_TEXT = "今天天气不错，我们下午去公园散步吧。"

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
    return sh(["logcat", "-d", "-s", "W14:I"])


def last_line(needle, text=None):
    text = text if text is not None else logcat()
    hits = [l for l in text.splitlines() if needle in l]
    return hits[-1] if hits else ""


def trigger(*extras, needle="", timeout_s=300):
    """清日志 → 广播 → 等新鲜断言行（杜绝旧日志假阳性）。"""
    sh(["logcat", "-c"])
    bcast(*extras)
    return wait_for(needle, timeout_s)


def wait_for(needle, timeout_s=300):
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        line = last_line(needle)
        if line:
            return line
        time.sleep(2)
    return ""


def dump_ui():
    for _ in range(8):
        sh(["shell", "uiautomator", "dump", "/sdcard/w14ui.xml"])
        xml = sh(["shell", "cat", "/sdcard/w14ui.xml"])
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


# ---------- 0. 环境 ----------
step("0. 环境：安装 APK + 授权 + 启动（解除 stopped）")
r = sh(["install", "-r", APK], timeout=180)
check("adb install", "Success" in r, r.strip().splitlines()[-1] if r.strip() else "")
sh(["shell", "pm", "grant", PKG, "android.permission.RECORD_AUDIO"])
sh(["shell", "ime", "enable", f"{PKG}/.MineImeService"])
sh(["shell", "ime", "set", f"{PKG}/.MineImeService"])
sh(["shell", "am", "start", "-n", f"{PKG}/.MainActivity"])
time.sleep(2)
sh(["logcat", "-c"])

# ---------- 1. 模型首用下载（SHA256 校验） ----------
step("1. 模型首用下载（SHA256 钉死；模型不进 APK）")
# 1a. 下载器冒烟：单文件 + SHA256 校验（silero_vad.onnx 643KB）
line = trigger("--es", "cmd", "w14_model",
               "--es", "url", "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
               "--es", "sha256", "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
               "--es", "name", "silero_vad.onnx", "--es", "dest", "silero_vad.onnx",
               needle="MODEL_OK single", timeout_s=120)
check("单文件下载 + SHA256 校验（VAD）", "MODEL_OK single" in line and "9e2449e1" in line, line[-120:])

# 1b. 全量 install（已装则 already-installed；未装走 163MB 归档下载+解压+逐文件校验）
line = trigger("--es", "cmd", "w14_model", needle="MODEL_OK", timeout_s=1500)
check("全量模型安装（SenseVoice int8 归档）", "MODEL_OK" in line, line[-140:])
line = trigger("--es", "cmd", "w14_status", needle="STATUS", timeout_s=30)
check("w14_status 模型已就绪", "installed=true" in line and "engine_loaded" in line, line[-140:])
line = wait_for("ENGINE_LOADED", 120)
check("sherpa-onnx 引擎加载（SenseVoice+VAD）", "ENGINE_LOADED" in line, line[-120:])

# ---------- 2. 推 WAV → 确定性转写 ----------
step("2. DebugReceiver 推 WAV → 转写结果确定性断言")
sh(["shell", "mkdir", "-p", "/data/local/tmp/w14"])
for f in ["s1.wav", "s3.wav", "benchmark_multi.wav"]:
    sh(["push", os.path.join(AUDIO, f), f"/data/local/tmp/w14/{f}"])

line = trigger("--es", "cmd", "w14_asr", "--es", "wav", "/data/local/tmp/w14/s1.wav",
               "--es", "expect", S1_TEXT, needle="ASR_EXPECT", timeout_s=120)
check("s1 转写逐字断言", "ASR_EXPECT match=true" in line, line[-160:])
check("s1 转写文本正确", f"text={S1_TEXT}" in (last_line("ASR_RESULT") or ""))
lm = re.search(r"elapsed_ms=(\d+)", last_line("ASR_RESULT"))
if lm:
    check("s1 全管线延迟 NFR2 ≤1500ms", int(lm.group(1)) <= 1500, f"elapsed_ms={lm.group(1)}")

line = trigger("--es", "cmd", "w14_asr", "--es", "wav", "/data/local/tmp/w14/s3.wav",
               needle="ASR_RESULT", timeout_s=120)
mtext = re.search(r"text=(.*?) low_conf=", line)
s3_text = mtext.group(1) if mtext else ""
check("s3 热词纠偏生效（可颂）", "可颂" in s3_text and "可送" not in s3_text, f"text={s3_text}")
check("s3 热词编辑记录（同音替换）", "同音替换: 可送→可颂" in line)

line = trigger("--es", "cmd", "w14_asr", "--es", "wav", "/data/local/tmp/w14/s3.wav",
               "--es", "no_hotwords", "1", needle="ASR_RESULT", timeout_s=120)
check("s3 热词对照组（关：可送）", "可送" in line, line[-160:])

# ---------- 3. 分段转写 + 滚动 + 松开上屏 ----------
step("3. 分段转写 → 候选区滚动 → 松开上屏（W5 commit 通道）")
line = trigger("--es", "cmd", "w14_ptt", "--es", "wav", "/data/local/tmp/w14/benchmark_multi.wav",
               needle="PTT_DONE", timeout_s=300)
n_seg = len([l for l in logcat().splitlines() if "SEGMENT i=" in l])
check("多段样音分段转写（≥2 段）", n_seg >= 2, f"segments_logged={n_seg}")
roll_lines = [l for l in logcat().splitlines() if "PTT_ROLLING text=" in l]
check("候选区滚动多级刷新（≥2 次）", len(roll_lines) >= 2, f"rolling_updates={len(roll_lines)}")
last_roll = roll_lines[-1].split("PTT_ROLLING text=", 1)[1].strip() if roll_lines else ""
check("滚动文本 == 上屏文本", bool(last_roll) and f"text={last_roll}" in line, f"rolling_len={len(last_roll)}")
check("松开上屏（COMMIT_OK）", "COMMIT_OK" in last_line("COMMIT_OK"), last_line("COMMIT_OK")[-120:])
check("上屏记录（COMMIT_RECORD）", "COMMIT_RECORD" in last_line("COMMIT_RECORD"))
check("多段会话转写全文正确", "今天天气不错" in line and "月面照片" in line, line[-160:])
tm = re.search(r"final_ms=(\d+)", line)
if tm:
    check("松开→上屏延迟 NFR2 ≤1500ms（final_ms，流式终稿）", int(tm.group(1)) <= 1500, f"final_ms={tm.group(1)}")

# ---------- 4. 上屏记录（真输入框） ----------
step("4. 真输入框上屏记录（通讯录新建联系人）")
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
    line = trigger("--es", "cmd", "w14_ptt", "--es", "wav", "/data/local/tmp/w14/s1.wav",
                   "--es", "expect", S1_TEXT, needle="PTT_EXPECT", timeout_s=300)
    check("经输入法 commit 通道上屏（via=input-connection）",
          "PTT_EXPECT match=true" in line and "via=input-connection" in (last_line("COMMIT_OK") or ""),
          (last_line("COMMIT_OK") or "")[-120:])
    time.sleep(1)
    xml = dump_ui()
    check("上屏记录：输入框含转写文本", xml is not None and S1_TEXT in xml)

# ---------- 5. 真实 PTT 手势：失败兜底（静音 → 请重说，不瞎猜） ----------
step("5. 真实 PTT 长按（模拟器静音）→ 失败提示重说")
win_dump = sh(["shell", "dumpsys", "window", "windows"])
top = None
lines = win_dump.splitlines()
for i, l in enumerate(lines):
    if "InputMethod" in l and "}:" in l:
        for l2 in lines[i:i + 80]:
            m = re.search(r"frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]", l2)
            if m:
                top = int(m.group(2))
                break
        if top is not None:
            break
check("解析到键盘窗口顶边（dumpsys window）", top is not None, f"ime_top={top}")
if top is None:
    top = 2400 - 850  # 兜底：实测键盘窗 850px
DENSITY = 2.625  # 420dpi
ptt_x = int(317.4 * DENSITY)   # KeyboardView 第 4 行 PTT 键中心（权重布局实测）
ptt_y = top + int(254 * DENSITY)
sh(["logcat", "-c"])
sh(["shell", "input", "swipe", str(ptt_x), str(ptt_y), str(ptt_x), str(ptt_y), "1500"])
line = wait_for("PTT_DONE", 60)
check("长按 PTT 录音（AudioRecord 真实路径）",
      "REC_START" in last_line("REC_START") and "REC_STOP" in last_line("REC_STOP"),
      (last_line("REC_STOP") or "")[-80:])
check("静音失败兜底（提示重说、不上屏）",
      "PTT_FAIL source=ptt-release reason=no_speech_detected" in last_line("PTT_FAIL"),
      (last_line("PTT_FAIL") or "")[-120:])
check("失败时无 COMMIT", "COMMIT_OK" not in logcat())

# ---------- 6. 取消手势（滑出 / 返回） ----------
step("6. 取消手势（滑出 PTT / 返回键）")
sh(["logcat", "-c"])
sh(["shell", "input", "swipe", str(ptt_x), str(ptt_y), "200", str(ptt_y - 400), "1200"])
line = wait_for("PTT_CANCEL", 60)
check("滑出取消（PTT_CANCEL + slide-out）",
      "PTT_CANCEL dropped=true" in line and "PTT_CANCEL_REASON slide-out" in logcat(),
      (last_line("PTT_CANCEL_REASON") or "")[-80:])
check("取消不上屏（无 COMMIT）", "COMMIT_OK" not in logcat())

sh(["logcat", "-c"])
p = subprocess.Popen([ADB, "-s", DEV, "shell", "input", "swipe",
                      str(ptt_x), str(ptt_y), str(ptt_x), str(ptt_y), "3000"])
time.sleep(1.2)
sh(["shell", "input", "keyevent", "4"])
p.wait(timeout=10)
line = wait_for("PTT_CANCEL", 60)
check("返回键取消（PTT_CANCEL + key=back）",
      "PTT_CANCEL dropped=true" in line and "PTT_CANCEL_REASON key=back" in logcat(),
      (last_line("PTT_CANCEL_REASON") or "")[-80:])
check("取消不上屏（无 COMMIT）", "COMMIT_OK" not in logcat())

# ---------- 7. AudioRecord 实采探针 ----------
step("7. AudioRecord 16k mono 内存缓冲探针")
line = trigger("--es", "cmd", "w14_rec", "--es", "ms", "2000", needle="REC_OK", timeout_s=60)
check("录音探针（不落盘、内存缓冲）", "REC_OK" in line and "memory-only" in line, line[-120:])
mb = re.search(r"bytes=(\d+)", line)
check("采样字节数符合 16k mono pcm16（2s≈64000）",
      bool(mb) and 50000 <= int(mb.group(1)) <= 80000, (mb.group(0) if mb else ""))

# ---------- 结果 ----------
print("\n=== 结果 ===")
passed = sum(1 for _, ok in results if ok)
print(f"PASS={passed} FAIL={len(results) - passed}")
for name, ok in results:
    if not ok:
        print(f"  FAIL: {name}")
sys.exit(0 if passed == len(results) else 1)
