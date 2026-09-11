#!/usr/bin/env bash
# ONLYOFFICE 鸿蒙真机回归（P0）：case 矩阵 → 启动验收态 → 采集日志 → 标签断言 → PASS/FAIL
#
# 用法（在仓库任意位置执行；设备必须显式指定——沿用 deploy_ohos.sh 约定）：
#   OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/tests/regression.sh            # 全部 case
#   OHOS_DEV=... bash scripts/onlyoffice/tests/regression.sh --list                    # 列 case（不连设备）
#   OHOS_DEV=... bash scripts/onlyoffice/tests/regression.sh --case open-word          # 单个 case
#   OHOS_DEV=... bash scripts/onlyoffice/tests/regression.sh --record [--case <id>]    # 只采集不判定（加 case 前采基线用）
#
# 输入：scripts/onlyoffice/tests/cases.tsv（字段说明见该文件头）
# 产物：scripts/onlyoffice/tests/out/<runid>/<id>.log（本 case 增量日志）
#                                          <id>.jpeg（本 case 结束时刻截图，人工复核用）
#                                          summary.txt（汇总）
# 退出码：0=全部 PASS；1=有 FAIL；2=用法/环境错误
#
# 判据原理：页面日志统一落 files/dir/web_console.txt（EditorPage.ets onConsole）。
# 注意该文件的写入侧是 APPEND、但**文档页初始化时会用 TRUNC 重开**（每次启动清空
# 重建）——故不按字节偏移切增量（偏移在清空后不成立，曾致采到空日志）：跑前显式
# 清空一次，采集全量 = 本 case 独有。断言 = 固定子串匹配（grep -F）：必须出现项缺
# 一即 FAIL，禁止出现项命中即 FAIL。不依赖任何探针新增——判的是既有链路自己打的点。
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TESTS="$ROOT/scripts/onlyoffice/tests"
CASES="$TESTS/cases.tsv"
HDC="${OHOS_HDC:-/apps/harmony/sdk/default/openharmony/toolchains/hdc}"
DEV="${OHOS_DEV:-}"
BUNDLE=app.fuqidian.pureoffice
LOG="/data/app/el2/100/base/$BUNDLE/haps/entry/files/web_console.txt"

MODE=run          # run | record
ONLY_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE=list ;;
    --record) MODE=record ;;
    --case) shift; ONLY_ID="${1:-}" ;;
    *) echo "未知参数：$1（用法见脚本头）" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f "$CASES" ]; then
  echo "错误：case 清单缺失：$CASES" >&2
  exit 2
fi

if [ "$MODE" = list ]; then
  printf '%-16s %-52s %s\n' ID M7ARGS 说明
  grep -v '^#' "$CASES" | grep -v '^[[:space:]]*$' | while IFS='|' read -r id args tmo term exp forb desc; do
    printf '%-16s %-52s %s\n' "$id" "$args" "$desc"
  done
  exit 0
fi

if [ -z "$DEV" ]; then
  echo "错误：未指定目标设备。用法：OHOS_DEV=<ip:port> bash $0" >&2
  exit 2
fi
if ! "$HDC" list targets 2>/dev/null | grep -qF "$DEV"; then
  echo "错误：设备 $DEV 不在 hdc list targets 中" >&2
  "$HDC" list targets >&2
  exit 2
fi

RUNID="$(date +%Y%m%d_%H%M%S)"
OUT="$TESTS/out/$RUNID"
mkdir -p "$OUT"
TMPLOG="$OUT/.live.log"

# —— 设备侧日志：跑前清空 → 采集全量（本 case 独有；清空依据见脚本头注释）——
reset_log() { "$HDC" -t "$DEV" shell ": > $LOG" >/dev/null 2>&1 || true; }
pull_all() { "$HDC" -t "$DEV" shell "cat $LOG 2>/dev/null || true" | tr -d '\r' > "$1"; }
snap() {
  "$HDC" -t "$DEV" shell "snapshot_display -f /data/local/tmp/rt_shot.jpeg" >/dev/null 2>&1 || true
  "$HDC" -t "$DEV" file recv /data/local/tmp/rt_shot.jpeg "$1" >/dev/null 2>&1 || true
}
# 轮询日志直到出现结束判据；返回 0=命中，1=超时。判据为空时固定等 5s（不阻塞判定）。
# 轮询在**设备侧**判（只回传 HIT/MISS）——避免每 3s 回传整份日志（长 case 拖慢）。
# 注意：hdc shell **恒返回本地 rc=0**（不回传远端退出码，已实测）——判据只能取回传
# 文本，不能写 if hdc shell "grep -q ..."（那样恒真 → 秒"命中" → 全 case 假 FAIL）。
wait_terminal() {
  local term="$1" tmo="$2"
  if [ -z "$term" ]; then sleep 5; return 0; fi
  local end=$(( $(date +%s) + tmo )) r
  while [ "$(date +%s)" -lt "$end" ]; do
    r=$("$HDC" -t "$DEV" shell "grep -qF '$term' $LOG 2>/dev/null && echo HIT || echo MISS" | tr -d '\r\n ')
    if [ "$r" = HIT ]; then return 0; fi
    sleep 3
  done
  return 1
}

