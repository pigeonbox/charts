# pigeonbox Helm Charts

[![CI](https://github.com/pigeonbox/charts/actions/workflows/lint-test.yml/badge.svg)](https://github.com/pigeonbox/charts/actions/workflows/lint-test.yml)
[![Chart](https://img.shields.io/github/v/tag/pigeonbox/charts?label=chart)](https://github.com/pigeonbox/charts/tags)
[![License](https://img.shields.io/github/license/pigeonbox/charts)](LICENSE)

[PigeonBox](https://github.com/pigeonbox/pigeonbox)（文件快递柜 — 匿名口令分享文本/文件）生态的 Kubernetes Helm Chart 仓库。
独立发版：chart 版本与业务仓库版本解耦，chart 里的 `appVersion` 对应 `server` 镜像 tag。

> 🗂️ [PigeonBox 生态](https://github.com/orgs/pigeonbox)成员仓 · 总览与部署见 [装配仓 pigeonbox](https://github.com/pigeonbox/pigeonbox) · [架构图集](https://github.com/pigeonbox/pigeonbox/blob/main/docs/architecture.md)

## Chart 一览

| Chart | 说明 | Chart 版本 | App 版本 |
|---|---|---|---|
| `pigeonbox` | 前后端分离双 Deployment：[frontend](https://github.com/pigeonbox/frontend)（nginx 静态+反代）→ [server](https://github.com/pigeonbox/server)（API）；Ingress 指向 frontend Service | 见 [Chart.yaml](charts/pigeonbox/Chart.yaml) 的 `version`（发版自动刷新，勿在 README 手写小版本） | 同文件 `appVersion`（= server 镜像 tag，与产品号同步） |

支持可选组件：Redis（默认开）/ MySQL / PostgreSQL / S3 对象存储（SeaweedFS）/ PVC / Ingress / ServiceMonitor(Prometheus) / p2p 联邦注册中心（1.3.4 起，`p2p.enabled`，1.3.7 起含 PigeonBeam 直传中继开关；2.0 起默认 chart 名即 pigeonbox）；2.0 线(自 1.3.22 起)多副本双拓扑（`replicaCount>1` 自动渲染 public×N + admin×1，`PB_DEPLOY_MODE`）。

> server 镜像自 v3.0.0 波（设备直传拆分为独立应用）起不再随包 p2pc 设备直传二进制——直传归 PigeonBeam（信鸽直传）；注意 core 侧的 P2P 联邦为 **standalone 部署模式专属**——多副本双拓扑（public×N + admin×1 拆分）下自动降级不可用。

## 安装

方式一（**推荐**）：Helm 仓库（GitHub Pages，由 chart-releaser 自动发布）——始终装到最新已发布版本，不依赖手写版本号

```bash
helm repo add pigeonbox https://pigeonbox.github.io/charts
helm repo update
helm install pigeonbox pigeonbox/pigeonbox \
  --namespace pigeonbox --create-namespace
```

方式二：OCI 制品（ghcr.io，与 Pages 同步发布）

```bash
helm install pigeonbox oci://ghcr.io/pigeonbox/charts/pigeonbox
```

> 该 OCI 包已设为 public，可匿名安装。注意：org 包由 CI（GITHUB_TOKEN）推送时默认 private，且 GitHub 无修改可见性的 API——若将来删除重建，需在 org Settings → Packages 手动改回 public。

方式三：直接使用 Release 制品

从 [Releases](https://github.com/pigeonbox/charts/releases) 下载 `pigeonbox-<version>.tgz`
（`<version>` 以 Releases 最新为准，与 [Chart.yaml](charts/pigeonbox/Chart.yaml) 同源）：

```bash
helm install pigeonbox ./pigeonbox-<version>.tgz
```

生产环境最少建议覆盖：

```bash
helm install pigeonbox pigeonbox/pigeonbox \
  --set secret.adminPassword='<强密码>' \
  --set secret.production=true \
  --set ingress.enabled=true \
  --set ingress.hosts[0].host=<你的域名>
```

完整参数与生产建议见 [charts/pigeonbox/README.md](charts/pigeonbox/README.md)。

## 发布新版本（维护者）

1. 修改 `charts/pigeonbox/Chart.yaml` 的 `version`（chart 语义化版本）和/或 `appVersion`（对应 server 镜像 tag）
2. push 到 `main`
3. [chart-releaser](https://github.com/helm/chart-releaser-action) 自动执行：打包 `.tgz` → 发 GitHub Release → 更新 `gh-pages/index.yaml`（Helm 仓库索引）

chart `version` 未变化的 push 不会重复发布。

## CI

- `lint-test.yml`：PR / push 时用 [chart-testing](https://github.com/helm/chart-testing) 做 `ct lint`，并在 kind 集群上 `ct install` 安装冒烟（CI 会轮询等待 `appVersion` 对应镜像发布后 `kind load` 预载）。
  **前置条件**：`ghcr.io/pigeonbox/server` 与 `ghcr.io/pigeonbox/frontend` 镜像包需为 public（或给 CI 配置 imagePullSecrets），否则安装步骤会因拉取镜像失败。
- `release.yml`：push 到 `main` 自动发布。

仓库首次发布后需确认 GitHub Pages 已启用：Settings → Pages → Source = `gh-pages` branch / `/(root)`。

## 故障演练（kind 真集群）

[![Kind Failure Drill](https://github.com/pigeonbox/charts/actions/workflows/drill.yml/badge.svg)](https://github.com/pigeonbox/charts/actions/workflows/drill.yml)

`ci/drill/` 下是四个**真集群**故障演练脚本（2026-11-16 PR #32 交付）——在 kind 单节点集群里真把服务打挂，再断言「不雪崩 / 能自愈 / 会话不丢 / 能回滚」：

| 脚本 | 场景 | 断言要点 |
|---|---|---|
| `01-redis-unavailable.sh` | Redis 不可用 | force-delete 后自动重建；scale 0 持续 60s 期间 server/frontend **零重启**、`/api/config` 仍 200、匿名分享降级成功、liveness 失败 <3 |
| `02-node-termination.sh` | 节点终止 | `kubectl drain` 驱逐 ⇒ 业务 Pod Pending（单副本脆弱性实证）+ 断流，uncordon 后自愈；`docker stop` 节点 ⇒ 集群失联，`docker start` ⇒ 回 Ready 自愈 |
| `03-upload-pod-migration.sh` | 上传中 Pod 迁移 | 上传中 force-delete server Pod ⇒ **同一 upload_id 位图不丢**（会话在共享存储）⇒ 补传 ⇒ complete 返回单一 share_code |
| `04-canary-rollback.sh` | 灰度升级与回滚 | 换镜像 tag 滚动（断流窗口 ≤90s）；坏 tag ⇒ `ErrImagePull`/`ImagePullBackOff` 不伪装就绪；`helm rollback` 恢复 |

### 怎么跑

**本地手工跑**（前置：docker + kind + kubectl + helm。集群、镜像预载、chart 安装由脚本自举，幂等，可重复跑）：

```bash
bash ci/drill/01-redis-unavailable.sh   # 一次跑一个；四个都要就依次跑
```

- 集群名/命名空间/release 由 `DRILL_CLUSTER`（默认 `pb-drill`）、`DRILL_NS`（默认 `fcb-ci`）、`DRILL_RELEASE`（默认 `fcb`）控制——**别改默认值**：脚本 01 的断言写死了 `app.kubernetes.io/instance=fcb`，改 release 名会选不中 Pod 而假绿。
- 需能拉 `ghcr.io/pigeonbox/{server,frontend}` 与 `redis:7-alpine`；镜像没发布时脚本在「镜像预载」处报 `镜像拉取失败: <ref>`。

**夜间 CI**：`.github/workflows/drill.yml` 每日 03:17 UTC（= 11:17 CST）自动跑全部四个；也可在 Actions 页手动 `workflow_dispatch`：

- `drills`：选 `all` 或单个场景（`01`/`02`/`03`/`04`）；
- `allow_failure`：默认 `false`——**任一演练失败 ⇒ workflow 变红**（这是演练存在的意义）；显式置 `true` 才只收集结果不判红。

**失败怎么定位**：

1. 先看「**演练结果汇总**」步骤——四个场景各一行（状态 + 退出码），一眼看出是哪场挂了；
2. 失败时紧邻的「**演练失败诊断**」步骤已留好现场：Pod 列表、events、Pod describe/logs、`helm history`；
3. 脚本自身的失败点以 `::error::…` 打在日志里（`fail()` 原语），末尾 `✅ 场景N（…）通过` 是最后一道绿；
4. 常见原因：① chart 的 appVersion 镜像还没发布（CI 先等 20 分钟，仍不到就红并跳过演练）② ghcr 上的旧镜像被清理 ③ runner 资源不足导致 Pod Pending。

## License

[Apache-2.0](LICENSE)
