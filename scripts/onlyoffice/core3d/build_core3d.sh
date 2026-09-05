#!/usr/bin/env bash
# build_core3d.sh — ONLYOFFICE core (OHOS arm64) 正规化构建入口
#
# 背景（2026-09-05 正规化）：core3d 重建链（gen_cmake → cmake configure → build）
# 此前只存在于会话/历史命令中，未入库；任何增量修复后无法从零复现。本脚本把
# 全链固化，并支持 --rebuild 毁灭性演练（删产物 → 全链 → libx2t.a）。
#
# 用法:
#   bash scripts/onlyoffice/core3d/build_core3d.sh            # 增量构建（CMakeLists 变自动重 configure）
#   bash scripts/onlyoffice/core3d/build_core3d.sh --rebuild  # 毁灭性重建演练（删 build/ 产物目录全链）
#
# 验收: 产物 build/core3d/build/libx2t.a（x2t 三源 + core 全链静态库；非空校验）
# 注意: 不要对 build/core3d/build 之外做 cmake clean/删除（deploy_ohos.sh 注释的旧坑：
#       hvigor clean 会连带 native 产物；本脚本只管自己的目录）。
#
# 前置（外部预编译产物，各自脚本/仓库，不在 --rebuild 范围内——从零复现时需先就位）:
#   - boost:   scripts/onlyoffice/core3d/build_boost_ohos.sh
#   - ICU:     scripts/onlyoffice/core3d/build_icu_ohos.sh
#   - cryptopp: third_party/core/Common/3dParty/cryptopp/libcryptopp.a（fetch_3dparty.sh）
#   - third_party/core 子模块已克隆（release/v9.4.0）
#   - NDK: env OHOS_NDK_ROOT 可覆盖（ohos-arm64.toolchain.cmake 默认 /apps/harmony/...）
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE3D="$ROOT/build/core3d"        # CMake source dir（gen_cmake.py 生成 CMakeLists 于此）
BD="$CORE3D/build"                 # 产物目录
TOOLCHAIN="$HERE/ohos-arm64.toolchain.cmake"

gen() {
  python3 "$HERE/gen_cmake.py"
}

if [ "${1:-}" = "--rebuild" ]; then
  echo "== 毁灭性重建：rm -rf $BD =="
  rm -rf "$BD"
  gen
  echo "== configure =="
  cmake -S "$CORE3D" -B "$BD" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DCMAKE_BUILD_TYPE=Release
elif [ ! -f "$BD/CMakeCache.txt" ]; then
  gen
  echo "== configure (首次/无缓存) =="
  cmake -S "$CORE3D" -B "$BD" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DCMAKE_BUILD_TYPE=Release
else
  # CMakeLists.txt 变更时 cmake --build 会自动重 run：无需显式配置
  gen
fi

echo "== build =="
cmake --build "$BD"

echo "== 验收 =="
if [ -s "$BD/libx2t.a" ]; then
  ls -la "$BD/libx2t.a"
else
  echo "FAIL: libx2t.a 缺失或为空" >&2
  exit 1
fi
echo "== done =="
