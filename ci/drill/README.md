# ci/drill — kind 真集群故障演练

四个演练场景脚本（`01`~`04`）+ 公共库 `lib.sh` + 门禁脚本 `lint-shell-scripts.sh`。
背景、运行方式与故障排查见仓库根 `README.md` 的「故障演练（kind 真集群）」一节。

| 文件 | 作用 |
| --- | --- |
| `lib.sh` | 公共库：集群自举、镜像预载、chart 安装、断言原语、**已发布版本解析** |
| `01-redis-unavailable.sh` | 场景① Redis 不可用（不雪崩 / 降级可用 / 零重启） |
| `02-node-termination.sh` | 场景② 节点终止（drain 驱逐 + 节点容器 stop/start ⇒ 自愈） |
| `03-upload-pod-migration.sh` | 场景③ 上传中 Pod 迁移（分片会话不丢 ⇒ 续传 ⇒ 单一 share_code） |
| `04-canary-rollback.sh` | 场景④ 灰度升级与失败回滚 |
| `lint-shell-scripts.sh` | 门禁：仓内 shell 脚本的 shfmt 格式 + shellcheck 正确性（含负对照自证） |

## 环境变量

| 变量 | 默认 | 含义 |
| --- | --- | --- |
| `DRILL_CLUSTER` | `pb-drill` | kind 集群名 |
| `DRILL_NS` | `fcb-ci` | 命名空间 |
| `DRILL_RELEASE` | `fcb` | helm release 名（**别改**：脚本 01 的断言按 `instance=fcb` 选 Pod，改了会假绿） |
| `TAG_BASE` | Chart.yaml `appVersion` | 场景④ 的基线版本 |
| `TAG_NEXT` | 自动解析 | 场景④ 的灰度目标版本（须与基线不同、且是真实已发布版本） |
| `TAG_PREV` | 空 | 显式指定「上一个已发布版本」（优先级低于 `TAG_NEXT`） |
| `TAG_BAD` | `0.0.0-drill-not-exist` | 场景④ 里故意拉不到的坏镜像 tag（制造失败升级） |
| `DRILL_PUBLISHED_VERSIONS` | 空 | 显式指定已发布版本集合（空格/逗号/分号分隔） |
| `DRILL_PUBLISHED_SOURCES` | `env,repo,remote` | 已发布版本的取值来源（逗号分隔） |

## 场景④ 的版本取值规则

`TAG_NEXT` **不再写死**（此前写死成 `5.7.0` ⇒ 生态版本前进后演练永远对着老版本打）。

**取值优先级**

1. `TAG_NEXT` 环境变量（显式指定）；
2. `TAG_PREV` 环境变量（显式指定「上一个已发布版本」）；
3. 自动解析：在「已发布版本集合」里取**与基线不同**的那个 —— 优先「严格大于基线的最小者」
   （下一个已发布版本），否则「严格小于基线的最大者」（上一个已发布版本）。

**已发布版本集合**（`lib.sh: drill_published_versions`）＝ 下列来源的并集：

- `env`：`DRILL_PUBLISHED_VERSIONS`（显式注入；离线/自测用）；
- `repo`：本仓 git tag `pigeonbox-<ver>`（主版本 ≥5 才是「chart 版本跟产品号同号」方案；
  更早的 `pigeonbox-2.0.x` 是 chart 包版本号，不是镜像 tag ⇒ 排除）；
- `remote`：远端 `server` 仓 ∩ `frontend` 仓 的 release tag（两个镜像都在该 tag，
  灰度目标才拉得到；匿名读公开仓，无需凭据）。

**失败语义（响亮失败，绝不静默兜底写死值）**

- 已发布集合取不到（仓库 tag 与远端都读不到）⇒ 报错退出；
- 解析不出与基线不同的版本 ⇒ 报错退出；
- 显式传入的 `TAG_NEXT` 格式非 `X.Y.Z`、与基线相同、或不在已发布集合里 ⇒ 报错退出；
- `TAG_BAD` 竟然在已发布集合里 ⇒ 报错退出（否则「失败升级」场景失去意义）。

**自证输出**：脚本会打印解析出来的 `TAG_BASE` / `TAG_NEXT` / 来源 / 已发布版本数，
并断言「格式合法 + ≠ 基线 + 真实已发布」三条。

只解析、不跑演练（不建集群）：

```bash
bash ci/drill/04-canary-rollback.sh --resolve-only
TAG_NEXT=6.5.0 bash ci/drill/04-canary-rollback.sh --resolve-only
```
