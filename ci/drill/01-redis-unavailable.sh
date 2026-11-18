#!/usr/bin/env bash
# ci/drill/01-redis-unavailable.sh — #23 场景①：共享 Redis 不可用
#
# 断言（评审点：「降级行为可解释，不雪崩」）：
#   1. baseline：API 可服务；
#   2. 突然终止（force-delete redis Pod）→ Deployment 自动重建并回 Ready；
#   3. 持续不可用（scale 到 0）60s 窗口：
#      a) server/frontend 不重启（restarts=0，不 CrashLoop 雪崩）；
#      b) API 读路径仍可服务（进程内配置缓存降级）+ 匿名分享降级成功（断供不阻断寄件）；
#      c) 日志尽力观察：窗口内见 redis 连接失败信号则 ✓（pool 后台日志非周期保证）；
#      d) liveness 探针失败次数 < failureThreshold(3)（不触发杀 pod 循环）；
#   4. 恢复（scale 回 1）→ redis 回 Ready，API 持续正常，全程 server 零重启。
#
# 前置：docker + kind + kubectl + helm；集群/镜像/安装由 lib 自举（幂等）。
# 用法: ci/drill/01-redis-unavailable.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NS="$DRILL_NS"
REDIS_DEPLOY="$DRILL_RELEASE-pigeonbox-redis"

log_info "══ 0) 自举：集群 + 镜像预载 + 安装 ══"
drill_ensure_cluster
drill_preload_images
drill_install

log_info "══ 1) baseline ══"
drill_api_ok "baseline"

log_info "══ 2) 突然终止：force-delete redis Pod → 自动重建 ══"
redis_pod=$(kubectl -n "$NS" get po -l app.kubernetes.io/name=pigeonbox-redis \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "$redis_pod" ] || fail "找不到 redis Pod"
kubectl -n "$NS" delete po "$redis_pod" --force --grace-period=0 >/dev/null
ok "已 force-delete ${redis_pod}（模拟突然终止）"
# RS 重建有延迟：先等新 Pod 出现（kubectl wait 对空 selector 会直接报错）
# ⚠️ 等价替换：原为「for i in $(seq 1 60) + sleep 3」（最多 180s）⇒ DELAY=3/BACKOFF=1。
#   原实现**超时后不判失败**（由下一条 kubectl wait 的 fail 判红）⇒ `|| true` 保持该语义。
SHELLKIT_RETRY_DELAY=3 SHELLKIT_RETRY_BACKOFF=1 retry 60 kubectl -n "$NS" get po \
  -l app.kubernetes.io/name=pigeonbox-redis -o name 2>/dev/null | grep -q . || true
kubectl -n "$NS" wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=pigeonbox-redis --timeout=180s >/dev/null ||
  fail "redis Pod 未在 180s 内自动重建回 Ready"
ok "redis Pod 自动重建回 Ready"

log_info "══ 3) 持续不可用：scale 到 0，观察 60s ══"
restarts_before=$(server_restart_count)
kubectl -n "$NS" scale deploy "$REDIS_DEPLOY" --replicas=0 >/dev/null
fault_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ok "redis 已下线（scale=0），观察 60s…"
sleep 60

# a) 不雪崩：server/frontend 零重启且仍 Running
restarts_after=$(server_restart_count)
[ "$restarts_after" = "$restarts_before" ] ||
  fail "server 在 redis 下线期间重启了: $restarts_before → ${restarts_after}（雪崩）"
if kubectl -n "$NS" get po -l app.kubernetes.io/instance=fcb \
  -o jsonpath='{range .items[*]}{.status.phase}{" "}{end}' | grep -q Pending; then
  fail "有 Pod 进入 Pending（资源/调度异常）"
fi
ok "server 零重启（restarts=${restarts_after}），无 Pending Pod"

# b) 读路径降级仍可服务（配置走进程内缓存，不因 redis 断供而 5xx）
drill_api_ok "redis 下线期间"

# b2) 业务面降级可用：匿名分享（限流计数等 redis 路径失败被忽略，不阻断寄件）
share_out=$(kubectl -n "$NS" exec "$(server_pod)" -c pigeonbox -- \
  sh -c 'wget -qO- --timeout=8 --header="Content-Type: application/json" \
  --post-data="{\"text\":\"drill-redis-outage\",\"expire_value\":1,\"expire_style\":\"day\",\"require_auth\":false}" \
  http://127.0.0.1:12345/share/text/' 2>&1) || fail "redis 下线时匿名分享请求失败: $share_out"
echo "$share_out" | grep -q '"code":0' ||
  fail "redis 下线时匿名分享未降级成功（业务被 redis 断供阻断）: ${share_out:0:200}"
ok "匿名分享降级成功（redis 断供不阻断寄件面）"

# c) 降级可观测：故障窗口内出现过 redis 连接失败日志则 ✓。
# 注意：pool 后台 dial 日志由 go-redis 连接池维护任务驱动，**不保证周期出现**
# （实测仅故障初期集中输出，之后静默）——故此为尽力观察项，不作硬失败条件。
if kubectl -n "$NS" logs "$(server_pod)" -c pigeonbox --since=4m 2>/dev/null |
  grep -qiE 'redis.*(failed to dial|connection refused|timeout)'; then
  ok "server 日志有 redis 连接失败信号（降级可观测）"
else
  log_warn "  ⚠️ 窗口内未见 redis 失败日志（pool 后台日志非周期保证，非静默假活证据）"
fi

# d) liveness 失败次数 < failureThreshold(3)：不进入杀 pod 循环
live_fails=$(drill_unhealthy_since "$fault_at" "Liveness")
[ "$live_fails" -lt 3 ] ||
  fail "下线窗口内 liveness 失败 $live_fails 次 ≥ 3（会触发重启循环）"
ok "窗口内 liveness 失败 $live_fails 次 < 3（未触发重启循环）"

log_info "══ 4) 恢复：scale 回 1 ══"
kubectl -n "$NS" scale deploy "$REDIS_DEPLOY" --replicas=1 >/dev/null
kubectl -n "$NS" rollout status deploy "$REDIS_DEPLOY" --timeout=180s >/dev/null ||
  fail "redis 恢复后未回 Ready"
ok "redis 回 Ready"
drill_api_ok "恢复后"
[ "$(server_restart_count)" = "$restarts_before" ] ||
  fail "恢复后 server 重启次数与故障前不一致（全程应零重启）"
ok "全程 server 零重启"

log_ok "✅ 场景①（Redis 不可用）通过"
