# ONLYOFFICE core POC-2 —— OHOS arm64 交叉编译工具链（BiSheng/libc++ musl）
# 用法: cmake -DCMAKE_TOOLCHAIN_FILE=this -DCMAKE_INSTALL_PREFIX=<prefix> ..
# 注意: SDK 6.1.0 NDK clang，target=aarch64-linux-ohos
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# NDK 根：-DOHOS_NDK_ROOT=... 或环境变量 OHOS_NDK_ROOT 提供（build_core3d.sh 把
# env.sh 的探测结果传进来；换机/新 SDK **不改本文件**——2026-09-05 审查补）。
# 不内置默认路径：公开仓库里写死某台开发机的 SDK 布局，换机后会静默指向不存在的
# 目录（配置期就报错，比编译期报「找不到 clang」好定位）。
# 必须声明为「try_compile 平台变量」：CMake 的编译器自检会另起一个嵌套工程，
# 其 cache 是全新的——-D 传进来的 OHOS_NDK_ROOT 不会自动继承，导致嵌套那趟
# 走到下面的 FATAL_ERROR（实测：Clang identification 通过后 ABI 检测崩）。
# 声明后 CMake 会把它显式透传给嵌套工程（CMake >= 3.6 的官方机制）。
set(CMAKE_TRY_COMPILE_PLATFORM_VARIABLES OHOS_NDK_ROOT)
set(OHOS_NDK_ROOT "$ENV{OHOS_NDK_ROOT}" CACHE PATH "OHOS NDK root")
if(NOT OHOS_NDK_ROOT)
  message(FATAL_ERROR
    "OHOS_NDK_ROOT 未设置。二选一：\n"
    "  · cmake -DOHOS_NDK_ROOT=<sdk>/openharmony/native ...（build_core3d.sh 会自动传）\n"
    "  · export OHOS_NDK=<sdk>/openharmony/native 后 source scripts/onlyoffice/env.sh")
endif()

set(TOOLCHAIN_TRIPLE "aarch64-linux-ohos")

set(CMAKE_C_COMPILER   "${OHOS_NDK_ROOT}/llvm/bin/clang")
set(CMAKE_CXX_COMPILER "${OHOS_NDK_ROOT}/llvm/bin/clang++")
set(CMAKE_AR           "${OHOS_NDK_ROOT}/llvm/bin/llvm-ar")
set(CMAKE_RANLIB       "${OHOS_NDK_ROOT}/llvm/bin/llvm-ranlib")
set(CMAKE_STRIP        "${OHOS_NDK_ROOT}/llvm/bin/llvm-strip")
set(CMAKE_NM           "${OHOS_NDK_ROOT}/llvm/bin/llvm-nm")
set(CMAKE_LINKER       "${OHOS_NDK_ROOT}/llvm/bin/ld.lld")

set(CMAKE_C_FLAGS_INIT   "--target=${TOOLCHAIN_TRIPLE} --sysroot=${OHOS_NDK_ROOT}/sysroot")
set(CMAKE_CXX_FLAGS_INIT "--target=${TOOLCHAIN_TRIPLE} --sysroot=${OHOS_NDK_ROOT}/sysroot")

set(CMAKE_FIND_ROOT_PATH "${OHOS_NDK_ROOT}/sysroot" "${OHOS_NDK_ROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)   # 不找 host 程序
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# POC-2 断言：统一先编静态库，链路全部 static，避免运行时 so 分发
set(CMAKE_BUILD_TYPE Release)
