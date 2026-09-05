# ONLYOFFICE core POC-2 —— OHOS arm64 交叉编译工具链（BiSheng/libc++ musl）
# 用法: cmake -DCMAKE_TOOLCHAIN_FILE=this -DCMAKE_INSTALL_PREFIX=<prefix> ..
# 注意: SDK 6.1.0 NDK clang，target=aarch64-linux-ohos
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# NDK 根：环境变量 OHOS_NDK_ROOT 优先（换机/新 SDK 用 env 覆盖，勿改本文件——2026-09-05 审查补）
set(OHOS_NDK_ROOT "$ENV{OHOS_NDK_ROOT}" CACHE PATH "OHOS NDK root")
if(NOT OHOS_NDK_ROOT)
  set(OHOS_NDK_ROOT "/apps/harmony/sdk/default/openharmony/native" CACHE PATH "OHOS NDK root" FORCE)
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
