#!/usr/bin/env bash
# W12: 在 macos/squirrel 树上套用 squirrel-w12.patch（幂等；dev+w7 补丁须已套用）。
# 说明：当前 macos/squirrel 工作树已含 W12 改动（本补丁为可复现记录）；
# 在 pristine 克隆上依次套用 squirrel-dev.patch → squirrel-w7.patch → 本补丁即可复现。
set -euo pipefail
SQ="$(cd "$(dirname "$0")/.." && pwd)/squirrel"
PATCH="$(cd "$(dirname "$0")" && pwd)/squirrel-w12.patch"
cd "$SQ"
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  echo "applied squirrel-w12.patch"
elif git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "squirrel-w12.patch already applied"
else
  echo "warning: squirrel-w12.patch 无法干净套用（树里已有等价改动？）" >&2
fi
