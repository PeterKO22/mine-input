#!/usr/bin/env bash
# W23 ci-release: 按 pin 的 commit 浅克隆第三方源码（可复现、可审计）。
#
# 仓库不入库第三方源码（core/ 与 macos/squirrel/ 均 .gitignore）；CI 与新机器用本脚本
# 按下表 pin 的 commit 拉取，任何时刻拉到的都是同一份代码。
#
# pin（2026-11-04 取自本地克隆现状，写死；改 pin = 改本脚本 + 重跑回归）：
#   rime/librime   core/librime    e930f57b5cc2eeac91aed3b6c7fe62e96f1fc8bc
#   rime/squirrel  macos/squirrel  d220b92ae7d0c916f4cce50df42d9a136668ea52
#   ↳ squirrel 子模块由 gitlink 固定（submodule update 自动落到 pin 的 commit）：
#     librime 33e78140250125871856cdc5b42ddc6a5fcd3cd4
#     plum    b1be1969f914cc005add4090631b855db00c2591
#     Sparkle 41847a58cdef7506b257591fcca6f9495df591d4
#
# 幂等：目录已在 pin 的 commit → 跳过克隆；在别的 commit → fetch pin 后切回。
# 用法：bash build/fetch-sources.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LIBRIME_URL="https://github.com/rime/librime.git"
LIBRIME_SHA="e930f57b5cc2eeac91aed3b6c7fe62e96f1fc8bc"
SQUIRREL_URL="https://github.com/rime/squirrel.git"
SQUIRREL_SHA="d220b92ae7d0c916f4cce50df42d9a136668ea52"

# clone_pinned <url> <sha> <dest> <submodules: yes|no>
clone_pinned() {
  local url="$1" sha="$2" dest="$3" subs="$4"
  if [ -d "$dest/.git" ]; then
    local head
    head="$(git -C "$dest" rev-parse HEAD)"
    if [ "$head" = "$sha" ]; then
      echo ">> $dest 已在 pin 的 commit ($sha)，跳过克隆"
    else
      echo ">> $dest HEAD=$head != pin $sha —— fetch pin 后切回"
      git -C "$dest" fetch --depth 1 origin "$sha"
      git -C "$dest" checkout --detach "$sha"
    fi
  else
    echo ">> 浅克隆 $url @ $sha → $dest"
    mkdir -p "$(dirname "$dest")"
    git init -q "$dest"
    git -C "$dest" remote add origin "$url"
    git -C "$dest" fetch --depth 1 origin "$sha"
    git -C "$dest" checkout --detach "$sha"
  fi
  # 验证：必须落在 pin 的 commit，否则拒绝继续（可复现红线）
  [ "$(git -C "$dest" rev-parse HEAD)" = "$sha" ] || {
    echo "FAIL: $dest 不在 pin 的 commit $sha" >&2; exit 1
  }
  if [ "$subs" = "yes" ]; then
    git -C "$dest" submodule update --init --recursive --depth 1 --recommend-shallow
  else
    git -C "$dest" submodule update --init --depth 1 --recommend-shallow
  fi
}

clone_pinned "$LIBRIME_URL"  "$LIBRIME_SHA"  "$ROOT/core/librime"    no
clone_pinned "$SQUIRREL_URL" "$SQUIRREL_SHA" "$ROOT/macos/squirrel"  yes

echo "== fetch-sources done =="
git -C "$ROOT/core/librime"    rev-parse HEAD
git -C "$ROOT/macos/squirrel"  rev-parse HEAD
git -C "$ROOT/macos/squirrel"  submodule status | sed 's/^/  /'
