#!/usr/bin/env bash
# W15 路径 B：librime-on-Android 最小构建（裁剪 deps：无 glog/无 gtest/无插件）。
# 前置：bash engine/build/pathB-fetch-ndk.sh（NDK r21，华为云镜像）
# 依赖裁剪（相对上游 deps.mk）：
#   - glog       跳过（-DENABLE_LOGGING=OFF）
#   - googletest 跳过（-DBUILD_TEST=OFF）
#   - leveldb / yaml-cpp / marisa-trie / opencc  交叉编译（NDK toolchain）
#   - boost      只需 headers + libboost_regex.a（源码 tarball 自编，archives.boost.io）
# 产物：engine/poc/pathB/sysroot/lib/librime.so（arm64-v8a）+ bin/rime_api_console（Android 可执行）
# 日志：engine/poc/pathB/logs/build-librime.log
set -euo pipefail

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
PB="$ENGINE/poc/pathB"
NDK="$PB/ndk/android-ndk-r21"
TOOLCHAIN="$(cd "$(dirname "$0")" && pwd)/android-arfix.toolchain.cmake"  # 官方 toolchain + AR 修复
export W15_NDK_ROOT="$NDK"
PREBUILT="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
CLANG="$PREBUILT/bin/clang"
CLANGXX="$PREBUILT/bin/clang++"
SYSROOT="$PREBUILT/sysroot"
AR="$PREBUILT/bin/llvm-ar"
RANLIB="$PREBUILT/bin/llvm-ranlib"
PREFIX="$PB/sysroot"
LOGS="$PB/logs"
BOOST_VER=1_83_0   # tarball 名下划线版；URL 里 release/1.83.0 是点号版
BOOSTROOT="$PB/boost_$BOOST_VER"

mkdir -p "$LOGS" "$PREFIX"
exec > >(tee "$LOGS/build-librime.log") 2>&1

[ -x "$CLANG" ] || { echo "missing NDK —— 先跑 bash engine/build/pathB-fetch-ndk.sh"; exit 1; }

echo "== 环境 =="
"$CLANG" --version | head -2
TARGET_FLAGS="--target=aarch64-linux-android29 --sysroot=$SYSROOT"

