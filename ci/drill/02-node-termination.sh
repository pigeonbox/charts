#!/usr/bin/env bash
# ci/drill/02-node-termination.sh — #23 场景②：节点终止（单副本 admin/服务面）
#
# 本机 docker VM 仅 3.8GB，多节点 kind 集群不可行——用单节点上的两段等价验证：
#   A. 优雅驱逐（kubectl drain = 节点维护/驱逐语义）：
#      - 断言：业务 pod 被驱逐后 **Pending 无处调度**（单点无副本可逃 = 评审点名的
#        「单副本 admin 面单」脆弱性实证）+ 服务断流；
#      - uncordon 恢复 → 断言 RS 自动重建、服务自愈；
#   B. 突然终止（docker stop kind 节点容器 = 节点掉电）：
#      - 断言：集群失联（kubectl 不可达）；
#      - docker start → 断言节点回 Ready、pod 回 Running、API 自愈。
#
# 多副本 + PDB 的运行时驱逐验证（replicaCount=2 + 内置 DB）需多节点/更多内存，
# 留 CI/真机（PDB 渲染与 selector 断言已由 lint-test 覆盖，PR#29）。
#
# 前置：docker + kind + kubectl + helm；集群/镜像/安装由 lib 自举（幂等）。
# 用法: ci/drill/02-node-termination.sh
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NS="$DRILL_NS"
REL="$DRILL_RELEASE"

api_ok() {
  kubectl -n "$NS" exec deploy/"$REL-pigeonbox-frontend" -- \
    wget -qO- --timeout=5 http://127.0.0.1:8080/api/config 2>/dev/null | grep -q '"code":0'
}

echo "══ 0) 自举：集群 + 镜像预载 + 安装 ══"
drill_ensure_cluster
drill_preload_images
drill_install

NODE=$(kind get nodes --name "$DRILL_CLUSTER" | head -1)
[ -n "$NODE" ] || fail "取不到 kind 节点名"

echo "══ 1) baseline ══"
api_ok || fail "baseline 前端链路 API 不通"
ok "baseline API 通（单节点 $NODE，业务 pod 全在其上）"

echo "══ A) 优雅驱逐：drain 节点 ══"
# 单节点 drain：evict 后无节点可调度 ⇒ pod Pending。drain 会等待 pod 消失而卡住，
# 用 timeout 截断（eviction 动作在卡住前已发生）。
timeout 45 kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force \
  >/tmp/drill02-drain.log 2>&1 || true
grep -qE 'drained|Cannot drain' /tmp/drill02-drain.log \
  && ok "drain 已执行（卡住截断属预期：单节点等 pod 消失）" \
  || echo "  ⚠️ drain 输出未见 drained 标记，继续按 pod 状态断言"

# 断言①：业务 pod Pending（无处可去 = 单点脆弱性实证）
phase=$(kubectl -n "$NS" get po -l app.kubernetes.io/component=server \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo Missing)
[ "$phase" = Pending ] \
  || fail "驱逐后 server pod 应为 Pending（无副本可逃），实得 $phase"
ok "驱逐后 server pod = Pending（单节点无处迁移，脆弱性实证）"

# 断言②：服务断流（无就绪副本）
if api_ok; then
  fail "节点驱逐期间服务仍可用（预期断流——除非有未预期的多副本）"
fi
ok "节点驱逐期间服务断流（单副本的真实后果）"

echo "══ A-恢复) uncordon → 自愈 ══"
kubectl uncordon "$NODE" >/dev/null
kubectl -n "$NS" rollout status deploy/"$REL-pigeonbox" --timeout=180s >/dev/null \
  || uncordon_ok=1
for i in $(seq 1 30); do
  if api_ok; then break; fi
  sleep 2
done
api_ok || fail "uncordon 后服务未自愈（120s）"
phase=$(kubectl -n "$NS" get po -l app.kubernetes.io/component=server \
  -o jsonpath='{.items[0].status.phase}')
[ "$phase" = Running ] || fail "恢复后 server pod 应 Running，实得 $phase"
ok "uncordon 后 RS 自动重建、服务自愈（pod=Running、API 通）"

echo "══ B) 突然终止：docker stop 节点容器 ══"
docker stop "$NODE" >/dev/null
sleep 5
if kubectl get nodes >/dev/null 2>&1; then
  docker start "$NODE" >/dev/null 2>&1 || true
  fail "节点容器 stop 后集群仍可达（预期失联）"
fi
ok "节点容器已停止、集群失联（掉电语义）"

echo "══ B-恢复) docker start → 自愈 ══"
docker start "$NODE" >/dev/null
for i in $(seq 1 60); do
  if kubectl get nodes 2>/dev/null | grep -q "$NODE.*Ready"; then break; fi
  sleep 3
done
kubectl get nodes 2>/dev/null | grep -q "$NODE.*Ready" \
  || fail "节点未在 180s 内回 Ready"
ok "节点回 Ready"

kubectl -n "$NS" rollout status deploy/"$REL-pigeonbox" --timeout=180s >/dev/null \
  || fail "节点恢复后 server 未回 Ready"
for i in $(seq 1 30); do
  if api_ok; then break; fi
  sleep 2
done
api_ok || fail "节点恢复后服务未自愈（120s）"
ok "节点恢复后服务自愈（API 通）"

echo "✅ 场景②（节点终止）通过"
