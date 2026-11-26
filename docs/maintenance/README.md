# 维护手册（baidu-drive / 全盘管理 fork）

本目录是 `skills/baidu-drive` 这个自用 fork 的维护入口。目标只有一个：**外部契约发生变化时，能在固定位置查到“怎么发现、怎么确认、怎么更新”**，不靠记忆，也不靠猜参数。

维护对象是四条独立契约：

| 契约 | 提供方 | 变化特征 | 发现方式 | 更新方式 |
|---|---|---|---|---|
| 官方 skill | GitHub `baidu-netdisk/bdpan-storage` | `VERSION`、`SKILL.md`、脚本、reference 文档 | `git fetch upstream` + `update.sh --check` | `git merge upstream/main`，冲突按 [updates.md](./updates.md) 处理 |
| `bdpan` CLI | 百度（闭源 Go 二进制） | 子命令、参数、JSON 字段、错误码 | `bdpan version`；升级后跑 [regression.md](../../skills/baidu-drive/reference/regression.md) | 用户明确触发 `bdpan update`，回归后更新文档 |
| 官方 MCP Server | 百度（服务端） | 工具增删、参数 schema、`errno` | [mcp-tools.md](./mcp-tools.md) 的清单比对 | 不需要“安装”，改调用方式和文档；若上线原生删除则替换中转删除 |
| 开放平台文档 | 百度（公开网页） | 权限边界、目录授权、新能力 | [open-docs.md](./open-docs.md) 的季度重抓 | 重新抓取、入库、对比能力清单 |

## 固定节奏

| 频率 | 动作 | 预计耗时 |
|---|---|---|
| 每月 | `bash scripts/update.sh --check`；`git fetch upstream --prune` 后用 `git log --oneline HEAD..upstream/main` 看落后；`mcp-token.sh --status` 看 token 剩余天数；跑一次只读冒烟（whoami、quota、`ls` 空目录、MCP `file_list` 根目录；接了 Hermes 的再跑 `hermes mcp test baidu-netdisk`） | 约 10 分钟 |
| 每次 CLI / skill 升级后 | 按 [regression.md](../../skills/baidu-drive/reference/regression.md) 全量回归（含全盘删除 5.1） | 30–60 分钟 |
| 每季度 | 重抓开放平台文档（[open-docs.md](./open-docs.md)）；导出 MCP 工具清单并与基线比对（[mcp-tools.md](./mcp-tools.md)） | 1–2 小时 |
| 随时 | 出现 `unknown command`、`unknown tool`、schema 错误、`errno` 变化 → 停止，不改用猜测参数，记录后跑回归 | — |

## 变更发生时的处理顺序

1. **停**：写操作报错或超时，只说明“调用方不知道结果”，不要换参数重试；按 [whole-drive.md 第 3 节](../../skills/baidu-drive/reference/whole-drive.md) 核对。
2. **记**：记录 CLI 版本、skill `VERSION`、命令、原样错误（`code` / `status` / `errno` / `show_msg`）。
3. **判**：先判断是 CLI、skill、MCP 还是平台文档的变化，再决定改哪一层；不要用另一层的参数硬凑。
4. **验**：修改后先跑回归，再更新文档；无法确认状态时停止并报告。
5. **提交**：是否提交由用户决定；本仓库默认不自动提交。

## 当前基线（2026-11-25）

| 项 | 值 |
|---|---|
| skill `VERSION` | 1.7.8（2026-11-25 合并上游 `baidu-drive/v1.7.8`；本 fork 的 VERSION 跟上游走） |
| `bdpan` CLI | 本机 3.8.9。1.7.8 的登录流程要求 ≥ 3.9.0：3.8.9 上业务命令可用，但不能重新登录。3.9.0 的路径只按上游文档用假 CLI 测过包装脚本，**尚未在真 CLI 上回归** |
| MCP 工具数 | 25（基线文件：[contracts/mcp-tools.baseline.json](./contracts/mcp-tools.baseline.json)） |
| 开放平台文档 | 292 页（2026-11-25 抓取；WeKnora 库 `4b967e84-4ead-4861-9e27-aaf4cf91a62b`） |
| MCP token 签发 | 2026-11-25T14:48:41（本地记录），30 天后到期；详见 [token.md](./token.md) |
| 1Password 条目 | `baidu-netdisk-mcp`（`MCP_TOKEN` / `ISSUED_AT`，metadata complete） |
| CLI token 到期 | 2026-12-25T09:44:50+08:00（`bdpan whoami --json` 的 `expires_at`） |
| Hermes | Agent v0.23.4；MCP 通道 2026-11-25 接入（`transport: sse`，token 在 `.env`，skill 经 `skills.external_dirs` 挂载）；宿主细节见 [hosts/hermes.md](../../skills/baidu-drive/reference/hosts/hermes.md) |

基线是“上次核对过的事实”，不是保证；每次升级/比对后更新本表。

## 目录

| 文件 | 用途 |
|---|---|
| [updates.md](./updates.md) | 四类更新源怎么检查、怎么合并、冲突怎么处理 |
| [open-docs.md](./open-docs.md) | 开放平台文档抓取、入库、能力对比 |
| [mcp-tools.md](./mcp-tools.md) | MCP 工具清单基线、导出与比对、变更分类 |
| [token.md](./token.md) | 两个 token 的位置、剩余时间、1Password 集成与轮换 |
| [tools/mcp-call.mjs](./tools/mcp-call.mjs) | 只读 MCP 维护客户端（维护用，不被 skill 加载） |
| [tools/compare-mcp-tools.mjs](./tools/compare-mcp-tools.mjs) | 两份工具清单的差异比较 |
| [tools/scrape-union-docs.mjs](./tools/scrape-union-docs.mjs) | 开放平台文档抓取 |
| [tools/test-bdpanw.sh](./tools/test-bdpanw.sh) | `bdpanw.sh` 的离线测试（不联网、不碰网盘），配 [tools/bdpanw-mock/](./tools/bdpanw-mock/) 里的假 CLI |
| [contracts/mcp-tools.baseline.json](./contracts/mcp-tools.baseline.json) | 25 个 MCP 工具的参数基线 |
| [contracts/cli-surface.txt](./contracts/cli-surface.txt) | 本 fork 依赖的 CLI 命令、参数与 JSON 字段 |

## 边界

- 维护工具放在 `docs/maintenance/tools/`，**不被 skill 加载**，也不进入日常调用路径；skill 本身仍只有 CLI 通道 + 宿主提供的 MCP 工具。
- 不引入常驻服务、数据库或后台队列；所有检查都是只读、一次性命令。
- 文档、日志、提交里不出现 token、授权码、真实文件名或内部地址；只报长度、哈希前缀、字段名。
- 测试只在专门创建的测试目录内进行，不操作其他个人文件。
- 不自动提交；合并上游前先看 [updates.md](./updates.md) 的冲突预期。