# ---------------------------------------------------------------- [1] boost regex
if [ ! -f "$PREFIX/lib/libboost_regex.a" ]; then
  if [ ! -d "$BOOSTROOT" ]; then
    echo "== 获取 boost ${BOOST_VER}（archives.boost.io）=="
    curl -sL -o "$PB/boost_$BOOST_VER.tar.gz" \
      "https://archives.boost.io/release/1.83.0/source/boost_${BOOST_VER}.tar.gz"
    tar xzf "$PB/boost_$BOOST_VER.tar.gz" -C "$PB"
  fi
  echo "== 编译 boost::regex（静态，Android arm64）=="
  mkdir -p "$PREFIX/lib"
  OBJS="$PB/boost-objs"; rm -rf "$OBJS"; mkdir -p "$OBJS"
  for f in "$BOOSTROOT"/libs/regex/src/*.cpp; do
    case "$(basename "$f")" in
      icu.cpp) continue ;;   # 不启用 ICU
    esac
    echo "  cxx $(basename "$f")"
    "$CLANGXX" $TARGET_FLAGS -std=c++14 -fPIC -O2 \
      -I"$BOOSTROOT" -c "$f" -o "$OBJS/$(basename "$f").o"
  done
  "$AR" rcs "$PREFIX/lib/libboost_regex.a" "$OBJS"/*.o
fi
ls -la "$PREFIX/lib/libboost_regex.a"

# ---------------------------------------------------------------- [2] 四个 CMake dep
# NDK r21 的 x86_64 工具在 Rosetta 2 下偶发 libc++abi 崩溃（typed operator new 竞态），
# 表现为 llvm-ar/llvm-ranlib 偶发 Subprocess aborted；增量产物仍在，重试即过 → 统一重试 3 次。
build_retry() {
  local i
  for i in 1 2 3; do
    if "$@"; then return 0; fi
    echo "!! 命令失败（疑似 Rosetta 偶发崩溃），第 ${i} 次重试：$*"
    sleep 2
  done
  return 1
}

build_dep() { # name dir extra_cmake_args...
  local name="$1" dir="$2"; shift 2
  if [ -f "$PREFIX/.stamp-${name}" ]; then echo "== ${name} 已装（.stamp-${name}），跳过 =="; return 0; fi
  echo "== 构建 ${name}（→ ${PREFIX}）=="
  # 旧 build 目录的 link.txt 可能烤死了崩溃的 aarch64-linux-android-ar 包装器 → 每次干净重配
  rm -rf "$dir/build-android"
  cmake -S "$dir" -B "$dir/build-android" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    "$@"
  build_retry cmake --build "$dir/build-android" --target install -j"$(sysctl -n hw.ncpu)"
  touch "$PREFIX/.stamp-${name}"
}

RIME="$PB/librime"
[ -d "$RIME/deps/leveldb" ] || { echo "missing librime clone/submodules"; exit 1; }

build_dep leveldb "$RIME/deps/leveldb" \
  -DLEVELDB_BUILD_BENCHMARKS=OFF -DLEVELDB_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
build_dep yaml-cpp "$RIME/deps/yaml-cpp" \
  -DYAML_CPP_BUILD_CONTRIB=OFF -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF -DYAML_CPP_STATIC_DEFINE=ON
build_dep marisa-trie "$RIME/deps/marisa-trie" \
  -DBUILD_TESTING=OFF -DENABLE_TOOLS=OFF

# opencc 特例：`install` 会构建 data/*.ocd2，需要**宿主**工具 opencc_dict（交叉编译出的是 ARM 二进制，
# 无法在 macOS 运行）→ 只建 libopencc 静态库 + 头文件手工落位。本 schema 不挂 simplifier，
# 运行期不需要 opencc 数据；设备端要用时可从 Trime assets 拿 opencc/ 数据（W15 已验证该来源）。
if [ -f "$PREFIX/.stamp-opencc" ]; then
  echo "== opencc 已装（.stamp-opencc），跳过 =="
else
  echo "== 构建 opencc（→ ${PREFIX}，仅库，跳过 data/*.ocd2）=="
  rm -rf "$RIME/deps/opencc/build-android"
cmake -S "$RIME/deps/opencc" -B "$RIME/deps/opencc/build-android" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
  -DBUILD_SHARED_LIBS=OFF
build_retry cmake --build "$RIME/deps/opencc/build-android" --target libopencc -j"$(sysctl -n hw.ncpu)"
mkdir -p "$PREFIX/include/opencc" "$PREFIX/lib"
find "$RIME/deps/opencc/build-android" -name 'libopencc.a' -exec cp {} "$PREFIX/lib/" \;
cp "$RIME/deps/opencc/src/"*.h "$RIME/deps/opencc/src/"*.hpp "$PREFIX/include/opencc/"
  find "$RIME/deps/opencc/build-android" -name 'Opencc_Export.h' -exec cp {} "$PREFIX/include/opencc/" \;
  touch "$PREFIX/.stamp-opencc"
fi
ls "$PREFIX/lib/libopencc.a" "$PREFIX/include/opencc" | head

# ---------------------------------------------------------------- [2.5] libc++ filesystem 补库
# 实证：NDK r21 的 libc++_static.a 不含任何 std::filesystem 符号（llvm-nm 计数=0），
# 而 librime 需要（boost::dll 的 std::filesystem 路径 + rime/lever/user_dict_manager.cc）。
# 对策：编译 LLVM 9（与 r21 的 clang 9 匹配）libcxx/src/filesystem/{operations,directory_iterator,int128_builtins}.cpp
# 成 libcpfs.a，随 librime 链接。upstream 的 apple_availability.h 仅被 include、无宏被使用（grep 实证）→ 空 stub。
CPFS="$PB/cpfs-src/up"
if [ ! -f "$PREFIX/lib/libcpfs.a" ]; then
  echo "== 构建 libcpfs.a（libc++ filesystem 补库）=="
  mkdir -p "$CPFS/src" "$CPFS/include"
  for f in operations.cpp directory_iterator.cpp int128_builtins.cpp filesystem_common.h; do
    [ -s "$CPFS/src/$f" ] || curl -sL -o "$CPFS/src/$f" \
      "https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-9.0.0/libcxx/src/filesystem/$f"
  done
  [ -s "$CPFS/include/apple_availability.h" ] || \
    echo '/* stub: upstream includes this header but uses no macro from it; not needed for Android */' \
      > "$CPFS/include/apple_availability.h"
  for f in operations.cpp directory_iterator.cpp int128_builtins.cpp; do
    "$CLANGXX" $TARGET_FLAGS -std=c++17 -O2 -fPIC -c "$CPFS/src/$f" -o "$CPFS/src/$f.o"
  done
  "$AR" rcs "$PREFIX/lib/libcpfs.a" "$CPFS/src/operations.cpp.o" "$CPFS/src/directory_iterator.cpp.o" "$CPFS/src/int128_builtins.cpp.o"
fi
ls -la "$PREFIX/lib/libcpfs.a"

# ---------------------------------------------------------------- [3] librime（最小配置）
echo "== 构建 librime（Android arm64，ENABLE_LOGGING=OFF，无插件/无测试）=="
rm -rf "$RIME/build-android"
cmake -S "$RIME" -B "$RIME/build-android" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC=ON \
  -DBUILD_TEST=OFF -DBUILD_SAMPLE=OFF -DENABLE_LOGGING=OFF \
  -DBoost_NO_BOOST_CMAKE=TRUE -DBOOST_ROOT="$BOOSTROOT" -DBOOST_INCLUDEDIR="$BOOSTROOT" \
  -DBoost_INCLUDE_DIR="$BOOSTROOT" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_CXX_STANDARD_LIBRARIES="$PREFIX/lib/libcpfs.a" \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
build_retry cmake --build "$RIME/build-android" -j"$(sysctl -n hw.ncpu)"

echo "== 产物核验 =="
find "$RIME/build-android" -name 'librime*.so' -o -name 'rime_api_console' -o -name 'rime_deployer' | while read -r f; do
  file "$f"
done
echo "== pathB-build-librime done =="
