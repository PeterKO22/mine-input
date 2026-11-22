#!/usr/bin/env bash
# W31: 在 macos/squirrel 树上套用 squirrel-w31.patch（幂等；dev+w7+w12+w20+w26+w27+w28 补丁链须已套用）。
# 说明：当前 macos/squirrel 工作树已含 W31 改动（本补丁为可复现记录）；
# 在 pristine 克隆上依次套用 squirrel-dev.patch → squirrel-w7.patch → squirrel-w12.patch
# → squirrel-w20.patch → squirrel-w26.patch → squirrel-w27.patch → squirrel-w28.patch
# → 本补丁即可复现。
# 改动内容：SquirrelInputController.w7ShowRecorderLine()（W31 记录员模式速记稿面板行）+
# project.pbxproj 编入 ../w7/src/W7RecorderTranscript.swift（W31 分段转写会话）。
set -euo pipefail
SQ="$(cd "$(dirname "$0")/../.." && pwd)/squirrel"
PATCH="$(cd "$(dirname "$0")/.." && pwd)/squirrel-w31.patch"
cd "$SQ"
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  echo "applied squirrel-w31.patch"
elif git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "squirrel-w31.patch already applied"
else
  echo "warning: squirrel-w31.patch 无法干净套用（树里已有等价改动？）" >&2
fi
