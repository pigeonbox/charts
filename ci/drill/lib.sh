#!/usr/bin/env bash
# ci/drill/lib.sh — kind 演练公共库（#23 第③块：灰度回滚 + 故障三场景）
#
# 被 01~04 场景脚本 source。提供：集群创建、镜像预载、chart 安装、断言原语。
# 与 .github/workflows/lint-test.yml 的 kind 冒烟同一套约定：
#   - 镜像名与 tag 全部取自 chart（values.yaml 的 image.* / frontend.image.* /
#     redis.image.*，缺省 tag 取 Chart.yaml appVersion 剥 v），**不写死**：
#     写死 ⇒ chart 改了镜像名/tag 而演练还拉老镜像 ⇒ 预载白跑、演练红；
#   - 预载用 docker save + ctr import --platform <本机架构>（多架构 OCI index 直接
#     kind load 会因 --all-platforms 缺另一平台 blob 而失败，见 workflow 注释）。
#
# 环境变量（均有默认值，本地与 CI 通用）：
#   DRILL_CLUSTER  kind 集群名        默认 pb-drill
#   DRILL_NS       命名空间            默认 fcb-ci
#   DRILL_RELEASE  helm release 名     默认 fcb
#   DRILL_PUBLISHED_VERSIONS  已发布版本集合（空格/逗号/分号分隔）——默认自动解析
#   DRILL_PUBLISHED_SOURCES  已发布版本的取值来源（逗号分隔）默认 env,repo,remote
#
# CI 入口：.github/workflows/drill.yml（夜间定时 + workflow_dispatch）。
#   流水线只做「装工具 → 备 ghcr 凭据 → 依次跑 01~04 → 汇总」，集群/镜像/安装
#   一律由本库自举（幂等，可重复跑）⇒ 断言的唯一真相源在脚本里，不在 workflow 里。
#   ⚠️ DRILL_* 的默认值不可随意改：演练 01 的「无 Pending Pod」断言写死了
#      app.kubernetes.io/instance=fcb（chart 的 instance 标签 = helm release 名），
#      改 release 名会选不中任何 Pod ⇒ 断言静默假绿。
set -euo pipefail

# ── shellkit（CI 侧统一管道；**设备侧脚本一律不引**，见 C1） ───────────────
# third_party/shellkit 是上游镜像（由 hub 侧 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**。
# ⚠️ 落点是 third_party/ 而不是 vendor/：Go ≥1.14 见到**模块根**下有 vendor/ 就默认切
#    vendor 模式 ⇒ 缺 vendor/modules.txt ⇒ go build 报 "inconsistent vendoring"（实测现红）。
# ⚠️ 本库被 01~04 场景脚本 source ⇒ 库路径必须相对**本文件**解析，不能依赖调用方的 cwd。
DRILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DRILL_DIR/../.." && pwd)"
. "$REPO_ROOT/third_party/shellkit/lib/bootstrap.sh"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}" # 库内消息走中文，与生态输出一致

DRILL_CLUSTER="${DRILL_CLUSTER:-pb-drill}"
DRILL_NS="${DRILL_NS:-fcb-ci}"
DRILL_RELEASE="${DRILL_RELEASE:-fcb}"
CHART="$REPO_ROOT/charts/pigeonbox"

# ── 断言原语 ────────────────────────────────────────────────────────────
# ⚠️ **失败出口必须逐字保留两件事**：
#   ① `::error::` 注解**必须在行首** —— 它是 **GitHub Actions 的错误注解**
#      （workflow 的 Annotations 里能看到 ⇒ 不是普通日志）。
#      ⚠️ **不能用 shellkit 的 `log_error` 打这个注解**：它会加 `[ERROR] ` 前缀 ⇒
#      `::error::` 不在行首 ⇒ **Actions 认不出来**（注解静默失效 ⇒ CI 上失败原因消失）。
#      ⇒ 这里用 `printf` 直接打到 stderr，逐字保持原形态。
#   ② 失败退出码仍是 1（drill workflow 按非 0 判场景失败）。
fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}
# ⚠️ `ok()` 用 shellkit 的 log_ok（日志一律 stderr，stdout 只给数据）。
ok() { log_ok "$*"; }

drill_arch() {
  local a
  a=$(uname -m)
  case "$a" in x86_64) echo amd64 ;; aarch64 | arm64) echo arm64 ;; *) echo "$a" ;; esac
}

drill_app_tag() {
  awk '/^appVersion:/{gsub(/"/,"",$2); sub(/^v/,"",$2); print $2; exit}' "$CHART/Chart.yaml"
}

