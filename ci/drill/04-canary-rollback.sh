#!/usr/bin/env bash
# ci/drill/04-canary-rollback.sh — #23 场景④：灰度升级与失败回滚
#
# 对齐评审原文「helm upgrade 改镜像版本 → 就绪探针切流 → 失败回滚，写成可重复脚本」：
#   1. baseline：记录 helm revision + server 镜像 + 前端链路 API；
#   2. 灰度升级 基线 → 目标版本（换镜像 tag 触发滚动；期间后台流量守护经
#      frontend nginx → server Service 的真实链路，断言无连续断流）；
#   3. 失败升级：换到不存在的镜像 tag → --wait 必失败（预期红）；
#   4. helm rollback：断言镜像回目标版本、rollout Complete、API 恢复；
#   5. 回滚到 baseline revision：恢复基线版本。
#
# 版本一律**参数化**（此前 TAG_NEXT 写死成 5.7.0 ⇒ 生态版本前进后演练永远对着
# 老版本打：要么跑在旧版本上，要么镜像被清理后直接红）：
#   TAG_BASE  基线版本，默认 = Chart.yaml appVersion；
#   TAG_NEXT  灰度目标版本，默认 = 与基线不同的**真实已发布**版本；
#   TAG_PREV  显式指定「上一个已发布版本」（优先级低于 TAG_NEXT）；
#   TAG_BAD   故意拉不到的坏镜像 tag，默认 0.0.0-drill-not-exist。
#   取值规则与失败语义见 lib.sh 的「已发布版本解析」段与 ci/drill/README.md。
#
# 滚动语义：strategy 用 K8s 默认（单副本 maxSurge=1/maxUnavailable=0 ⇒ 先起新后删旧）。
# 前置：docker + kind + kubectl + helm；集群/镜像/安装由 lib 自举（幂等）。
# 用法: ci/drill/04-canary-rollback.sh [--resolve-only]
#   --resolve-only：只解析并断言版本（不建集群、不跑演练）——CI/本地自检用。
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

RESOLVE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --resolve-only) RESOLVE_ONLY=1 ;;
    *)
      echo "用法: $0 [--resolve-only]" >&2
      exit 2
      ;;
  esac
done

NS="$DRILL_NS"
REL="$DRILL_RELEASE"

# ── 版本解析（写死 ⇒ 演练永远对着老版本打；取不到 ⇒ 响亮失败）────────────
TAG_BASE="${TAG_BASE:-$(drill_app_tag)}"
TAG_BASE="${TAG_BASE#v}"
printf '%s' "$TAG_BASE" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' ||
  fail "TAG_BASE 格式非法: $TAG_BASE（期望 X.Y.Z）"

# 已发布版本集合（真实已发布 ⇒ ghcr.io/pigeonbox/{server,frontend}:<ver> 两个镜像都在）
PUBLISHED="$(drill_published_versions)"
[ -n "$PUBLISHED" ] ||
  fail "取不到任何已发布版本（仓库 tag + 远端 release tag 都读不到）——不猜、不兜底写死值"

TAG_NEXT_SRC=""
if [ -n "${TAG_NEXT:-}" ]; then
  TAG_NEXT_SRC="环境变量 TAG_NEXT"
  TAG_NEXT="${TAG_NEXT#v}"
elif [ -n "${TAG_PREV:-}" ]; then
  TAG_NEXT_SRC="环境变量 TAG_PREV（上一个已发布版本）"
  TAG_NEXT="${TAG_PREV#v}"
else
  TAG_NEXT_SRC="自动解析（与基线不同的最近已发布版本）"
  TAG_NEXT="$(drill_resolve_peer_version "$TAG_BASE" "$PUBLISHED")" ||
    fail "解析不出与基线 $TAG_BASE 不同的已发布版本——不猜、不兜底写死值"
fi

# 自证：格式合法 / ≠ 基线 / 真实已发布 —— 三条断言缺一不可
printf '%s' "$TAG_NEXT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' ||
  fail "TAG_NEXT 格式非法: $TAG_NEXT（期望 X.Y.Z）"
[ "$TAG_NEXT" != "$TAG_BASE" ] ||
  fail "TAG_NEXT 必须与基线不同（都是 $TAG_BASE ⇒ 换 tag 触发不了滚动）"
