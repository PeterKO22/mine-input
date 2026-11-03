#!/usr/bin/env bash
# W1 macos-core: 编译 librime（macOS arm64）→ core/librime
#
# 依赖（全局安装，已在 W1 报告注明）：
#   brew install boost cmake   + Xcode 命令行工具
# 坑（2026-11-04 实测）：
#   librime Makefile 默认 MACOSX_DEPLOYMENT_TARGET=10.15，Xcode 26/27 SDK 的 libc++
#   已不支持该平台（deps/leveldb 打开 -Werror 后直接报错
#   "The selected platform is no longer supported by libc++"）。
#   本脚本统一用 MACOSX_DEPLOYMENT_TARGET=13.0（与 Squirrel 的最低系统一致）。
#   若换机器后仍报该错：rm -rf core/librime/deps/*/build 清掉 CMake 缓存再跑。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RIME_SRC="$ROOT/core/librime"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

[ -d "$RIME_SRC" ] || {
  echo "missing $RIME_SRC —— 先浅克隆："
  echo "  git clone --depth 1 https://github.com/rime/librime.git core/librime"
  echo "  cd core/librime && git submodule update --init --depth 1 --recommend-shallow"
  exit 1
}

# Boost：优先用 brew 的（portable 性差但够用）；如需便携构建，
# 改用 core/librime/install-boost.sh 并 export BOOST_ROOT=.../deps/boost
if [ -z "${BOOST_ROOT:-}" ] && ! brew --prefix boost >/dev/null 2>&1; then
  echo "boost not found; run: brew install boost" >&2; exit 1
fi

cd "$RIME_SRC"
make deps          # glog googletest leveldb marisa-trie opencc yaml-cpp → core/librime/{include,lib}
make               # Release：build/lib/librime*.dylib + build/bin/rime_*

echo "== artifacts =="
ls -l build/lib/librime*.dylib build/bin/
file build/lib/librime.1.dylib
