#!/usr/bin/env bash
# ci/drill/check-image-ref.sh —— 门禁：04 场景实际拼出的**镜像引用形态**必须合法。
#
# 为什么要有这道门禁（2026-11-18 夜间演练红实录）：
#   drill_server_image 返回**完整引用**（repo:tag），而 04 场景要「同一仓库、换 tag」
#   ⇒ 原实现再拼 ":$TAG_NEXT" ⇒ 得到 ghcr.io/pigeonbox/server:6.8.0:6.9.0
#   这种**非法引用** ⇒ docker pull 必失败 ⇒ 演练红。
#   而错误文案是「镜像拉取失败: ghcr.io/pigeonbox/server:6.8.0:6.9.0」
#   —— 看着像「镜像没发布」，实则是**引用拼错** ⇒ 排查方向被带偏一整晚。
#
# ⚠️ **判据不许自己重拼一份**：
#   v1 版本在本守卫里自己按「仓库名 + tag」拼一遍引用再检查 ⇒ 门禁查的是
#   **守卫自己那份拼接**，不是 04 脚本实际用的那份 ⇒ 把 04 改回历史缺陷形态
#   门禁照样绿（实测：真负对照不转红 ⇒ 判据没有牙齿）。
#   ⇒ 本版改为**从 04 脚本源码里取出它真正使用的那几行**并求值 ⇒
#     04 改坏 ⇒ 被求值出来的引用形态同步变坏 ⇒ 判据转红（同一判断只有一处实现）。
#
# 判据：
#   ① 04 脚本里所有「镜像引用」表达式求值后，冒号数必须**恰为 1**；
#   ② tag 部分必须是纯版本号（X.Y.Z）。
#
# ⚠️ **求值必须离线可重放**：
#   TAG_NEXT 的真实取值来自「已发布版本集合」，默认来源含**远端查询**
#   ⇒ 网络抖动会让门禁假红（形态判据与网络无关）。
#   ⇒ 这里把取值来源钉成 env（固定集合）⇒ 同一棵树上结果恒定。
#
# 用法: bash ci/drill/check-image-ref.sh [--selfcheck]
#   --selfcheck：负对照自证——把 04 改回「完整引用再拼 tag」的历史缺陷形态，
#                门禁必须转红；不转红 ⇒ 判据没牙齿 ⇒ 门禁自己判红。
#
# 环境变量:
#   DRILL_04  被检查的 04 脚本路径（默认 ci/drill/04-canary-rollback.sh）。
#             --selfcheck 用它指向「改坏的副本」⇒ 判据自身可被证伪。
set -uo pipefail

SELFCHECK=0
case "${1:-}" in
  --selfcheck) SELFCHECK=1 ;;
  "") ;;
  *)
    echo "用法: $0 [--selfcheck]" >&2
    exit 2
    ;;
esac

DRILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DRILL_DIR/../.." && pwd)"
D04="${DRILL_04:-$DRILL_DIR/04-canary-rollback.sh}"

fails=0
note_fail() {
  echo "  ✗ $1"
  fails=$((fails + 1))
}
note_ok() { echo "  ✓ $1"; }

# shellcheck source=ci/drill/lib.sh
. "$DRILL_DIR/lib.sh"
# lib.sh 带着 set -euo pipefail 进来；本守卫要**收集全部判据**再统一红
# ⇒ 关掉 errexit（否则第一条判据失败就把后面的判据全吞掉）。
set +e

# ── 固定「已发布版本集合」⇒ 离线可重放 ───────────────────────────────
export DRILL_PUBLISHED_SOURCES=env
export DRILL_PUBLISHED_VERSIONS="6.7.0 6.8.0 6.9.0 7.0.0"

# ── 从 04 源码里抽出「镜像引用表达式」──────────────────────────────
# 取形如 $VAR:$TAG_X 或 "$VAR:$TAG_X" 的行（04 里共 4 处：预载 + 两条断言 + 回滚断言）。
# 用法：把这些行**在 04 的真实环境里求值**（下面的 eval_ref）⇒ 得到 04 真正会用的引用。
extract_ref_exprs() {
  # shellcheck disable=SC2016 # 单引号里要的是**字面量** `$VAR`（从 04 源码抠表达式），不是展开
  grep -oE '"?\$[A-Z_]+:\$TAG_[A-Z_]+"?' "$D04" | tr -d '"' | sort -u
}

# 在 04 的上下文里求值某个表达式：
#   · tag 变量：与 04 同源（lib 的 drill_app_tag / drill_published_versions /
#     drill_resolve_peer_version ⇒ 04 的推导逻辑只有一份，这里不重写）；
#   · 镜像变量：取 04 **原样**的定义行（取值逻辑保持 04 原样 ⇒ 同一判断只有一处实现）。
eval_ref() { # <表达式，如 $SERVER_REPO:$TAG_NEXT> → stdout: 求值结果
  # shellcheck disable=SC2034 # expr/TAG_NEXT 只在下面的 eval 串里被消费，shellcheck 看不见
  local expr="$1" out
  out="$(
    TAG_BASE="$(drill_app_tag)"
    TAG_BASE="${TAG_BASE#v}"
    _pub="$(drill_published_versions)"
    # shellcheck disable=SC2034 # 同上：TAG_NEXT 由 eval 串消费
    TAG_NEXT="$(drill_resolve_peer_version "$TAG_BASE" "$_pub")"
    eval "$(grep -E '^(SERVER_REPO|SERVER_IMAGE)=' "$D04" | sed 's/^/    /')"
    eval "printf '%s\\n' \"$expr\""
  )"
  printf '%s' "$out"
}

check_ref() { # <说明> <引用>
  local desc="$1" ref="$2"
  local colons tagpart
  colons="$(printf '%s' "$ref" | tr -cd ':' | wc -c | tr -d ' ')"
  if [ "$colons" != "1" ]; then
    note_fail "${desc}: 引用 '$ref' 的冒号数=$colons（应恰为 1：repo:tag）—— 非法镜像引用"
    return 1
  fi
  tagpart="${ref##*:}"
  if ! printf '%s' "$tagpart" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    note_fail "${desc}: 引用 '$ref' 的 tag 部分 '$tagpart' 不是纯版本号"
    return 1
  fi
  note_ok "${desc}: $ref"
  return 0
}

echo "── 判据：04 脚本实际使用的镜像引用形态必须合法（被检查文件：$D04）"
exprs="$(extract_ref_exprs)"
if [ -z "$exprs" ]; then
  note_fail "没从 04 脚本里取到任何镜像引用表达式——判据自身失效（脚本形态变了？）"
else
  for e in $exprs; do
    r="$(eval_ref "$e")"
    check_ref "$e" "$r"
  done
fi

# ── 负对照自证：改坏 04 ⇒ 本门禁必须转红 ───────────────────────────
if [ "$SELFCHECK" -eq 1 ]; then
  echo
  echo "── 负对照自证：把 04 改回「完整引用再拼 tag」的历史缺陷形态，门禁必须转红"
  tmp="$(mktemp -d)"
  bad="$tmp/04-canary-rollback.sh"
  cp "$DRILL_DIR/04-canary-rollback.sh" "$bad"
  # 变异①：镜像变量换回**完整引用**（repo:tag）
  # shellcheck disable=SC2016 # 单引号是故意的：变异要写**字面量** $(drill_server_image)
  sed -i.bak 's|^SERVER_REPO=.*|SERVER_IMAGE="$(drill_server_image)"|' "$bad"
  # 变异②：所有引用点改回「完整引用再拼一个 tag」
  # shellcheck disable=SC2016 # 同上：变异要写**字面量** $SERVER_IMAGE:$TAG_NEXT
  sed -i.bak2 's|\$SERVER_REPO:\$TAG_NEXT|$SERVER_IMAGE:$TAG_NEXT|g' "$bad"
  if DRILL_04="$bad" bash "$DRILL_DIR/check-image-ref.sh" >"$tmp/out" 2>&1; then
    note_fail "负对照：改坏的 04 副本竟然通过了门禁 ⇒ 判据没有牙齿（门禁自身判红）"
  elif grep -q '冒号数' "$tmp/out"; then
    note_ok "负对照：改坏的 04 副本被门禁判红（判据有牙齿）"
    grep '冒号数' "$tmp/out" | head -2 | sed 's/^/    /'
  else
    note_fail "负对照：门禁确实转红了，但红的原因不是引用形态判据（判据被别的错误顶替）"
    sed -n '1,20p' "$tmp/out" | sed 's/^/    /'
  fi
  rm -rf "$tmp"
fi

if [ "$fails" -gt 0 ]; then
  echo
  echo "✗ $fails 条判据失效"
  exit 1
fi
echo
echo "✓ 04 场景的镜像引用形态全部合法"
exit 0
