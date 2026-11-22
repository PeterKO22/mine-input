#!/usr/bin/env bash
# W32: 在 macos/squirrel 树上套用 squirrel-w32.patch（幂等；dev+w7+w12+w20+w26+w27+w28+w29+w30+w31 补丁链须已套用）。
# 说明：当前 macos/squirrel 工作树已含 W32 改动（本补丁为可复现记录）；
# 在 pristine 克隆上依次套用 squirrel-dev.patch → squirrel-w7.patch → squirrel-w12.patch
# → squirrel-w20.patch → squirrel-w26.patch → squirrel-w27.patch → squirrel-w28.patch
# → …（w29/w30/w31 记录补丁）→ 本补丁即可复现。
# 改动内容：resources/Info.plist W12C1Screen <true/>→<false/>（屏幕上下文默认 OFF）。
set -euo pipefail
SQ="$(cd "$(dirname "$0")/../.." && pwd)/squirrel"
PATCH="$(cd "$(dirname "$0")/.." && pwd)/squirrel-w32.patch"
cd "$SQ"
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  echo "applied squirrel-w32.patch"
elif git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "squirrel-w32.patch already applied"
else
  echo "warning: squirrel-w32.patch 无法干净套用（树里已有等价改动？）" >&2
fi
