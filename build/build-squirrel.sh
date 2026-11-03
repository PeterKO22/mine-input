#!/usr/bin/env bash
# W1 macos-core: 编译 Squirrel 开发版（macOS arm64）→ macos/squirrel
#
# 前置：
#   - brew install boost cmake；Xcode（含 CLI 工具）
#   - macos/squirrel 已浅克隆并 init 全部子模块（Sparkle/librime/plum）
# 产物：macos/squirrel/build/Build/Products/Release/Squirrel.app
#
# dev 隔离（编译期已打补丁，见 macos/squirrel 与 W1-REPORT.md）：
#   - bundle id / TISInputSourceID / IMK 连接名 均带 .dev，独立于用户现有 Squirrel
#   - RIME 用户目录固定 ~/Library/Rime-mine-dev（Info.plist RimeUserDir）
#   - 分布式通知名加 .dev 后缀；关闭 Sparkle 自动更新（不会升级覆盖官方版）
#   - macOS 部署目标 13.0；仅构建 arm64（不做 universal）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SQ_SRC="$ROOT/macos/squirrel"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

[ -d "$SQ_SRC" ] || {
  echo "missing $SQ_SRC —— 先浅克隆："
  echo "  git clone --depth 1 https://github.com/rime/squirrel.git macos/squirrel"
  echo "  cd macos/squirrel && git submodule update --init --recursive --depth 1 --recommend-shallow"
  exit 1
}

cd "$SQ_SRC"
# 确保子模块齐备（幂等）
git submodule update --init --recursive --depth 1 --recommend-shallow

# 应用 dev 隔离补丁（bundle id/TIS/连接名 .dev、RIME 用户目录、通知名、Sparkle 关更、
# copy-rime-binaries 容错）；已应用则跳过，保证脚本可重跑
if git apply --check "$ROOT/build/squirrel-dev.patch" 2>/dev/null; then
  git apply "$ROOT/build/squirrel-dev.patch"
  echo "applied build/squirrel-dev.patch"
elif git apply --reverse --check "$ROOT/build/squirrel-dev.patch" 2>/dev/null; then
  echo "build/squirrel-dev.patch already applied"
else
  echo "warning: squirrel-dev.patch 无法干净套用（树里已有手动改动？继续构建）" >&2
fi

# make release 会依次：构建 librime（macos/squirrel/librime，pinned 子模块）→ 拉 plum 数据
# → 拷 opencc 数据 → 构建 Sparkle.framework → xcodebuild Squirrel
make release ARCHS='arm64'

APP="$SQ_SRC/build/Build/Products/Release/Squirrel.app"
echo "== artifact =="
ls -ld "$APP"
plutil -p "$APP/Contents/Info.plist" | grep -E "CFBundleIdentifier|CFBundleName|TISInputSourceID|RimeUserDir|InputMethodConnectionName" || true
echo "下一步：bash build/install-dev.sh 安装到 ~/Library/Input Methods"