RESULT_IDS=(); RESULT_ST=(); RESULT_NOTE=(); RESULT_SEC=()

run_case() {
  local id="$1" args="$2" tmo="$3" term="$4" exp="$5" forb="$6" desc="$7"
  local t0; t0=$(date +%s)
  echo "---- [$id] $desc"
  echo "     触发：m7args '$args'（超时 ${tmo}s，判据 '$term'）"

  "$HDC" -t "$DEV" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
  sleep 1
  reset_log
  sleep 1
  "$HDC" -t "$DEV" shell "aa start -a EntryAbility -b $BUNDLE --ps m7args '$args'" >/dev/null

  local timedout=0
  wait_terminal "$term" "$tmo" || timedout=1
  pull_all "$OUT/$id.log"
  snap "$OUT/$id.jpeg"

  local sec=$(( $(date +%s) - t0 ))
  if [ "$MODE" = record ]; then
    RESULT_IDS+=("$id"); RESULT_ST+=("RECORD"); RESULT_NOTE+=("采集 ${sec}s → out/$id.log"); RESULT_SEC+=("$sec")
    echo "     采集完成（${sec}s）；未判定"
    return 0
  fi

  # —— 断言：必须出现项缺一即 FAIL；禁止出现项命中即 FAIL ——
  local missing="" hitforbid="" p
  if [ -n "$exp" ]; then
    IFS=',' read -ra _e <<< "$exp"
    for p in "${_e[@]}"; do
      [ -z "$p" ] && continue
      grep -qF -- "$p" "$OUT/$id.log" || missing="$missing $p"
    done
  fi
  if [ -n "$forb" ]; then
    IFS=',' read -ra _f <<< "$forb"
    for p in "${_f[@]}"; do
      [ -z "$p" ] && continue
      grep -qF -- "$p" "$OUT/$id.log" && hitforbid="$hitforbid $p"
    done
  fi

  local st="PASS" note=""
  if [ "$timedout" = 1 ]; then st="FAIL"; note="超时未出现判据 '$term'"$'\n'; fi
  if [ -n "$missing" ]; then st="FAIL"; note="$note 缺必须项:$missing"$'\n'; fi
  if [ -n "$hitforbid" ]; then st="FAIL"; note="$note 命中禁止项:$hitforbid"$'\n'; fi
  [ -z "$note" ] && note="OK"
  note="$note（${sec}s，日志 out/$id.log）"

  RESULT_IDS+=("$id"); RESULT_ST+=("$st"); RESULT_NOTE+=("$note"); RESULT_SEC+=("$sec")
  if [ "$st" = PASS ]; then
    echo "     PASS（${sec}s）"
  else
    echo "     FAIL（${sec}s）"
    printf '%s\n' "$note" | sed 's/^/       /' | grep -v '^ *$'
  fi
}

echo "== ONLYOFFICE 回归（$MODE）== 设备 $DEV  产物 $OUT"
while IFS='|' read -r id args tmo term exp forb desc; do
  case "$id" in ''|'#'*) continue ;; esac
  if [ -n "$ONLY_ID" ] && [ "$id" != "$ONLY_ID" ]; then continue; fi
  run_case "$id" "$args" "${tmo:-120}" "$term" "$exp" "$forb" "$desc"
done < <(grep -v '^[[:space:]]*$' "$CASES")

if [ "${#RESULT_IDS[@]}" -eq 0 ]; then
  echo "错误：没有匹配的 case（--case '$ONLY_ID' 拼错？用 --list 看可用 id）" >&2
  exit 2
fi

# —— 汇总 ——
{
  echo "== 回归汇总（$RUNID，设备 $DEV）=="
  npass=0
  for i in "${!RESULT_IDS[@]}"; do
    printf '%-8s %-16s %s\n' "${RESULT_ST[$i]}" "${RESULT_IDS[$i]}" "${RESULT_NOTE[$i]}"
    if [ "${RESULT_ST[$i]}" = PASS ]; then npass=$((npass + 1)); fi
  done
  echo "总计：$npass/${#RESULT_IDS[@]} PASS"
} | tee "$OUT/summary.txt"

# 退出码：record 恒 0；run 有 FAIL 则 1
rm -f "$TMPLOG"
if [ "$MODE" = run ]; then
  for st in "${RESULT_ST[@]}"; do [ "$st" = PASS ] || exit 1; done
fi
exit 0
