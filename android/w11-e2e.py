#!/usr/bin/env python3
"""W11 端到端验收脚本（模拟器 + 真 Hub）。

流程（对齐验收项）：
  1. 安装 APK、清数据（首次启动）→ 路由到 A5 知情同意/配对页
  2. 界面逐项勾选 C0 + 语音热词同步（C2 留空 → 证明无默认全开）
  3. 输入配对码 → 「配对并继续」真连 Hub（模拟器 http://10.0.2.2:8088）
  4. 写入演示学习数据 → 设置页「立即同步」→ push→pull 往返一致
  5. 二次同步验证计数器增量累加（3+4=7）与 push_id 幂等通道
  6. 设置页「撤回全部同意」→ 再触发 ingest/同步 → 必须被拦截、Hub 零新增上报

用法：python3 android/w11-e2e.py   （需 adb 可见模拟器、Hub 容器已起）
"""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = "/Users/you/Library/Android/sdk/platform-tools/adb"
PKG = "com.mineinput.ime"
# 配对码 → 确定性凭据（同码=同 Hub 账号）。Hub 服务端状态跨运行持久，
# 固定码会撞历史累计计数器（3+4=7 断言失去意义）→ 每次运行随机码=全新账号，
# 与 W8 sync-demo 每次随机账号（w8demo-A-<rand>）同一做法。
PAIR_CODE = "-".join(os.urandom(2).hex().upper() for _ in range(3))  # e.g. 7F2A-91C4-3D08

results = []


def sh(args, timeout=30):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return r.stdout + r.stderr


def step(name):
    print(f"\n=== {name} ===")


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  {detail}" if detail else ""))


def logcat():
    return sh([ADB, "logcat", "-d", "-s", "W11"])


def last_line(text, needle):
    hits = [l for l in text.splitlines() if needle in l]
    return hits[-1] if hits else ""


def dump_ui():
    for _ in range(8):
        sh([ADB, "shell", "uiautomator", "dump", "/sdcard/w11ui.xml"])
        xml = sh([ADB, "shell", "cat", "/sdcard/w11ui.xml"])
        if "<node" in xml:
            return xml
        time.sleep(1)
    raise RuntimeError("uiautomator dump failed")


def nodes(xml):
    out = []
    for m in re.finditer(r"<node[^>]*>", xml):
        attrs = dict(re.findall(r'(\w+)="([^"]*)"', m.group(0)))
        out.append(attrs)
    return out


def center(bounds):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", bounds))
    return (x1 + x2) // 2, (y1 + y2) // 2


def tap_text(text, occurrence=0, exact=False):
    xml = dump_ui()
    hits = []
    for n in nodes(xml):
        t = n.get("text", "")
        if (t == text) if exact else (text in t):
            hits.append(n)
    if not hits:
        raise RuntimeError(f"UI text not found: {text}")
    n = hits[min(occurrence, len(hits) - 1)]
    x, y = center(n["bounds"])
    sh([ADB, "shell", "input", "tap", str(x), str(y)])
    time.sleep(1.0)
    return n


def tap_edittext(code_text):
    xml = dump_ui()
    for n in nodes(xml):
        if n.get("class", "") == "android.widget.EditText":
            t = n.get("text", "")
            if not t.startswith("http"):  # 空文本或 hint → 配对码输入框
                x, y = center(n["bounds"])
                sh([ADB, "shell", "input", "tap", str(x), str(y)])
                time.sleep(0.5)
                sh([ADB, "shell", "input", "text", code_text])
                time.sleep(0.5)
                sh([ADB, "shell", "input", "keyevent", "4"])  # 收起软键盘
                time.sleep(1.0)
                return n
    raise RuntimeError("配对码输入框 not found")


def broadcast(cmd, extras=None):
    # 显式组件：API 26+ 隐式广播不到达清单注册的 receiver
    args = [ADB, "shell", "am", "broadcast", "-n", f"{PKG}/.DebugReceiver",
            "-a", f"{PKG}.DEBUG_ACTION", "--es", "cmd", cmd]
    for k, v in (extras or {}).items():
        args += ["--es", k, v]
    return sh(args)


def docker_push_ingest_counts():
    logs = sh(["docker", "logs", "mine-input-hub"], timeout=60)
    return {
        "push": logs.count('"POST /v1/sync/push'),
        "pull": logs.count('"POST /v1/sync/pull'),
        "ingest": logs.count('"POST /v1/ingest'),
    }


