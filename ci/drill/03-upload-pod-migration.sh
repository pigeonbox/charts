#!/usr/bin/env bash
# ci/drill/03-upload-pod-migration.sh — #23 场景③：上传过程中 Pod 迁移
#
# 验证评审点名的「分片会话不丢、续传可用」（呼应 upload_id 不重 init 铁律：
# upload_id 由 file_hash 派生 ⇒ 重 init 会另起新会话使旧位图作废 ⇒ 续传必须
# 对既有会话补片）。
#
# 全链路走真实用户路径：frontend pod 内 curl → nginx(/chunk/ 反代) → server
# Service → server pod。迁移 = force-delete server pod（RS 重建新 pod）；
# 客户端（curl）视角零变化，仅 nginx 上游短暂 502 后恢复。
#
# 断言：
#   1. init + 传 2/3 片（status 位图=2）；
#   2. force-delete server pod → 新 pod Ready、链路恢复；
#   3. **核心**：同一 upload_id 的 status 仍报 uploaded=2（会话未随旧 pod 消失，
#      证明会话在共享存储而非进程内存）；
#   4. 补传第 3 片（不重新 init）→ 位图=3；
#   5. complete 成功、返回真实 share_code。
#
# 前置：docker + kind + kubectl + helm；集群/镜像/安装由 lib 自举（幂等）。
# 用法: ci/drill/03-upload-pod-migration.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NS="$DRILL_NS"
REL="$DRILL_RELEASE"
CHUNK_SIZE=1048576 # 1MB × 3 片（限流 UploadQPS=10，小流量）
TOTAL_CHUNKS=3

# 在 frontend pod 内发 curl（真实用户路径；frontend 不参与迁移）
fcurl() {
  kubectl -n "$NS" exec deploy/"$REL-pigeonbox-frontend" -- \
    curl -s --max-time 30 "$@"
}

fjson() { # 取业务码（0=成功）
  fcurl "$@" 2>/dev/null | sed -n 's/.*"code":\([0-9-]*\).*/\1/p' | head -1
}

log_info "══ 0) 自举：集群 + 镜像预载 + 安装 ══"
drill_ensure_cluster
drill_preload_images
drill_install

log_info "══ 1) 造分片会话：init + 传 2/3 片 ══"
# frontend pod 内生成 3×1MB 随机片 + 整文件 sha256
kubectl -n "$NS" exec deploy/"$REL-pigeonbox-frontend" -- sh -c '
  head -c 1048576 /dev/urandom > /tmp/dc0
  head -c 1048576 /dev/urandom > /tmp/dc1
  head -c 1048576 /dev/urandom > /tmp/dc2
  cat /tmp/dc0 /tmp/dc1 /tmp/dc2 > /tmp/dbig
  sha256sum /tmp/dbig | cut -d" " -f1 > /tmp/dsha
' >/dev/null
SHA=$(kubectl -n "$NS" exec deploy/"$REL-pigeonbox-frontend" -- cat /tmp/dsha | tr -d '[:space:]')
[ ${#SHA} -eq 64 ] || fail "取不到文件 sha256（实得 ${#SHA} 字节）"
ok "已生成 3×1MB 分片文件 sha256=${SHA:0:16}…"

INIT_BODY=$(fcurl -F "file_name=drill-migrate.bin" \
  -F "file_size=$((CHUNK_SIZE * TOTAL_CHUNKS))" \
  -F "file_hash=$SHA" \
  -F "chunk_size=$CHUNK_SIZE" \
  -F "total_chunks=$TOTAL_CHUNKS" \
  http://127.0.0.1:8080/chunk/upload/init/)
echo "$INIT_BODY" | grep -q '"code":0' || fail "init 失败: ${INIT_BODY:0:200}"
UPLOAD_ID=$(echo "$INIT_BODY" | sed -n 's/.*"upload_id":"\([^"]*\)".*/\1/p')
[ -n "$UPLOAD_ID" ] || fail "init 未返回 upload_id"
ok "init 成功 upload_id=${UPLOAD_ID:0:20}…"

put_chunk() {
  local i="$1"
  fcurl -F "chunk=@/tmp/dc$i" \
    "http://127.0.0.1:8080/chunk/upload/chunk/$UPLOAD_ID/$i"
}
for i in 0 1; do
  put_chunk "$i" | grep -q '"code":0' || fail "传片 $i 失败"
done
ok "已传片 0、1（2/3）"
st_body=$(fcurl "http://127.0.0.1:8080/chunk/upload/status/$UPLOAD_ID")
echo "$st_body" | grep -q '"uploaded_chunks":2' || fail "status 应报 2 片: ${st_body:0:200}"
ok "status 位图=2"

log_info "══ 2) 迁移：force-delete server pod ══"
old_pod=$(kubectl -n "$NS" get po -l app.kubernetes.io/component=server \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" delete po "$old_pod" --force --grace-period=0 >/dev/null
ok "已 force-delete ${old_pod}（模拟上传中 Pod 迁移）"
# 等 server 新 pod 的容器 ready（判据函数化，避免 retry 里嵌套引号）
# ⚠️ 等价替换：原为「for i in $(seq 1 60) + sleep 3」（最多 180s）⇒ DELAY=3/BACKOFF=1。
#   原实现超时后不判失败，由随后的 `new_ready` 断言判红 ⇒ `|| true` 保持该语义。
server_pod_ready() {
  kubectl -n "$NS" get po -l app.kubernetes.io/component=server \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="pigeonbox")].ready}' 2>/dev/null |
    grep -q true
}
SHELLKIT_RETRY_DELAY=3 SHELLKIT_RETRY_BACKOFF=1 retry 60 server_pod_ready || true
new_ready=$(kubectl -n "$NS" get po -l app.kubernetes.io/component=server \
  -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="pigeonbox")].ready}' 2>/dev/null || echo false)
