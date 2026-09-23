#!/usr/bin/env bash
# 开发环境**集中**配置（**入库**——本文件不得出现任何本机私有路径或设备地址）。
#
# 用法：在需要 hdc / hvigorw / SDK 路径的脚本里 source 本文件（放在 ROOT 定义之后）：
#     . "$(dirname "$0")/env.sh"           # scripts/onlyoffice/*.sh
#     . "$(dirname "$0")/../env.sh"        # 子目录脚本（tests/、core3d/）
# 脚本里改用它导出的变量：HDC / HVIGORW / NDK / OHOS_SDK_ROOT / OHOS_CJK_FONTS_DIR
#
# 取值优先级：**显式环境变量 > 探测（PATH / SDK 环境变量 / 通用安装布局） > 报错**。
# 为什么不再写死默认值：公开仓库里的默认值等于把某台开发机的目录布局当成约定，
# 换机器/换 SDK 版本就会静默指向不存在的路径（报错比静默跑错要好）。
#
# 可覆盖项：OHOS_HDC / OHOS_HVIGORW / OHOS_SDK_ROOT / OHOS_CJK_FONTS_DIR / OHOS_NDK
# 注意：设备地址（OHOS_DEV）**不在这里给默认值**——必须由调用方显式指定，
#       否则多设备环境下会静默装到错的机器上（deploy_ohos.sh 头部有同样说明）。
# 注意：本文件会被 source，**不要**在这里 set -e / exit（执行流归调用方）。

# —— 1. hdc：显式 > PATH ——
if [ -z "${OHOS_HDC:-}" ]; then
  OHOS_HDC="$(command -v hdc 2>/dev/null || true)"
fi

# —— 2. SDK 根：显式 > DevEco/命令行工具环境变量 > 通用安装布局 ——
if [ -z "${OHOS_SDK_ROOT:-}" ]; then
  for _cand in "${DEVECO_SDK_HOME:-}" "${COMMAND_LINE_TOOLS_HOME:-}/sdk/default" \
               "${TOOL_HOME:-}/sdk/default" "$HOME/command-line-tools/sdk/default" \
               "/opt/harmony/sdk/default"; do
    if [ -n "$_cand" ] && [ -d "$_cand/openharmony" ]; then
      OHOS_SDK_ROOT="$_cand"; break
    fi
  done
fi
# 反推：hdc 恒定位于 <sdk>/openharmony/toolchains/hdc —— 「hdc 进了 PATH、但没有任何
# SDK 环境变量」的机器（DevEco 安装器只加 PATH）靠这条兜住，无需写死任何路径。
if [ -z "${OHOS_SDK_ROOT:-}" ] && [ -n "${OHOS_HDC:-}" ]; then
  case "$OHOS_HDC" in
    */openharmony/toolchains/hdc)
      OHOS_SDK_ROOT="${OHOS_HDC%/openharmony/toolchains/hdc}" ;;
  esac
fi
# 反向补：SDK 根已知但 hdc 不在 PATH 时，用 SDK 内布局
if [ -z "${OHOS_HDC:-}" ] && [ -n "${OHOS_SDK_ROOT:-}" ] \
   && [ -x "$OHOS_SDK_ROOT/openharmony/toolchains/hdc" ]; then
  OHOS_HDC="$OHOS_SDK_ROOT/openharmony/toolchains/hdc"
fi
if [ ! -x "${OHOS_HDC:-}" ]; then
  echo "环境错误：找不到 hdc。请二选一：" >&2
  echo "  · 把 hdc 加进 PATH；或" >&2
  echo "  · export OHOS_HDC=/path/to/sdk/default/openharmony/toolchains/hdc" >&2
  # 用 return 而非 exit：source 时把控制权交回调用方（调用方按 `. env.sh || exit 1` 处理），
  # 这样本文件也能在交互 shell 里安全 source 做排查。
  return 1
fi

# —— 3. hvigorw：显式 > PATH > DevEco 命令行工具布局 ——
if [ -z "${OHOS_HVIGORW:-}" ]; then
  OHOS_HVIGORW="$(command -v hvigorw 2>/dev/null || true)"
  for _cand in "${COMMAND_LINE_TOOLS_HOME:-}/bin/hvigorw" "${TOOL_HOME:-}/bin/hvigorw" \
               "$HOME/command-line-tools/bin/hvigorw"; do
    if [ -z "$OHOS_HVIGORW" ] && [ -x "$_cand" ]; then OHOS_HVIGORW="$_cand"; break; fi
  done
fi

# —— 4. CJK 字体源目录（SDK previewer 自带字库；make_cjk_font_src.sh 消费）——
if [ -z "${OHOS_CJK_FONTS_DIR:-}" ] && [ -n "${OHOS_SDK_ROOT:-}" ] \
   && [ -d "$OHOS_SDK_ROOT/hms/previewer/resources/fonts" ]; then
  OHOS_CJK_FONTS_DIR="$OHOS_SDK_ROOT/hms/previewer/resources/fonts"
fi

# —— 5. OHOS NDK（core3d 四个构建脚本消费）——
if [ -z "${OHOS_NDK:-}" ] && [ -n "${OHOS_SDK_ROOT:-}" ] \
   && [ -d "$OHOS_SDK_ROOT/openharmony/native" ]; then
  OHOS_NDK="$OHOS_SDK_ROOT/openharmony/native"
fi

# 导出给子进程（hvigorw 等）；未探测到的项保持为空，由调用方按需判空
export OHOS_SDK_ROOT OHOS_HDC OHOS_HVIGORW OHOS_CJK_FONTS_DIR OHOS_NDK
export HDC="$OHOS_HDC"
# 用 if 而非 `[ -n x ] && export ...`：后者在 set -e 的调用方里，判断为假时整条
# AND-OR 列表返回非零 → **source 当场中断调用脚本**（bash 的经典坑）
if [ -n "${OHOS_HVIGORW:-}" ]; then export HVIGORW="$OHOS_HVIGORW"; fi
if [ -n "${OHOS_NDK:-}" ]; then export NDK="$OHOS_NDK"; fi
:
