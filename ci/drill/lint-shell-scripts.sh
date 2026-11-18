#!/usr/bin/env bash
# ci/drill/lint-shell-scripts.sh — 仓内 shell 脚本门禁：shfmt 格式 + shellcheck 正确性
#
# 为什么有这道门禁：
#   2026-11-18 实测 ci/drill/ 五个脚本**全部**不合 shfmt（shfmt -l -i 2 -ci 全量点名），
#   而 charts 仓此前**没有任何格式门禁**（Lint and Test Charts 一直是绿的）⇒ 格式基线持续
#   漂移、review 里排版噪声淹没逻辑 diff。同一批脚本还把灰度目标版本**写死**成 5.7.0
#   ⇒ 演练永远对着老版本打。两件事一起治：格式一次拉干净（见前一个 commit）+ 本门禁防回潮。
#
# 口径（与生态 hub 仓 scripts/check-shfmt.sh 同款，便于两仓统一）：
#   · 格式：shfmt -i 2 -ci（两空格缩进 + case 分支缩进一级）。shfmt 版本必须钉死
#     v3.14.1（不同 minor 的格式化输出可能有差异 ⇒ 浮动版本会让门禁时红时绿）。
#   · 正确性：shellcheck -x（0 告警）。
#   · 扫描范围：git ls-files 里的 shell 脚本（*.sh 或首行 shebang 指向 sh/bash）。
#   · 扫到 0 个 ⇒ 判红（「没扫到」≠「扫过且通过」）。
#
# 用法：bash ci/drill/lint-shell-scripts.sh [--selfcheck]
#   --selfcheck：门禁自证（负对照）——干净⇒绿、注入格式漂移⇒红且点名、
#     注入 shellcheck 错误⇒红且点名、还原⇒绿、零覆盖⇒红。
set -uo pipefail

