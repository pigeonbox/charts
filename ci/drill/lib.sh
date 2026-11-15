#!/usr/bin/env bash
# ci/drill/lib.sh — kind 演练公共库（#23 第③块：灰度回滚 + 故障三场景）
#
# 被 01~04 场景脚本 source。提供：集群创建、镜像预载、chart 安装、断言原语。
# 与 .github/workflows/lint-test.yml 的 kind 冒烟同一套约定：
#   - 镜像 tag 取 Chart.yaml appVersion 剥 v；
#   - 预载用 docker save + ctr import --platform <本机架构>（多架构 OCI index 直接
#     kind load 会因 --all-platforms 缺另一平台 blob 而失败，见 workflow 注释）。
#
# 环境变量（均有默认值，本地与 CI 通用）：
#   DRILL_CLUSTER  kind 集群名        默认 pb-drill
#   DRILL_NS       命名空间            默认 fcb-ci
#   DRILL_RELEASE  helm release 名     默认 fcb
set -euo pipefail

DRILL_CLUSTER="${DRILL_CLUSTER:-pb-drill}"
DRILL_NS="${DRILL_NS:-fcb-ci}"
DRILL_RELEASE="${DRILL_RELEASE:-fcb}"
DRILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DRILL_DIR/../.." && pwd)"
CHART="$REPO_ROOT/charts/pigeonbox"

fail() { echo "::error::$*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

drill_arch() {
  local a; a=$(uname -m)
  case "$a" in x86_64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo "$a" ;; esac
}

drill_app_tag() {
  awk '/^appVersion:/{gsub(/"/,"",$2); sub(/^v/,"",$2); print $2; exit}' "$CHART/Chart.yaml"
}

# 集群：不存在则创建；存在则复用（幂等）
drill_ensure_cluster() {
  if ! kind get clusters 2>/dev/null | grep -qx "$DRILL_CLUSTER"; then
    echo "→ 创建 kind 集群 $DRILL_CLUSTER"
    kind create cluster --name "$DRILL_CLUSTER" --wait 120s || fail "kind 集群创建失败"
  else
    echo "→ 复用已有 kind 集群 $DRILL_CLUSTER"
  fi
  kubectl config use-context "kind-$DRILL_CLUSTER" >/dev/null
}

# 镜像预载：docker pull（本平台）→ 节点内 ctr import pin 平台（幂等，重复导入无害）
drill_preload_images() {
  local tag; tag=$(drill_app_tag)
  local node; node=$(kind get nodes --name "$DRILL_CLUSTER" | head -1)
  local ref
  for ref in "ghcr.io/pigeonbox/server:$tag" "ghcr.io/pigeonbox/frontend:$tag" "redis:7-alpine"; do
    docker pull -q "$ref" >/dev/null || fail "镜像拉取失败: $ref"
    docker save "$ref" | docker exec -i "$node" \
      ctr --namespace=k8s.io images import --platform "linux/$(drill_arch)" \
        --digests --snapshotter=overlayfs - >/dev/null \
      || fail "镜像预载失败: $ref"
    ok "预载 $ref"
  done
}

# 安装/升级到最新 chart（与 workflow 冒烟同参）并等 Ready。
# 带重试：本机 docker 端口转发偶发 TLS EOF（kubectl 手动重试即通），不重试会假红。
drill_install() {
  local i
  for i in 1 2 3; do
    if helm upgrade --install "$DRILL_RELEASE" "$CHART" -n "$DRILL_NS" --create-namespace \
      -f "$CHART/ci/config-overlay-values.yaml" --wait --timeout 6m; then
      break
    fi
    [ "$i" -lt 3 ] || fail "helm install/upgrade 连续 3 次失败"
    echo "  ! helm 瞬时失败，10s 后重试 ($i/2)"; sleep 10
  done
  drill_wait_ready
}

# 用 label 选中两平面（deployment 名随 fullname 变，selector 与 workflow 冒烟同款）
drill_wait_ready() {
  local t="${1:-180s}" i
  for i in 1 2 3; do
    if kubectl -n "$DRILL_NS" rollout status deploy -l app.kubernetes.io/component=server --timeout="$t" >/dev/null \
      && kubectl -n "$DRILL_NS" rollout status deploy -l app.kubernetes.io/name=pigeonbox-frontend --timeout="$t" >/dev/null; then
      return 0
    fi
    [ "$i" -lt 3 ] || fail "deployment 未在重试后回 Ready"
    echo "  ! rollout 等待失败，10s 后重试 ($i/2)"; sleep 10
  done
}

server_pod() {
  kubectl -n "$DRILL_NS" get po -l app.kubernetes.io/component=server \
    -o jsonpath='{.items[0].metadata.name}'
}

# server 重启次数（雪崩判据：故障窗口内必须为 0）
server_restart_count() {
  kubectl -n "$DRILL_NS" get po -l app.kubernetes.io/component=server \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="pigeonbox")].restartCount}'
}

# API 断言：server 容器内打本机 /api/config，必须 HTTP 通且业务码 code:0
drill_api_ok() {
  local label="${1:-api}"
  local out
  out=$(kubectl -n "$DRILL_NS" exec "$(server_pod)" -c pigeonbox -- \
    sh -c 'wget -qO- --timeout=8 http://127.0.0.1:12345/api/config' 2>&1) \
    || fail "[$label] /api/config 请求失败: $out"
  echo "$out" | grep -q '"code":0' || fail "[$label] /api/config 业务码非 0: ${out:0:200}"
  ok "[$label] /api/config 业务码 0"
}

# 指定时刻之后、匹配关键字的 Unhealthy 事件数（时间比较为 RFC3339 字符串序，同格式可比）
# 用法: drill_unhealthy_since <RFC3339> <关键字，如 Liveness|Readiness|probe>
drill_unhealthy_since() {
  local since="$1" kw="$2"
  kubectl -n "$DRILL_NS" get events \
    -o go-template='{{range .items}}{{if eq .reason "Unhealthy"}}{{.lastTimestamp}} {{.message}}{{"\n"}}{{end}}{{end}}' \
    2>/dev/null | awk -v since="$since" -v kw="$kw" \
    '$1 >= since && index($0, kw) {n++} END {print n+0}'
}
