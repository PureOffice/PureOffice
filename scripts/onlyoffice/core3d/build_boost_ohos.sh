#!/bin/bash
# POC-2: boost 1.72.0 交叉编译到 OHOS arm64
# 官方 android 分支走 boost_qt.make（Qt mkspec），OHOS 无 mkspec -> 改 b2 + NDK clang
# 需求库: system/filesystem/regex/date_time; link=static runtime-link=static（libc++_static.a 在 NDK 内）
# 输出前缀 (对齐 boost.pri 语义): 3dParty/boost/build/ohos_arm64/{include,lib}
set -e

BOOST="$(cd "$(dirname "$0")/../../.." && pwd)/third_party/core/Common/3dParty/boost/boost_1_72_0"
PREFIX="$BOOST/build/ohos_arm64"
NDK="${OHOS_NDK:-/apps/harmony/sdk/default/openharmony/native}"
TRIPLE=aarch64-linux-ohos
JOBS=$(nproc)

if [ -d "$PREFIX/lib" ]; then
  echo "already built: $PREFIX"
  ls "$PREFIX/lib"
  exit 0
fi

cd "$BOOST"
if [ ! -x ./b2 ]; then
  echo "bootstrap b2 (host tool)..."
  ./bootstrap.sh --with-toolset=gcc >/dev/null
fi

export PATH="$NDK/llvm/bin:$PATH"
./b2 -j"$JOBS" toolset=clang variant=release link=static runtime-link=static \
  threading=multi address-model=64 --prefix="$PREFIX" \
  --with-system --with-filesystem --with-regex --with-date_time \
  cxxflags="--target=$TRIPLE --sysroot=$NDK/sysroot -fPIC -fno-short-wchar -fno-short-enums" \
  linkflags="--target=$TRIPLE --sysroot=$NDK/sysroot" \
  install 2>&1 | tail -50

echo "---- boost done ----"
ls "$PREFIX/lib"
