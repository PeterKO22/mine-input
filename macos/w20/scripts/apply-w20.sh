#!/usr/bin/env bash
# W20: 在 macos/squirrel 树上套用 squirrel-w20.patch（幂等；dev+w7+linear+w12 补丁须已套用）。
# 说明：当前 macos/squirrel 工作树已含 W20 改动（本补丁为可复现记录）；
# 在 pristine 克隆上依次套用 squirrel-dev.patch → squirrel-w7.patch → squirrel-linear.patch
# → squirrel-w12.patch（macos/w12/scripts/apply-w12.sh）→ 本补丁即可复现。
# 本补丁只动 3 个文件（相对 dev+w7+linear+w12 状态的增量）：
#   Squirrel.xcodeproj/project.pbxproj      （W20 源文件/桥/Null 提案桩编入 app）
#   sources/Squirrel-Bridging-Header.h      （暴露 W20ProposalBridge 给 Swift）
#   sources/SquirrelInputController.swift   （⌥M 拦截 + 菜单项「记忆管理…」）
set -euo pipefail
SQ="$(cd "$(dirname "$0")/../.." && pwd)/squirrel"
PATCH="$(cd "$(dirname "$0")" && pwd)/squirrel-w20.patch"
cd "$SQ"
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  echo "applied squirrel-w20.patch"
elif git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "squirrel-w20.patch already applied"
else
  echo "warning: squirrel-w20.patch 无法干净套用（树里已有等价改动？）" >&2
fi
