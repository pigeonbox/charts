#!/usr/bin/env bash
# ci/drill/dump-pod-logs.sh —— Pod 级日志转储（**不依赖 kubectl logs --init-containers**）
#
# 为什么单独一个脚本（2026-11-18 夜间演练红实录）：
#   演练/冒烟失败时的诊断 step 原本写的是
#     kubectl logs <pod> --all-containers --init-containers --tail=50
#   而 **--init-containers 不是 kubectl logs 的旗标**（演练 runner 的 kubectl 版本
#   没有它）⇒ 直接报 `error: unknown flag: --init-containers`
#   ⇒ 诊断 step 自己先炸 ⇒ **演练失败现场一条日志都没留下**
#   —— 最需要证据的时候，证据被采集动作本身弄没了。
#   （顺带一提：--all-containers 本身是否含 init 容器随 kubectl 版本而异，
#     所以 init 容器单独按名字再拉一遍，跨版本都拿得到。）
#
# 用法: bash ci/drill/dump-pod-logs.sh <namespace> <pod> [tail行数]
#   <pod> 允许两种形态: "xxx" 或 "pod/xxx"（kubectl get po -o name 的输出）。
#
# 退出码恒为 0：这是**诊断**工具，取不到日志不该反过来把诊断 step 变成失败源
#   （原实现用 || true 也正是这个意图，只是被未知旗标先打断了）。
set -uo pipefail

NS="${1:-}"
POD="${2:-}"
TAIL="${3:-50}"

if [ -z "$NS" ] || [ -z "$POD" ]; then
  echo "用法: $0 <namespace> <pod> [tail行数]" >&2
  exit 2
fi

# kubectl get po -o name 给的是 "pod/xxx" ⇒ 取名字时剥掉前缀
NAME="${POD##*/}"

# 普通容器：--all-containers
kubectl -n "$NS" logs "$NAME" --all-containers --tail="$TAIL" 2>&1 || true

# init 容器：先取名字，再逐个 -c 拉（跨 kubectl 版本都可用）
INIT_NAMES="$(kubectl -n "$NS" get pod "$NAME" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null || true)"
for c in $INIT_NAMES; do
  echo "──────── init container: $c ────────"
  kubectl -n "$NS" logs "$NAME" -c "$c" --tail="$TAIL" 2>&1 || true
done

exit 0