# 读 chart values.yaml 的某个点分键（如 image.repository / frontend.image.tag /
# redis.image.tag）。只解析浅层标量（chart 的 values 结构够用，且不引 yq 依赖）；
# 读不到（键不存在或值为空）⇒ 返回 1 ⇒ 调用方必须响亮失败，不许兜底写死值。
drill_chart_value() {
  local want="$1"
  awk -v want="$want" '
    function ind(s,   m) { m = match(s, /[^ ]/); return (m ? m - 1 : -1) }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[ ]*#/ || line ~ /^[ ]*$/) next
      ci = ind(line)
      if (ci < 0) next
      rest = substr(line, ci + 1)
      p = index(rest, ":")
      if (p < 2) next
      key = substr(rest, 1, p - 1)
      if (key !~ /^[A-Za-z0-9_.-]+$/) next
      val = substr(rest, p + 1)
      sub(/[ \t]+#.*$/, "", val)
      gsub(/^[ \t]+/, "", val)
      gsub(/[ \t]+$/, "", val)
      # 缩进栈 ⇒ 点分路径（image.repository / frontend.image.repository …）
      while (n > 0 && si[n] >= ci) n--
      n++
      sk[n] = key
      si[n] = ci
      path = ""
      for (j = 1; j <= n; j++) path = (j == 1 ? sk[j] : path "." sk[j])
      if (path != want) next
      gsub(/^"|"$/, "", val)
      if (val == "") next
      print val
      exit
    }' "$CHART/values.yaml"
}

# chart 定义的三个镜像引用（server / frontend / redis）。名字与 tag 全部来自 chart，
# 不写死。取不到 ⇒ 返回 1（调用方响亮失败）。
drill_server_image() {
  local repo tag
  repo=$(drill_chart_value image.repository)
  tag=$(drill_chart_value image.tag)
  [ -n "$tag" ] || tag=$(drill_app_tag)
  [ -n "$repo" ] && [ -n "$tag" ] || return 1
  printf '%s:%s\n' "$repo" "$tag"
}

drill_frontend_image() {
  local repo tag
  repo=$(drill_chart_value frontend.image.repository)
  tag=$(drill_chart_value frontend.image.tag)
  [ -n "$tag" ] || tag=$(drill_app_tag)
  [ -n "$repo" ] && [ -n "$tag" ] || return 1
  printf '%s:%s\n' "$repo" "$tag"
}

drill_redis_image() {
  local repo tag
  repo=$(drill_chart_value redis.image.repository)
  tag=$(drill_chart_value redis.image.tag)
  [ -n "$repo" ] && [ -n "$tag" ] || return 1
  printf '%s:%s\n' "$repo" "$tag"
}

# 集群：不存在则创建；存在则复用（幂等）
drill_ensure_cluster() {
  if ! kind get clusters 2>/dev/null | grep -qx "$DRILL_CLUSTER"; then
    log_info "创建 kind 集群 $DRILL_CLUSTER"
    kind create cluster --name "$DRILL_CLUSTER" --wait 120s || fail "kind 集群创建失败"
  else
    log_info "复用已有 kind 集群 $DRILL_CLUSTER"
  fi
  kubectl config use-context "kind-$DRILL_CLUSTER" >/dev/null
}

# 单镜像预载：docker pull（本平台）→ 节点内 ctr import pin 平台（幂等，重复导入无害）
drill_preload_one() {
  local ref="$1"
  local node
  node=$(kind get nodes --name "$DRILL_CLUSTER" | head -1)
  docker pull -q "$ref" >/dev/null || fail "镜像拉取失败: $ref"
  docker save "$ref" | docker exec -i "$node" \
    ctr --namespace=k8s.io images import --platform "linux/$(drill_arch)" \
    --digests --snapshotter=overlayfs - >/dev/null ||
    fail "镜像预载失败: $ref"
  ok "预载 $ref"
}

# 预载默认三镜像（server/frontend/redis —— 名字与 tag 全部取自 chart，不写死：
# 写死的镜像名会与 chart 漂移 ⇒ 预载了集群根本不用的镜像，白跑）
drill_preload_images() {
  local server frontend redis
  server=$(drill_server_image) || fail "chart 未给出 server 镜像（values.yaml 的 image.repository/image.tag）"
  frontend=$(drill_frontend_image) || fail "chart 未给出 frontend 镜像（values.yaml 的 frontend.image.*）"
  redis=$(drill_redis_image) || fail "chart 未给出 redis 镜像（values.yaml 的 redis.image.*）"
  drill_preload_one "$server"
  drill_preload_one "$frontend"
  drill_preload_one "$redis"
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
    log_warn "helm 瞬时失败，10s 后重试 ($i/2)"
    sleep 10
  done
  drill_wait_ready
}

# 用 label 选中两平面（deployment 名随 fullname 变，selector 与 workflow 冒烟同款）
drill_wait_ready() {
  local t="${1:-180s}" i
  for i in 1 2 3; do
    if kubectl -n "$DRILL_NS" rollout status deploy -l app.kubernetes.io/component=server --timeout="$t" >/dev/null &&
      kubectl -n "$DRILL_NS" rollout status deploy -l app.kubernetes.io/name=pigeonbox-frontend --timeout="$t" >/dev/null; then
      return 0
    fi
    [ "$i" -lt 3 ] || fail "deployment 未在重试后回 Ready"
    log_warn "rollout 等待失败，10s 后重试 ($i/2)"
    sleep 10
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
    sh -c 'wget -qO- --timeout=8 http://127.0.0.1:12345/api/config' 2>&1) ||
    fail "[$label] /api/config 请求失败: $out"
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