# 脚本自身路径（绝对）——自证模式要用它重入本脚本；ROOT 可能被覆盖 ⇒ 必须先取绝对路径
SELF="$0"
case "$SELF" in
  /*) ;;
  *) SELF="$PWD/$SELF" ;;
esac

# 扫描根目录可覆盖（自证模式要指向临时工作区）
ROOT="${DRILL_LINT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *)
      echo "用法: $0 [--selfcheck]"
      exit 2
      ;;
  esac
done

SHFMT_BIN="${SHFMT_BIN:-shfmt}"
SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"

if ! command -v "$SHFMT_BIN" >/dev/null 2>&1; then
  echo "✗ 没有 shfmt——门禁自身失效（安装: brew install shfmt，或 go install mvdan.cc/sh/v3/cmd/shfmt@v3.14.1）"
  exit 1
fi

if ! command -v "$SHELLCHECK_BIN" >/dev/null 2>&1; then
  echo "✗ 没有 shellcheck——门禁自身失效（安装: apt-get install shellcheck / brew install shellcheck）"
  exit 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "✗ $ROOT 不是 git 仓——无法界定「在库」脚本，门禁自身失效"
  exit 1
fi

# 在库 shell 脚本清单：*.sh 或首行 shebang 指向 sh/bash
collect_files() { # → stdout，每行一个仓内相对路径
  git ls-files -z | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    case "$f" in
      *.sh)
        printf '%s\n' "$f"
        continue
        ;;
    esac
    if head -n1 "$f" | grep -qE '^#![/a-z0-9 _.-]*(ba|da|k)?sh([[:space:]]|$)'; then
      printf '%s\n' "$f"
    fi
  done
}

files=()
while IFS= read -r f; do
  [ -n "$f" ] && files[${#files[@]}]="$f"
done < <(collect_files)

if [ "${#files[@]}" -eq 0 ]; then
  echo "✗ 扫到 0 个在库 shell 脚本——门禁自身失效（git ls-files 结构变了？）"
  exit 1
fi

# ── 判定 1：shfmt -l 列出格式漂移文件 ────────────────────────────────────────
# shfmt 退出码：0=干净；1=列出了漂移文件（-l 的正常「有问题」信号）；≥2=执行失败
# （脚本语法坏了 / 工具参数错）⇒ 两者都要判红，但话术要分开，别把漂移说成解析失败。
shfmt_rc=0
drifted=$("$SHFMT_BIN" -i 2 -ci -l "${files[@]}" 2>&1) || shfmt_rc=$?

if [ "$shfmt_rc" -ge 2 ]; then
  echo "✗ shfmt 执行失败（rc=$shfmt_rc；脚本语法坏了或工具异常）:"
  printf '%s\n' "$drifted" | sed 's/^/    /'
  exit 1
fi

if [ -n "$drifted" ]; then
  echo "✗ 以下文件未 shfmt 干净（修法: shfmt -i 2 -ci -w <文件>）:"
  printf '%s\n' "$drifted" | sed 's/^/    /'
  echo
  echo "  口径: shfmt -i 2 -ci（版本钉 v3.14.1，浮动版本会时红时绿）。"
  echo "  为何要紧: 格式漂移的 diff 会淹没 review 里的逻辑 diff。"
  exit 1
fi

echo "✓ shfmt 检查通过（${#files[@]} 个在库 shell 脚本，shfmt -i 2 -ci）"

# ── 判定 2：shellcheck 0 告警 ───────────────────────────────────────────────
sc_out=$("$SHELLCHECK_BIN" -x "${files[@]}" 2>&1) || {
  echo "✗ shellcheck 报出问题（修法: shellcheck -x <文件>）:"
  printf '%s\n' "$sc_out" | sed 's/^/    /'
  exit 1
}
echo "✓ shellcheck 检查通过（${#files[@]} 个在库 shell 脚本，0 告警）"

# ── 自证（负对照）：门禁必须有牙齿 ─────────────────────────────────────────
if [ "$SELFCHECK" -eq 1 ]; then
  SELF_TMP=$(mktemp -d)
  OK=0
  # shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
  trap 'rc=$?; rm -rf "$SELF_TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT
  mkdir -p "$SELF_TMP/scripts"
  git -C "$SELF_TMP" init -q >/dev/null 2>&1
  self_fail=0

  # 基线：格式干净且无 shellcheck 问题 ⇒ 必须绿
  printf '#!/usr/bin/env bash\nif true; then\n  echo hi\nfi\n' >"$SELF_TMP/scripts/ok.sh"
  git -C "$SELF_TMP" add . >/dev/null 2>&1
  if DRILL_LINT_ROOT="$SELF_TMP" bash "$SELF" >/dev/null 2>&1; then
    echo "  ✓ 基线：格式干净 + shellcheck 无告警 ⇒ 门禁绿"
  else
    echo "  ✗ 基线竟然判红 ⇒ 门禁本身坏了" >&2
    self_fail=1
  fi

  # 注入 1：4 空格缩进（shfmt -i 2 会挑出来）⇒ 必须红**且点名文件**
  printf '#!/usr/bin/env bash\nif true; then\n    echo hi\nfi\n' >"$SELF_TMP/scripts/drifted.sh"
  git -C "$SELF_TMP" add . >/dev/null 2>&1
  bad_rc=0
  bad_out=$(DRILL_LINT_ROOT="$SELF_TMP" bash "$SELF" 2>&1) || bad_rc=$?
  if [ "$bad_rc" -eq 0 ]; then
    echo "  ✗ 注入「格式漂移的文件」后门禁仍绿 ⇒ 断言无效" >&2
    self_fail=1
  elif printf '%s' "$bad_out" | grep -q 'drifted.sh'; then
    echo "  ✓ 注入「格式漂移的文件」⇒ 门禁变红并点名 drifted.sh（断言有牙齿）"
  else
    echo "  ✗ 判红但没点名文件 ⇒ 结论不可用" >&2
    self_fail=1
  fi

  # 移除注入后恢复绿（证明上面的红不是「本来就红」）
  rm -f "$SELF_TMP/scripts/drifted.sh"
  if DRILL_LINT_ROOT="$SELF_TMP" bash "$SELF" >/dev/null 2>&1; then
    echo "  ✓ 移除注入后恢复绿"
  else
    echo "  ✗ 移除注入后仍红 ⇒ 门禁有误报" >&2
    self_fail=1
  fi

  # 注入 2：shellcheck 真问题（未加引号的变量展开 SC2086）⇒ 必须红且点名
  # shellcheck disable=SC2016  # 单引号里的 $HOME 是**要注入的坏例子**，不该被本脚本展开
  printf '#!/usr/bin/env bash\ncat $HOME/drill-sample\n' >"$SELF_TMP/scripts/badcheck.sh"
  git -C "$SELF_TMP" add . >/dev/null 2>&1
  bad_rc=0
  bad_out=$(DRILL_LINT_ROOT="$SELF_TMP" bash "$SELF" 2>&1) || bad_rc=$?
  if [ "$bad_rc" -eq 0 ]; then
    echo "  ✗ 注入「shellcheck 报错的文件」后门禁仍绿 ⇒ 断言无效" >&2
    self_fail=1
  elif printf '%s' "$bad_out" | grep -q 'badcheck.sh'; then
    echo "  ✓ 注入「shellcheck 报错的文件」⇒ 门禁变红并点名 badcheck.sh"
  else
    echo "  ✗ 判红但没点名文件 ⇒ 结论不可用" >&2
    self_fail=1
  fi
  rm -f "$SELF_TMP/scripts/badcheck.sh"

  # 空转守卫：一个在库 shell 脚本都没有 ⇒ 必须红（「没扫到」≠「扫过且通过」）
  rm -f "$SELF_TMP/scripts/ok.sh"
  if DRILL_LINT_ROOT="$SELF_TMP" bash "$SELF" >/dev/null 2>&1; then
    echo "  ✗ 零覆盖时门禁仍绿 ⇒ 空转守卫无效" >&2
    self_fail=1
  else
    echo "  ✓ 零覆盖 ⇒ 门禁变红（空转守卫有牙齿）"
  fi

  if [ "$self_fail" -ne 0 ]; then
    echo "✗ 自证失败：本门禁至少有一条断言没有区分力" >&2
    exit 1
  fi
  echo "✓ 自证：干净⇒绿、格式漂移⇒红点名、shellcheck 错误⇒红点名、还原⇒绿、零覆盖⇒红 ⇒ 门禁有牙齿"
fi
OK=1