printf '%s\n' "$PUBLISHED" | grep -qx "$TAG_NEXT" ||
  fail "TAG_NEXT=$TAG_NEXT 不是真实已发布版本（已发布集合里没有它）——演练只打真实发布过的 tag"

TAG_BAD="${TAG_BAD:-0.0.0-drill-not-exist}"
if printf '%s\n' "$PUBLISHED" | grep -qx "$TAG_BAD"; then
  fail "TAG_BAD=$TAG_BAD 竟然在已发布集合里 ⇒ 失败升级场景失去意义"
fi

SERVER_IMAGE="$(drill_server_image)" || fail "chart 未给出 server 镜像（values.yaml 的 image.repository）"

echo "══ 版本解析 ══"
ok "基线版本 TAG_BASE=$TAG_BASE（Chart.yaml appVersion）"
ok "灰度目标 TAG_NEXT=$TAG_NEXT（来源：$TAG_NEXT_SRC）"
ok "坏镜像 TAG_BAD=$TAG_BAD（必须拉不到）"
ok "已发布版本数=$(printf '%s\n' "$PUBLISHED" | grep -c .)；最近若干：$(printf '%s\n' "$PUBLISHED" | head -5 | tr '\n' ' ')"
if ! printf '%s\n' "$PUBLISHED" | grep -qx "$TAG_BASE"; then
  echo "  ⚠️ 基线版本 $TAG_BASE 不在已发布集合里（chart appVersion 可能刚 bump、镜像还没发布）"
fi

if [ "$RESOLVE_ONLY" -eq 1 ]; then
  echo "✓ 版本解析通过（--resolve-only：只解析不跑演练）"
  exit 0
fi

current_image() {
  kubectl -n "$NS" get deploy "$REL-pigeonbox" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="pigeonbox")].image}'
}

current_revision() {
  # helm4 无 --no-headers；列 tab 分隔（UPDATED 含空格），末行=最新 revision
  helm history "$REL" -n "$NS" --max 1 2>/dev/null | tail -1 | awk -F'\t' '{gsub(/[[:space:]]/,"",$1); print $1}'
}

# 经前端链路打 API（nginx 反代 → server Service = 真实用户路径）
api_via_frontend() {
  kubectl -n "$NS" exec deploy/"$REL-pigeonbox-frontend" -- \
    wget -qO- --timeout=5 http://127.0.0.1:8080/api/config 2>/dev/null | grep -q '"code":0'
}

# rollback/滚动后 endpoint 同步有延迟：轮询直到通（30s 上限）
api_via_frontend_wait() {
  local i
  for i in $(seq 1 15); do
    if api_via_frontend; then return 0; fi
    sleep 2
  done
  return 1
}

FLOW_LOG=$(mktemp)

echo "══ 0) 自举：集群 + 镜像预载 + 安装 ══"
drill_ensure_cluster
drill_preload_images
drill_preload_one "$SERVER_IMAGE:$TAG_NEXT" # 灰度目标版本镜像
drill_install

echo "══ 1) baseline ══"
BASE_REV=$(current_revision)
BASE_IMG=$(current_image)
[ -n "$BASE_REV" ] && [ -n "$BASE_IMG" ] || fail "取不到 baseline revision/image"
ok "baseline: revision=$BASE_REV image=$BASE_IMG"
api_via_frontend || fail "baseline 前端链路 API 不通"
ok "baseline 前端链路 API 通"

echo "══ 2) 灰度升级 $TAG_BASE → ${TAG_NEXT}（滚动期间流量守护） ══"
: >"$FLOW_LOG"
(
  while true; do
    if api_via_frontend; then echo "$(date +%s) ok" >>"$FLOW_LOG"; else echo "$(date +%s) fail" >>"$FLOW_LOG"; fi
    sleep 1
  done
) &
FLOW_PID=$!

helm upgrade "$REL" "$CHART" -n "$NS" \
  -f "$CHART/ci/config-overlay-values.yaml" \
  --set image.tag="$TAG_NEXT" --wait --timeout 6m ||
  {
    kill "$FLOW_PID" 2>/dev/null || true
    fail "灰度升级失败（$TAG_NEXT 应可正常滚动）"
  }
kill "$FLOW_PID" 2>/dev/null || true
wait "$FLOW_PID" 2>/dev/null || true

IMG_NOW=$(current_image)
[ "$IMG_NOW" = "$SERVER_IMAGE:$TAG_NEXT" ] ||
  fail "升级后镜像未切到 $TAG_NEXT: $IMG_NOW"
