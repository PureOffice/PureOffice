#!/bin/bash
# POC-2: ICU 74.2 交叉编译到 OHOS arm64（官方 icu_android.py 结构：host cross_build -> target cross）
# 产物(仅 libicuuc + icudata archive)：build/ohos_arm64/{include,lib,data}
set -e

ICU_SRC="$(cd "$(dirname "$0")/../../.." && pwd)/third_party/core/Common/3dParty/icu/android"
CROSS_DIR=$ICU_SRC/cross_build
BUILD_DIR=$ICU_SRC/build
DST=$BUILD_DIR/ohos_arm64
NDK="${OHOS_NDK:-/apps/harmony/sdk/default/openharmony/native}"
TRIPLE=aarch64-linux-ohos
JOBS=$(nproc)

export CC="$NDK/llvm/bin/clang --target=$TRIPLE --sysroot=$NDK/sysroot"
export CXX="$NDK/llvm/bin/clang++ --target=$TRIPLE --sysroot=$NDK/sysroot"
export AR=$NDK/llvm/bin/llvm-ar
export RANLIB=$NDK/llvm/bin/llvm-ranlib
export CFLAGS="-Os -fPIC -fvisibility=hidden"
export CXXFLAGS="-Os -fPIC -fvisibility=hidden -fno-short-wchar -fno-short-enums"

# ---------- host tools (x86_64, 供 cross_build 与 icupkg genccode 等) ----------
# host 构建必须用系统编译器：撤掉交叉 CC/CXX 变量
unset CC CXX AR RANLIB CFLAGS CXXFLAGS
HOST_INSTALL=$ICU_SRC/host_install
if [ ! -d "$HOST_INSTALL/lib" ]; then
  # HOST_INSTALL 不存在 = host 尚未完整建成；CROSS_DIR 里是上次 half-built 产物，清掉
  rm -rf "$CROSS_DIR"
  mkdir -p "$CROSS_DIR" "$HOST_INSTALL"
  cd "$CROSS_DIR"
  LDFLAGS="-pthread -Wl,--gc-sections" CPPFLAGS="-Os -ffunction-sections -fdata-sections -fvisibility=hidden -fPIC -DU_USING_ICU_NAMESPACE=0 -DU_TIMEZONE=0" \
  ../icu/source/runConfigureICU Linux --prefix="$HOST_INSTALL" \
      --enable-strict=no --enable-extras=no --enable-draft=yes --enable-samples=no \
      --enable-tests=no --enable-renaming=yes --enable-icuio=no --enable-layoutex=no \
      --with-library-bits=nochange --with-library-suffix= --enable-static=yes \
      --enable-shared=no --with-data-packaging=archive
  make -j"$JOBS"
  make install
  cd - >/dev/null
fi

# ---------- target (OHOS arm64) ----------
export CC="$NDK/llvm/bin/clang --target=$TRIPLE --sysroot=$NDK/sysroot"
export CXX="$NDK/llvm/bin/clang++ --target=$TRIPLE --sysroot=$NDK/sysroot"
export AR=$NDK/llvm/bin/llvm-ar
export RANLIB=$NDK/llvm/bin/llvm-ranlib
export CFLAGS="-Os -fPIC -fvisibility=hidden"
export CXXFLAGS="-Os -fPIC -fvisibility=hidden -fno-short-wchar -fno-short-enums"
if [ -d "$DST" ]; then
  echo "DST exists, skip target build: $DST"
  ls "$DST/lib" 2>/dev/null
  exit 0
fi
TMP=$BUILD_DIR/tmp_ohos
TMP_ROOT=$BUILD_DIR/tmp_ohos_root
rm -rf "$TMP" "$TMP_ROOT"
mkdir -p "$TMP"
cd "$TMP"
$ICU_SRC/icu/source/configure --with-cross-build="$CROSS_DIR" --host="$TRIPLE" \
    --prefix="$TMP_ROOT" \
    --enable-strict=no --enable-extras=no --enable-draft=yes --enable-samples=no \
    --enable-tests=no --enable-renaming=yes --enable-icuio=no --enable-layoutex=no \
    --with-library-bits=nochange --with-library-suffix= --enable-static=yes \
    --enable-shared=no --with-data-packaging=archive
make -j"$JOBS"
mkdir -p "$DST/include" "$DST/lib" "$DST/data"
# 官方 Android 取法：libicuuc.a + stubdata/libicudata.a + icudt74l.dat（archive 数据运行时加载）
cp -r "$TMP/include"/* "$DST/include/" 2>/dev/null || true
cp -f "$TMP/lib/libicuuc.a" "$DST/lib/"
cp -f "$TMP/stubdata/libicudata.a" "$DST/lib/libicudata.a"
cp -f "$TMP/data/out/icudt74l.dat" "$DST/data/icudt74l.dat" || true
echo "---- DST ----"
ls -la "$DST/lib"
find "$DST" -name "icudt*" | head
