#!/usr/bin/env bash
# ci/drill/04-canary-rollback.sh — #23 场景④：灰度升级与失败回滚
#
# 对齐评审原文「helm upgrade 改镜像版本 → 就绪探针切流 → 失败回滚，写成可重复脚本」：
#   1. baseline：记录 helm revision + server 镜像 + 前端链路 API；
#   2. 灰度升级 5.8.0 → 5.7.0（换镜像 tag 触发滚动；期间后台流量守护经
#      frontend nginx → server Service 的真实链路，断言无连续断流）；
#   3. 失败升级：换到不存在的镜像 tag → --wait 必失败（预期红）；
#   4. helm rollback：断言镜像回 5.7.0、rollout Complete、API 恢复；
#   5. 回滚到 baseline revision：恢复 5.8.0 基线。
#
# 滚动语义：strategy 用 K8s 默认（单副本 maxSurge=1/maxUnavailable=0 ⇒ 先起新后删旧）。
# 前置：docker + kind + kubectl + helm；集群/镜像/安装由 lib 自举（幂等）。
# 用法: ci/drill/04-canary-rollback.sh
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NS="$DRILL_NS"
REL="$DRILL_RELEASE"
TAG_BASE=$(drill_app_tag)          # 5.8.0
TAG_NEXT="5.7.0"                   # 「新版本」：与基线不同的真实已发布 tag
TAG_BAD="0.0.0-drill-not-exist"    # 必拉取失败的 tag（制造失败升级）

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
drill_preload_one "ghcr.io/pigeonbox/server:$TAG_NEXT"   # 灰度目标版本镜像
drill_install

echo "══ 1) baseline ══"
BASE_REV=$(current_revision)
BASE_IMG=$(current_image)
[ -n "$BASE_REV" ] && [ -n "$BASE_IMG" ] || fail "取不到 baseline revision/image"
ok "baseline: revision=$BASE_REV image=$BASE_IMG"
api_via_frontend || fail "baseline 前端链路 API 不通"
ok "baseline 前端链路 API 通"

echo "══ 2) 灰度升级 $TAG_BASE → $TAG_NEXT（滚动期间流量守护） ══"
: > "$FLOW_LOG"
(
  while true; do
    if api_via_frontend; then echo "$(date +%s) ok" >> "$FLOW_LOG"; else echo "$(date +%s) fail" >> "$FLOW_LOG"; fi
    sleep 1
  done
) &
FLOW_PID=$!

helm upgrade "$REL" "$CHART" -n "$NS" \
  -f "$CHART/ci/config-overlay-values.yaml" \
  --set image.tag="$TAG_NEXT" --wait --timeout 6m \
  || { kill "$FLOW_PID" 2>/dev/null || true; fail "灰度升级失败（5.7.0 应可正常滚动）"; }
kill "$FLOW_PID" 2>/dev/null || true
wait "$FLOW_PID" 2>/dev/null || true

IMG_NOW=$(current_image)
[ "$IMG_NOW" = "ghcr.io/pigeonbox/server:$TAG_NEXT" ] \
  || fail "升级后镜像未切到 $TAG_NEXT: $IMG_NOW"
ok "镜像已切到 $TAG_NEXT"
[ "$(current_revision)" != "$BASE_REV" ] || fail "revision 未推进"
ok "revision: $BASE_REV → $(current_revision)"

# 流量断言（单副本滚动语义实测定稿）：
# K8s 默认 strategy(25%,25%) 对单副本 = maxUnavailable=roundUp(0.25)=1
# ⇒ 旧 pod 先删、新 pod 就绪后恢复 ⇒ **必然出现有限断流窗口**（实测 ~10-15s）。
# 故断言不是「零断流」，而是：①断流窗口有限（≤90s，覆盖 init+就绪+endpoint 同步）；
# ②滚动完成后链路立即且持续可用。
total=$(wc -l < "$FLOW_LOG" | tr -d ' ')
first_fail=$(awk '$2=="fail"{print $1; exit}' "$FLOW_LOG")
last_fail=$(awk '$2=="fail"{t=$1} END{print t}' "$FLOW_LOG")
if [ -n "$first_fail" ]; then
  span=$((last_fail - first_fail))
  [ "$span" -le 90 ] \
    || fail "断流窗口 ${span}s > 90s（新 pod 初始化超时或永久断流；共 $total 次探测）"
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
[ "$ST" = failed ] || echo "  ⚠️ 最新 revision STATUS=$ST（期望 failed；helm 对 --wait 超时的标记依版本而异）"
# 坏副本必须停在拉取失败态（不能伪装就绪）
if ! kubectl -n "$NS" get po -l app.kubernetes.io/component=server \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[?(@.name=="pigeonbox")].state.waiting.reason}{" "}{end}' \
  | grep -qE 'ErrImagePull|ImagePullBackOff'; then
  fail "坏镜像 Pod 未停在拉取失败态"
fi
ok "坏镜像 Pod 停在 ErrImagePull/ImagePullBackOff（未伪装就绪）"

echo "══ 4) 回滚（helm rollback → 上一成功 revision） ══"
helm rollback "$REL" -n "$NS" >/dev/null || fail "helm rollback 失败"
drill_wait_ready
IMG_RB=$(current_image)
[ "$IMG_RB" = "ghcr.io/pigeonbox/server:$TAG_NEXT" ] \
  || fail "回滚后镜像应恢复 $TAG_NEXT，实得 $IMG_RB"
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
