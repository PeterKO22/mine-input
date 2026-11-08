#!/usr/bin/env bash
# W29 数据文件门：任何用户数据（.db/.sqlite/.jsonl/memory/userdb）不得进入版本库。
# 用户数据只允许存在于 ~/Library/Application Support/mine-input/（独立目录）。
set -euo pipefail
cd "$(dirname "$0")/.."
bad=$(git ls-files | grep -iE '\.db$|\.sqlite$|\.jsonl$|(^|/)memory/|\.userdb' || true)
if [ -n "$bad" ]; then
  echo "ERROR: 数据文件被 git 跟踪——禁止入库，立即 git rm --cached 并清理历史：" >&2
  echo "$bad" >&2
  exit 1
fi
echo "OK: 版本库无数据文件（用户数据仅存 ~/Library/Application Support/mine-input/）"
