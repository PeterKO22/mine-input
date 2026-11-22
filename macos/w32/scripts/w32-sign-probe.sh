#!/usr/bin/env bash
# W32 签名验收探针：断言装机副本的 designated requirement 是
# identifier + certificate 锚（非 cdhash）——TCC 授权跨重装存活的机制证明。
#
# 用法：bash macos/w32/scripts/w32-sign-probe.sh [Squirrel-dev.app 路径]
#（默认 ~/Library/Input Methods/Squirrel-dev.app；装机后运行。
#  也可对任意副本运行，如构建产物/scratch 签名副本。）
#
# 判定：
#   PASS = designated 需求含 `identifier "im.rime.inputmethod.Squirrel.dev"` 与
#          `certificate leaf = H"..."`（或 certificate/anchor 类锚），且不含 cdhash；
#   FAIL = 仍是 cdhash 锚（ad-hoc）或缺 identifier（TCC 授权会随重装失效、反复弹窗）。
set -uo pipefail

APP="${1:-$HOME/Library/Input Methods/Squirrel-dev.app}"
BUNDLE_ID="im.rime.inputmethod.Squirrel.dev"

if [ ! -d "$APP" ]; then
  echo "FAIL: 找不到 app：$APP（先 bash build/install-dev.sh 装机）" >&2
  exit 1
fi

DR="$(codesign -dr- "$APP" 2>&1)"
echo "$DR"

fail=0
echo "$DR" | grep -q "identifier \"$BUNDLE_ID\"" \
  && echo "PASS: designated 含 identifier \"$BUNDLE_ID\"" \
  || { echo "FAIL: designated 缺 identifier \"$BUNDLE_ID\""; fail=1; }
echo "$DR" | grep -Eq "certificate (leaf|anchor|root) = H\"" \
  && echo "PASS: designated 含 certificate 锚（授权可跨重装存活）" \
  || { echo "FAIL: designated 缺 certificate 锚"; fail=1; }
if echo "$DR" | grep -q "cdhash"; then
  echo "FAIL: designated 是 cdhash 锚（ad-hoc 签名——TCC 授权随重装失效，W27 弹窗风暴根因）"
  echo "  修复：bash scripts/make-dev-cert.sh && bash build/install-dev.sh"
  fail=1
else
  echo "PASS: designated 非 cdhash 锚"
fi

if [ "$fail" -eq 0 ]; then
  echo "== W32 签名探针 ALL PASS（${APP}）=="
else
  echo "== W32 签名探针 FAILED（${APP}）=="
fi
exit "$fail"
