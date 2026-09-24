#!/bin/bash
# POC-2: ICU 74.2 交叉编译到 OHOS arm64（官方 icu_android.py 结构：host cross_build -> target cross）
# 产物(仅 libicuuc + icudata archive)：build/ohos_arm64/{include,lib,data}
set -e

ICU_SRC="$(cd "$(dirname "$0")/../../.." && pwd)/third_party/core/Common/3dParty/icu/android"
CROSS_DIR=$ICU_SRC/cross_build
BUILD_DIR=$ICU_SRC/build
DST=$BUILD_DIR/ohos_arm64
# 工具链路径统一由 env.sh 探测（优先 OHOS_NDK，其次 OHOS_SDK_ROOT 下的 NDK 布局）
. "$(dirname "$0")/../env.sh" || exit 1
: "${NDK:?环境错误：未找到 OHOS NDK，请 export OHOS_NDK=/path/to/sdk/default/openharmony/native}"
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
# DST 完整的判据 = 三个库都在 **且** libicudata.a 是含数据的。
# 逐项列出的理由：只判目录存在会放行残缺产物（实测踩过——早先本脚本只拷 libicuuc，
# libicui18n.a 是当时手工放进 DST 的，删目录重建后它消失，直到 ninja 链接报
# "libicui18n.a ... missing" 才暴露）；只判 libicudata 大小则会放行缺库的树。
if [ -d "$DST" ] && [ -f "$DST/lib/libicuuc.a" ] && [ -f "$DST/lib/libicui18n.a" ] \
   && [ -f "$DST/lib/libicudata.a" ] \
   && [ "$(stat -c%s "$DST/lib/libicudata.a")" -ge 1048576 ]; then
  echo "DST exists (complete, with ICU data), skip target build: $DST"
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
# 交付件 = 三个静态库（libicuuc / libicui18n / libicudata）+ 头 + 数据文件。
# 前两个是 entry/src/main/cpp/CMakeLists.txt 的链接输入，缺一不可（早期版本只拷了
# libicuuc，libicui18n 靠手工补进 DST——重建即丢）；libicudata 由末尾的数据步骤
# 生成为**含数据**的版本（这里不再拷 stubdata 空壳）。
cp -r "$TMP/include"/* "$DST/include/" 2>/dev/null || true
cp -f "$TMP/lib/libicuuc.a" "$DST/lib/"
cp -f "$TMP/lib/libicui18n.a" "$DST/lib/"
cp -f "$TMP/data/out/icudt74l.dat" "$DST/data/icudt74l.dat" || true
echo "---- DST ----"
ls -la "$DST/lib"
find "$DST" -name "icudt*" | head

# ---------- 含真实数据的 libicudata.a（本工程必须） ----------
# 为什么必须替换：--with-data-packaging=archive 的默认产物是「stubdata 空壳（1KB）
#   + icudt74l.dat 数据文件」，数据靠**运行时**交给 ICU（官方 Android 客户端在
#   Java/native 侧做这件事）。本工程是纯静态链进 libconvertershell.so、没有任何
#   运行时加载机制——沿用空壳会让**所有需要 ICU 数据表**的编码（GBK/GB18030/Big5/
#   windows-1251…）静默失败：ucnv_open 打不开就返回空串、不报错，调用方
#   （CSVReader/TxtFile）拿到空内容后照常产出空表。UTF-8/16/32 是 ICU 内建编码、
#   不查数据表，所以症状只在非 UTF-8 源文件上出现（csv/txt 导入）。
# 做法：host 的 genccode 把 .dat 转成 C 源，目标工具链编译后打包成含数据的 .a。
#   -e icudt74 → 符号 icudt74_dat（与 ICU 的 U_ICUDATA_ENTRY_POINT 一致；注意数据
#   **文件**名 icudt74l.dat 带 l 而**符号**不带，两者不是同一个名字）。
#   -m 传一个目标架构的 .o 作参照（genccode 对 ELF 默认按 i386 生成对齐）。
DAT="$DST/data/icudt74l.dat"
LIBDATA="$DST/lib/libicudata.a"
[ -f "$DAT" ] || { echo "错误：$DAT 缺失（genccode 的输入）" >&2; exit 1; }
WORK="$BUILD_DIR/icudata_work"
rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK"
"$CROSS_DIR/bin/genccode" -d "$WORK" -m "$TMP/stubdata/stubdata.ao" \
    --skip-dll-export -e icudt74 "$DAT"
"$NDK/llvm/bin/clang" --target="$TRIPLE" --sysroot="$NDK/sysroot" \
    -Os -fPIC -fvisibility=hidden -c icudt74l_dat.c -o icudt74l_dat.o
# 先删后建：ar 的 r 是「追加/替换**同名**成员」而非重建。DST 里若残留早期拷入的
# stubdata.ao，它与数据成员**定义同一个符号**，链接器按成员顺序先选中空壳——实测
# 症状是 .so 比预期小 30MB、icudt74_dat 仍是 64 字节，而 .a 里两个成员都在。
rm -f "$LIBDATA"
"$NDK/llvm/bin/llvm-ar" rcs "$LIBDATA" icudt74l_dat.o
MEMBERS=$("$NDK/llvm/bin/llvm-ar" t "$LIBDATA")
if [ "$MEMBERS" != "icudt74l_dat.o" ]; then
  echo "错误：libicudata.a 成员异常（期望仅 icudt74l_dat.o，实际：$MEMBERS）" >&2
  exit 1
fi

# 验收断言：库须明显大于空壳（真数据 ~30MB）——否则后续所有非 UTF-8 转换静默失败
SZ=$(stat -c%s "$LIBDATA")
if [ "$SZ" -lt 1048576 ]; then
  echo "错误：libicudata.a 仍是空壳（$SZ 字节）—— ICU 数据未生成" >&2
  exit 1
fi
echo "libicudata.a（含数据）= $SZ 字节"