# ── 已发布版本解析（演练 04 的灰度目标版本不许写死）────────────────────────
# 为什么要它：04 曾把 TAG_NEXT 写死成 5.7.0 ⇒ 生态版本前进后演练永远对着老版本打
#   （要么跑在旧版本上，要么镜像被清理后直接红）。改成从「真实已发布 tag」解析：
#   取不到就**响亮失败**，绝不静默兜底一个写死值。
#
# 已发布版本集合（drill_published_versions 输出：每行一个 X.Y.Z，降序）＝ 下列来源并集：
#   env    ：DRILL_PUBLISHED_VERSIONS（显式注入；空格/逗号/分号分隔）——离线/自测用；
#   repo   ：本仓 git tag `pigeonbox-<ver>`（主版本 ≥5 才是「chart 版本跟产品号同号」
#             方案；更早的 pigeonbox-2.0.x 是 chart 包版本号，不是镜像 tag ⇒ 排除）；
#   remote ：远端产品发布版本（server 仓 ∩ frontend 仓 的 release tag —— 两个镜像
#             都存在该 tag，灰度目标才拉得到；匿名读公开仓，无需凭据）。
# 取值来源可用 DRILL_PUBLISHED_SOURCES 裁剪（默认 env,repo,remote）。
DRILL_PUBLISHED_SOURCES="${DRILL_PUBLISHED_SOURCES:-env,repo,remote}"

# 远端产品发布版本（server 仓 ∩ frontend 仓）：
#   - server 仓的 release 产出 ghcr.io/pigeonbox/server:<tag>；
#   - frontend 仓的 release 产出 ghcr.io/pigeonbox/frontend:<tag>。
# 演练 04 的灰度目标同时升级两个平面 ⇒ 目标版本必须在交集里（否则预载镜像拉不到）。
drill_remote_product_versions() {
  local server frontend
  server=$(git ls-remote --tags https://github.com/pigeonbox/server.git 'v*' 2>/dev/null |
    awk '{ print $2 }' | sed 's#^refs/tags/v##' || true)
  frontend=$(git ls-remote --tags https://github.com/pigeonbox/frontend.git 'v*' 2>/dev/null |
    awk '{ print $2 }' | sed 's#^refs/tags/v##' || true)
  printf '%s\n%s\n' "$server" "$frontend" |
    awk 'NF && $0 !~ /\^\{\}$/ { c[$0]++ } END { for (k in c) if (c[k] == 2) print k }'
}

# 版本降序排序 + 去重（纯 POSIX 口径：不依赖 GNU sort -V，macOS/BSD 也能跑）
drill_sort_versions_desc() {
  sed 's/^v//' |
    awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
      printf "%010d%010d%010d\t%s\n", $1, $2, $3, $0
    }' |
    sort -r | cut -f2 | awk '!seen[$0]++'
}

# 已发布版本集合（每行一个 X.Y.Z，降序）
drill_published_versions() {
  local sources="$DRILL_PUBLISHED_SOURCES"
  local raw=""
  case ",$sources," in
    *,env,*)
      if [ -n "${DRILL_PUBLISHED_VERSIONS:-}" ]; then
        raw="$raw
$(printf '%s' "$DRILL_PUBLISHED_VERSIONS" | awk '{ gsub(/[,; ]/, "\n"); print }' || true)"
      fi
      ;;
  esac
  case ",$sources," in
    *,repo,*)
      raw="$raw
$(git -C "$REPO_ROOT" tag -l 'pigeonbox-*' 2>/dev/null |
        sed 's#^pigeonbox-##' |
        awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $1 + 0 >= 5 { print }' || true)"
      ;;
  esac
  case ",$sources," in
    *,remote,*)
      raw="$raw
$(drill_remote_product_versions || true)"
      ;;
  esac
  printf '%s\n' "$raw" | drill_sort_versions_desc
}

# 解析「与 base 不同」的已发布版本（list 按降序，每行一个）：
#   优先「严格大于 base 的最小者」（下一个已发布版本）；
#   否则「严格小于 base 的最大者」（上一个已发布版本）；
#   都没有 ⇒ 返回 1 ⇒ 调用方必须响亮失败（不许静默兜底写死值）
drill_resolve_peer_version() {
  local base="$1" list="$2"
  printf '%s\n' "$list" | awk -v base="$base" '
    function vcmp(x, y,   xs, ys, i, nx, ny) {
      nx = split(x, xs, ".")
      ny = split(y, ys, ".")
      if (nx != 3 || ny != 3) return 0
      for (i = 1; i <= 3; i++) {
        if (xs[i] + 0 > ys[i] + 0) return 1
        if (xs[i] + 0 < ys[i] + 0) return -1
      }
      return 0
    }
    NF {
      c = vcmp($0, base)
      if (c == 1) { greater = $0; next }
      if (c == -1 && smaller == "") smaller = $0
    }
    END {
      if (greater != "") { print greater; exit 0 }
      if (smaller != "") { print smaller; exit 0 }
      exit 1
    }'
}
