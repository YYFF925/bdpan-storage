# 升级回归清单

在以下情况跑一遍；只使用**专用测试目录**，不碰其他个人文件：

- 升级 `bdpan` CLI 之后；
- 合并 upstream 之后；
- 修改 `bdpanw.sh` / `staging.sh` / `mcp-token.sh` / `SKILL.md` 之后。

在 Hermes 终端里跑时，交给 `jq`、`node` 等原生程序的本机路径要写 Windows 风格（Hermes 默认设了 `MSYS_NO_PATHCONV=1`），见 `reference/hosts/hermes.md`。

## 0. 记录版本

```bash
cat <SKILL_DIR>/VERSION
bash <SKILL_DIR>/scripts/bdpanw.sh version
# MCP：在会话里列一次工具，记录数量（当前 25）与名称
#      Hermes 会话里带 mcp__baidu_netdisk__ 前缀的是 29 个（25 + 4 个通用协议工具），
#      以 `hermes mcp test baidu-netdisk` 列出的 25 个为准
```

把 Skill 版本、CLI 版本、MCP 工具清单记在一起，便于回退判断。

## 1. 基础

| 检查 | 命令 | 期望 |
|---|---|---|
| 登录态 | `bdpanw.sh whoami` | `authenticated: true`，退出 0 |
| 版本 | `bdpanw.sh version` | 文本输出，退出 0 |
| 容量 | `bdpanw.sh quota` | `code: 0`，退出 0 |

## 2. 路径与边界

| 检查 | 命令 | 期望 |
|---|---|---|
| 应用根目录 | `bdpanw.sh ls` | JSON 数组，退出 0 |
| 绝对路径 | `bdpanw.sh ls /apps/bdpan` | 与上一条一致（谓词确认路径转换被正确处理） |
| 越界路径 | `bdpanw.sh ls /my-documents` | 退出 1，`路径超出授权目录范围` |
| 路径穿越 | `bdpanw.sh ls ../x` | 退出 1，`路径穿越攻击被阻止` |
| 空目录 | 建一个空目录后 `bdpanw.sh ls <它>` | 输出 `[]`（不是目录自身） |

## 3. 上传 / 下载

在测试目录内：

1. 上传一个小文件（Windows 风格本地路径）→ `action: created`，`saved_path` 正确；
2. 远端 `size` 与本地一致，`action` 为 created（百度返回的 `md5` 不是标准 MD5，不能与本地 `md5sum` 比对）；
3. 同名同内容再传 → `action: unchanged`；
4. 同名不同内容再传 → `action: renamed`（`(1)` 后缀）；
5. `--overwrite` → `action: overwritten`；文件夹带 `--overwrite` → 被拒绝；
6. 下载到本地新路径 → 本地 md5 与远端一致；
7. **`.part` 与原子替换（2026-11-25 已实测）**：预置哨兵文件作为下载目标，下载中出现 `<目标>.part`；终止进程后哨兵文件完好、`.part` 残留；完整重下后 md5 一致、`.part` 消失。回归时重复一遍，行为变化则按实际修正文档。

## 4. 列表与搜索

| 检查 | 期望 |
|---|---|
| `bdpanw.sh ls <测试目录>` | 数组，元素含 `fsid`/`md5`/`return_markdown` |
| `bdpanw.sh search <测试标记>` | `items[]` 含命中与链接 |
| MCP `file_list` 根目录 | `errno 0`，能列出（不打印用户文件名） |
| MCP `file_keyword_search` 测试标记 | 命中所属测试目录的文件 |

## 5. 中转与清理

```bash
bash <SKILL_DIR>/scripts/staging.sh new up
# 上传到该目录 → MCP file_move 到测试目录 → 核对 fsid → set status done → clean
```

期望：任务目录按 `<kind>-<id>` 命名；`clean` 在非 `done` 状态被拒绝；`stale 7` 能列出未清理任务。`_staging/` 根目录不存在时 `staging.sh new` 会自动创建。

