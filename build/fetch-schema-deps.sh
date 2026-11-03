#!/usr/bin/env bash
# W1 macos-core: 拉取 ping_wubi_mixed 所需词库/配方文件（rime-wubi / rime-pinyin-simp / rime-prelude）。
# 网络纪律：GitHub API 匿名限流 → 一律 raw.githubusercontent.com，且全部 pin 到具体 commit，
# 保证可复现。产物落在 schema/deps/（连同 schema/default.yaml 一并构成 RIME 用户目录内容）。
set -euo pipefail

SCHEMA_DIR="$(cd "$(dirname "$0")/.." && pwd)/schema"
DEPS_DIR="$SCHEMA_DIR/deps"

# pinned upstream refs（2026-11-04 锁定）
RIME_WUBI_SHA="152a0d3f3efe40cae216d1e3b338242446848d07"
RIME_PINYIN_SIMP_SHA="0c6861ef7420ee780270ca6d993d18d4101049d0"
RIME_PRELUDE_SHA="082425ea0684bca36474415d4a0e8db9b016487e"

fetch() {
  local repo="$1" sha="$2" file="$3"
  local url="https://raw.githubusercontent.com/${repo}/${sha}/${file}"
  local out="$DEPS_DIR/$(basename "$file")"
  echo "fetch ${repo}@${sha:0:8} → ${out}"
  curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$out"
}

mkdir -p "$DEPS_DIR"

# rime-wubi：五笔86 码表（主 translator + 反查 target）
fetch rime/rime-wubi       "$RIME_WUBI_SHA"       "wubi86.dict.yaml"
# rime-pinyin-simp：袖珍简化字拼音码表（并联 translator + 反查词典）
fetch rime/rime-pinyin-simp "$RIME_PINYIN_SIMP_SHA" "pinyin_simp.dict.yaml"
fetch rime/rime-pinyin-simp "$RIME_PINYIN_SIMP_SHA" "pinyin_simp.schema.yaml"
# rime-prelude：预设配置（key_bindings / punctuation / symbols）
fetch rime/rime-prelude    "$RIME_PRELUDE_SHA"    "key_bindings.yaml"
fetch rime/rime-prelude    "$RIME_PRELUDE_SHA"    "punctuation.yaml"
fetch rime/rime-prelude    "$RIME_PRELUDE_SHA"    "symbols.yaml"

echo "schema deps ready → $DEPS_DIR"
ls -l "$DEPS_DIR"