[ "$new_ready" = true ] || fail "新 server pod 未在 180s 内 Ready"
new_pod=$(kubectl -n "$NS" get po -l app.kubernetes.io/component=server \
  -o jsonpath='{.items[0].metadata.name}')
[ "$new_pod" != "$old_pod" ] || fail "pod 未发生迁移（同名）"
ok "新 pod $new_pod 已 Ready（旧 $old_pod 已消失）"

# 等 nginx 上游恢复（Service endpoint 指向新 pod）
# ⚠️ 等价替换：原为「for i in $(seq 1 30) + sleep 2」（最多 60s）⇒ DELAY=2/BACKOFF=1。
frontend_api_ok() {
  fcurl http://127.0.0.1:8080/api/config 2>/dev/null | grep -q '"code":0'
}
SHELLKIT_RETRY_DELAY=2 SHELLKIT_RETRY_BACKOFF=1 retry 30 frontend_api_ok || true
fcurl http://127.0.0.1:8080/api/config 2>/dev/null | grep -q '"code":0' ||
  fail "迁移后前端链路未恢复（60s）"
ok "迁移后前端链路恢复"

log_info "══ 3) 核心断言：同一 upload_id 会话存活 ══"
st_body=$(fcurl "http://127.0.0.1:8080/chunk/upload/status/$UPLOAD_ID")
echo "$st_body" | grep -q '"uploaded_chunks":2' ||
  fail "迁移后分片会话丢失/位图变化（应=2）: ${st_body:0:200}"
ok "迁移后 status 仍报 uploaded=2（会话在共享存储，未随旧 pod 消失）"

log_info "══ 4) 续传：补片 2（不重新 init） ══"
put_chunk 2 | grep -q '"code":0' || fail "补传片 2 失败"
st_body=$(fcurl "http://127.0.0.1:8080/chunk/upload/status/$UPLOAD_ID")
echo "$st_body" | grep -q '"uploaded_chunks":3' || fail "补传后位图应=3: ${st_body:0:200}"
ok "补传片 2 成功、位图=3（对既有会话续传，未重 init）"

log_info "══ 5) complete → 真实分享码 ══"
cmp_body=$(fcurl -F "expire_value=1" -F "expire_style=day" -F "require_auth=false" \
  "http://127.0.0.1:8080/chunk/upload/complete/$UPLOAD_ID")
echo "$cmp_body" | grep -q '"code":0' || fail "complete 失败: ${cmp_body:0:200}"
share_code=$(echo "$cmp_body" | sed -n 's/.*"share_code":"\([^"]*\)".*/\1/p')
[ -n "$share_code" ] && [ "$share_code" != "$UPLOAD_ID" ] ||
  fail "complete 未返回真实 share_code: ${cmp_body:0:200}"
ok "complete 成功 share_code=${share_code}（跨迁移的分片会话完整闭环）"

log_ok "✅ 场景③（上传中 Pod 迁移）通过"
