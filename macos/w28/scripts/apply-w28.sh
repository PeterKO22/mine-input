#!/usr/bin/env bash
# W28: 在 macos/squirrel 树上套用 squirrel-w28.patch（幂等；dev+w7+w12+w20+w26+w27 补丁须已套用）。
# 说明：当前 macos/squirrel 工作树已含 W28 改动（本补丁为可复现记录）；
# 在 pristine 克隆上依次套用 squirrel-dev.patch → squirrel-w7.patch → squirrel-w12.patch
# → squirrel-w20.patch → squirrel-w26.patch → squirrel-w27.patch → 本补丁即可复现。
# 改动内容：SquirrelInputController.w7ShowLockedHint()（锁定态面板文案）+
# project.pbxproj 编入 ../w7/src/W7PttLockMachine.swift（W28 锁定态状态机）。
set -euo pipefail
SQ="$(cd "$(dirname "$0")/../.." && pwd)/squirrel"
PATCH="$(cd "$(dirname "$0")/.." && pwd)/squirrel-w28.patch"
cd "$SQ"
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  echo "applied squirrel-w28.patch"
elif git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "squirrel-w28.patch already applied"
else
  echo "warning: squirrel-w28.patch 无法干净套用（树里已有等价改动？）" >&2
fi