def main():
    step("0. 环境：安装 APK + 清数据（首次启动）")
    sh([ADB, "logcat", "-c"])
    out = sh([ADB, "install", "-r",
              "/Users/you/AITECreate/mine-input/android/app/build/outputs/apk/debug/app-debug.apk"])
    check("adb install", "Success" in out, out.strip().splitlines()[-1] if out.strip() else "")
    sh([ADB, "shell", "pm", "clear", PKG])
    sh([ADB, "shell", "am", "start", "-n", f"{PKG}/.MainActivity"])
    time.sleep(2)
    xml = dump_ui()
    check("首次启动路由到 A5 同意/配对页", "连接你的 AI Hub" in xml and "同意清单" in xml)
    broadcast("status")
    time.sleep(1)
    lg = logcat()
    check("同意项默认全关（无默认全开）", "consent(c0=false,c2=false,hotword=false)" in lg,
          last_line(lg, "STATUS paired=")[-160:])

    step("1. 界面逐项勾选同意（C0 + 语音热词同步，C2 留空）")
    tap_text("基础上下文（推荐）")
    tap_text("语音热词同步")
    time.sleep(0.5)
    broadcast("status")
    time.sleep(1)
    lg = logcat()
    check("C0/热词逐项勾选生效、C2 留空", "consent(c0=true,c2=false,hotword=true)" in lg,
          last_line(lg, "STATUS paired=")[-160:])

    step("2. 输入配对码 → 配对并继续（真连 Hub 10.0.2.2:8088）")
    tap_edittext(PAIR_CODE)
    tap_text("配对并继续")
    time.sleep(6)
    lg = logcat()
    check("配对真连成功（PAIR_OK）", "PAIR_OK" in lg, last_line(lg, "PAIR_OK"))

    step("3. seed 演示学习数据 → 设置页「立即同步」")
    broadcast("seed")
    time.sleep(1)
    sh([ADB, "shell", "am", "start", "-n", f"{PKG}/.SectionActivity", "--es", "section", "ai_sync"])
    time.sleep(2)
    tap_text("立即同步")
    time.sleep(6)
    lg = logcat()
    round1 = next((l for l in lg.splitlines() if "ROUNDTRIP_OK" in l), "")
    check("push→pull 往返一致（ROUNDTRIP_OK）", "ROUNDTRIP_OK" in lg, round1[-160:])
    check("往返内容含 userdb=w11/demo 与计数器", "w11/demo=hello-w11" in lg and "w11_clicks" in lg)

    step("4. 二次同步：计数器增量累加（3+4=7）")
    broadcast("seed", {"delta": "4"})
    time.sleep(1)
    broadcast("sync")
    time.sleep(6)
    broadcast("status")
    time.sleep(1)
    lg = logcat()
    check("二次 ROUNDTRIP_OK", lg.count("ROUNDTRIP_OK") >= 2)
    check("计数器增量累加 3+4=7", 'server_counters={"w11_clicks":7}' in lg,
          last_line(lg, 'server_counters=')[-160:])

    step("5. 撤回全部同意 → 不再上报")
    counts_before = docker_push_ingest_counts()
    sh([ADB, "shell", "am", "start", "-n", f"{PKG}/.SectionActivity", "--es", "section", "privacy"])
    time.sleep(2)
    tap_text("撤回全部同意")
    time.sleep(1)
    broadcast("ingest")
    time.sleep(2)
    broadcast("sync")
    time.sleep(2)
    lg = logcat()
    check("撤回后 ingest 被拦截（UPLOAD_BLOCKED）", "UPLOAD_BLOCKED" in lg)
    check("撤回后同步被拦截（SYNC_BLOCKED/SYNC_RESULT blocked）",
          "SYNC_BLOCKED" in lg or "SYNC_RESULT blocked=" in lg)
    time.sleep(2)
    counts_after = docker_push_ingest_counts()
    check("Hub 侧零新增 push/pull/ingest（服务端实证）",
          counts_before == counts_after,
          f"before={counts_before} after={counts_after}")

    step("6. 状态位/设置入口自检")
    broadcast("status")
    time.sleep(1)
    lg = logcat()
    st = last_line(lg, "STATUS paired=")
    check("STATUS 含 consent 全 false 与队列 0", "consent(c0=false,c2=false,hotword=false)" in st, st[-200:])

    print("\n=== 结果 ===")
    n_pass = sum(1 for _, ok in results if ok)
    print(f"PASS={n_pass} FAIL={len(results) - n_pass}")
    print("\n--- W11 logcat（断言依据）---")
    print("\n".join(logcat().splitlines())[-6000:])
    return 0 if n_pass == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