`clean` 里的 `rm` 偶发 `errno 20013`（HTTP 403，2026-11-25 实测到一次）：先 `ls` 确认任务目录为空，再重试一次 `clean`；仍失败就停止并报告。

### 5.1 全盘删除（仅测试目录）

只在专用测试目录内跑，且只删自己刚创建的对象：

1. MCP 在测试目录建一个文件（`file_upload_by_content`），记录 `fsid`；
2. `staging.sh new del`，`set <id> note <原路径>`；
3. MCP `file_move` 移到 `_staging/del-<id>/`；
4. 核对：原位置消失、中转目录出现同名项、`fsid` 不变；
5. `bdpanw.sh rm <中转路径> --force`，确认中转目录为空；
6. `set status done`、`clean`；
7. 测试文件夹本身按同样流程删除，确认根目录恢复原状。

期望：七步全部成功；任一步核对不一致时按文档停止并报告，不继续删。

## 6. 读正文

- txt：`bdpanw.sh get-content <fsid>` 同步返回正文；
- Office/PDF：MCP `file_content_create` → `file_content_get`（同一 task id 轮询，不重复创建任务）。

## 7. Token 脚本

- 用同一个 token 再写一次 → `issued_at` 保持原值；
- 备份文件里 `Authorization` 为 `Bearer <redacted>`，不含明文；
- 配置里其他 server（如 `hindsight`）保持原样。

`--host hermes`（用假 token 在隔离的 `HERMES_HOME` 里测，不要拿真 token 试错）：

- 条目缺失时自动补建 `mcp_servers.baidu-netdisk`（输出 `server_added: true`），再跑一次为 `false`；
- `config.yaml` 里只有 `${MCP_BAIDU_NETDISK_API_KEY}` 模板、不含 token；`.env` 里该键只有一行；标准输出和错误输出里都不含 token；
- 同一 token 再写一次 → `issued_at` 保持原值；
- `--host` 为未知值、`--config` 指向没有 `config.yaml` 的目录、`HERMES_PYTHON` 无法导入 `hermes_cli` → 分别退出 2、2、1，且 `.env` 不变。

## 8. Hermes（宿主项）

先确认 `hermes mcp test baidu-netdisk` 连上并列出 25 个工具，再给 Hermes 发一次性任务（`hermes -z "<prompt>"`），让它汇报：

| 检查 | 期望 |
|---|---|
| skill 目录 | `skill_view` 返回的 `skill_dir` 指向仓库的 `skills/baidu-drive`；`${CLAUDE_SKILL_DIR}` 保持字面量 |
| 终端环境 | `MSYS_NO_PATHCONV=1`；`command -v jq node bdpan cygpath` 都有结果 |
| CLI | `bdpanw.sh version` / `whoami` / `ls <测试目录>` 成功；`bash -x` 里两次调用的 `--session-id` 相同，`--agentname hermes` |
| MCP 工具 | 工具不在直接列表里，经 `tool_call` 调用 `mcp__baidu_netdisk__get_quota`、`file_list` 成功 |
| 中转上传 / 下载 | 在测试目录内走通第 5 节的两条流程，`fsid` 核对一致 |
| 删除协议 | 只问方法 → 不移动、不删除、不建任务；明确许可一个测试文件后 → 七步全部完成 |
| 越界 / 穿透 | `bdpanw.sh ls /my-documents`、`ls ../x` 退出 1（2026-11-25 只在模拟环境验证，Hermes 终端内未跑） |

Hermes 的汇报要另行核对：用 CLI `ls` 和 MCP `file_list` 看网盘与中转目录的实际状态，不要只看它自己的 JSON。

## 9. 收尾

- 删除测试目录与应用目录内的测试文件；
- 确认网盘根目录没有遗留测试文件夹；
- `staging.sh list` 里没有本次测试留下的未清理任务；
- 记录本次结果（通过/失败项、CLI 版本、异常现象），失败项不静默忽略。