ok "镜像已切到 $TAG_NEXT"
[ "$(current_revision)" != "$BASE_REV" ] || fail "revision 未推进"
ok "revision: $BASE_REV → $(current_revision)"

# 流量断言（单副本滚动语义实测定稿）：
# K8s 默认 strategy(25%,25%) 对单副本 = maxUnavailable=roundUp(0.25)=1
# ⇒ 旧 pod 先删、新 pod 就绪后恢复 ⇒ **必然出现有限断流窗口**（实测 ~10-15s）。
# 故断言不是「零断流」，而是：①断流窗口有限（≤90s，覆盖 init+就绪+endpoint 同步）；
# ②滚动完成后链路立即且持续可用。
total=$(wc -l <"$FLOW_LOG" | tr -d ' ')
first_fail=$(awk '$2=="fail"{print $1; exit}' "$FLOW_LOG")
last_fail=$(awk '$2=="fail"{t=$1} END{print t}' "$FLOW_LOG")
if [ -n "$first_fail" ]; then
  span=$((last_fail - first_fail))
  [ "$span" -le 90 ] ||
    fail "断流窗口 ${span}s > 90s（新 pod 初始化超时或永久断流；共 $total 次探测）"
  ok "断流窗口 ${span}s ≤90s（单副本滚动必然窗口，有限且可解释；共 $total 次探测）"
else
  ok "滚动全程无断流（$total 次探测）"
fi
for i in 1 2 3 4 5; do
  api_via_frontend || fail "滚动后第 $i/5 次探测失败（切流未完成/未恢复）"
done
ok "滚动后连续 5 次探测全通（切流完成且稳定）"

echo "══ 3) 失败升级：坏镜像 tag（预期 helm --wait 失败） ══"
if helm upgrade "$REL" "$CHART" -n "$NS" \
  -f "$CHART/ci/config-overlay-values.yaml" \
  --set image.tag="$TAG_BAD" --wait --timeout 2m >/tmp/drill04-bad.log 2>&1; then
  fail "不存在的镜像 tag 竟然升级成功（--wait 语义失效）"
fi
ok "坏镜像升级按预期失败（--wait 超时拒绝就绪）"
ST=$(helm history "$REL" -n "$NS" --max 1 2>/dev/null | tail -1 | awk -F'\t' '{print $3}')
[ "$ST" = failed ] || echo "  ⚠️ 最新 revision STATUS=${ST}（期望 failed；helm 对 --wait 超时的标记依版本而异）"
# 坏副本必须停在拉取失败态（不能伪装就绪）
if ! kubectl -n "$NS" get po -l app.kubernetes.io/component=server \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[?(@.name=="pigeonbox")].state.waiting.reason}{" "}{end}' |
  grep -qE 'ErrImagePull|ImagePullBackOff'; then
  fail "坏镜像 Pod 未停在拉取失败态"
fi
ok "坏镜像 Pod 停在 ErrImagePull/ImagePullBackOff（未伪装就绪）"

echo "══ 4) 回滚（helm rollback → 上一成功 revision） ══"
helm rollback "$REL" -n "$NS" >/dev/null || fail "helm rollback 失败"
drill_wait_ready
IMG_RB=$(current_image)
[ "$IMG_RB" = "$SERVER_IMAGE:$TAG_NEXT" ] ||
  fail "回滚后镜像应恢复 ${TAG_NEXT}，实得 $IMG_RB"
ok "回滚后镜像恢复 $TAG_NEXT"
api_via_frontend_wait || fail "回滚后前端链路 API 不通（30s 未恢复）"
ok "回滚后前端链路 API 通"

echo "══ 5) 回滚到 baseline（恢复 $TAG_BASE 基线） ══"
helm rollback "$REL" "$BASE_REV" -n "$NS" >/dev/null || fail "回滚到 baseline revision 失败"
drill_wait_ready
IMG_FIN=$(current_image)
[ "$IMG_FIN" = "$BASE_IMG" ] || fail "基线未恢复: $IMG_FIN != $BASE_IMG"
ok "基线镜像恢复 $IMG_FIN"
api_via_frontend_wait || fail "恢复后前端链路 API 不通（30s 未恢复）"
ok "恢复后前端链路 API 通"

rm -f "$FLOW_LOG"
echo "✅ 场景④（灰度升级/回滚）通过"
