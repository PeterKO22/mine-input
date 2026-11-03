# W15 路径 B：NDK r21 工具链包装。
# 问题实证：r21 套件里 `aarch64-linux-android-ar`/`-ranlib`（CMAKE_AR/RANLIB 默认值）是 x86_64
# 包装器，在 Rosetta 2 下必崩（libc++abi: typed operator new… Subprocess aborted）；
# 同套件的 `llvm-ar`/`llvm-ranlib` 正常。此包装在官方 toolchain include 之后强制改写两个工具路径。
# 用法：W15_NDK_ROOT=<ndk 根> cmake -DCMAKE_TOOLCHAIN_FILE=<本文件> ...
set(_W15_NDK "$ENV{W15_NDK_ROOT}")
set(_W15_PREBUILT "${_W15_NDK}/toolchains/llvm/prebuilt/darwin-x86_64")
include("${_W15_NDK}/build/cmake/android.toolchain.cmake")
set(CMAKE_AR "${_W15_PREBUILT}/bin/llvm-ar")
set(CMAKE_RANLIB "${_W15_PREBUILT}/bin/llvm-ranlib")
set(CMAKE_AR "${_W15_PREBUILT}/bin/llvm-ar" CACHE FILEPATH "Archiver" FORCE)
set(CMAKE_RANLIB "${_W15_PREBUILT}/bin/llvm-ranlib" CACHE FILEPATH "Ranlib" FORCE)
