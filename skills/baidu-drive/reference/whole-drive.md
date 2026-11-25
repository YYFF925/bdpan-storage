# 全盘管理（双通道）参考

本文是 `SKILL.md` 全盘章节的展开。适用范围：ZCode 与 Hermes 已实机验证，个人自用；应用目录之外的删除**经用户明确允许后**经中转执行。

## 1. 两条通道

| 通道 | 覆盖 | 能做的 | 不能做的 |
|---|---|---|---|
| `bdpan` CLI（经 `scripts/bdpanw.sh`） | 仅 `/apps/bdpan` | 本地文件上传/下载、读正文、删除、列表、搜索、创建/移动/复制/重命名、分享、转存、容量 | 触及 `/apps/bdpan` 之外的任何文件 |
| 官方 MCP Server（`baidu-netdisk`） | 整个网盘 | 列目录、关键词/语义搜索、文件详情、建文件夹、复制、移动、重命名、按文本内容或 URL 存文件、读 Office/PDF 正文、分享链接的列表/验码/转存/任务查询 | 没有删除工具；本地上传/下载只是生成 CLI 提示词 |

关键事实（2026-11-25 实测，25 个工具）：

- `file_upload`、`file_download`、`file_sharelink_download` **不传输文件**，只校验路径并生成让 Agent 调用本地 `bdpan` CLI 的提示词，且目标限定 `/apps/bdpan`。不要用它们完成本地文件进出。
- 服务端真正执行、覆盖全盘的是：`file_list` / `file_doc_list` / `file_image_list` / `file_video_list`、`file_keyword_search`、`file_semantics_search`、`file_meta`、`make_dir`、`file_copy`、`file_move`、`file_rename`、`file_upload_by_content`、`file_upload_by_url`、`file_content_create` + `file_content_get`、`file_sharelink_set`、`file_sharelink_list` / `file_sharelink_verify` / `file_sharelink_transfer` / `file_sharelink_taskquery`、`user_info`、`get_quota`。
- **没有删除工具**。全盘删除只能走“移动 + CLI 删除”的中转路径，且必须获得用户明确允许（见第 5 节）。

MCP 工具按名称引用；宿主前缀不同：

- ZCode：`mcp__baidu-netdisk__file_list`
- Hermes：`mcp__baidu_netdisk__file_list`（经 `tool_call` 调用）
- 其他宿主：按实际注册名映射，见 `reference/hosts/`

## 2. 路径模型

| 场景 | 形式 |
|---|---|
| MCP 工具 | 以 `/` 开头的网盘绝对路径（如 `/apps/bdpan/docs/a.pdf`、`/项目资料/b.pdf`） |
| CLI（经 `bdpanw.sh`） | 相对 `/apps/bdpan` 的路径（`docs/a.pdf`），或完整 `/apps/bdpan/...`；**不要**在 Git Bash 里直接传绝对远程路径给原生 CLI——`bdpanw.sh` 已处理 |
| 展示给用户 | `我的应用数据/bdpan/...` 或网盘里的原路径 |

注意：

- `file_meta` 返回的 `path` 是 URL 编码的（`%2Fapps%2Fbdpan%2F...`），比较前先解码。
- `file_list` 对不存在的目录返回 `errno 1002`（“请求数据为空”），不要当成空目录。
- `file_move` 移动**文件夹**时，会把它放进目标目录内部（成为目标的子目录），路径要按此预期拼接。
- `make_dir` 的 `rtype`：0 冲突失败、1 冲突改名、2 按 MD5 决定、4 覆盖。中转任务目录用 0，冲突即失败。
- `file_copy` / `file_move` / `file_rename` 的 `ondup`：`fail` / `newcopy`（默认）/ `overwrite` / `skip`。
- CLI 的 `ls /` 指**应用根目录** `/apps/bdpan`，不是网盘根目录；网盘根目录只能用 MCP `file_list`。
- `file_keyword_search` 是模糊匹配，可能命中含相关词的其他文件，不能据此断言“只有这些/不存在”。
- MCP 写操作失败可能返回 `{"errno":12,"info":[{"errno":-9,...}]}`：外层是任务级错误，内层是具体文件错误（-9 = 文件不存在）。

## 3. 失败核对配方（写操作绝不盲目重试）

超时或报错只说明“调用方不知道结果”。按操作核对后再决定：

| 操作 | 核对方法 | 判定 |
|---|---|---|
| 建目录 | MCP `file_list` 父目录，找该名字 | 已存在 = 成功；不存在 = 可重试一次 |
| 上传（CLI） | `bdpanw.sh ls <父目录>`：同名文件的 `size` 与本地一致，`action` 为 created/renamed/overwritten/unchanged | 一致 = 成功；不存在 = 可重试；size 不一致 = 停止并报告。**百度返回的 `md5` 不是标准 MD5**（值含非十六进制字符，如 `fc8f9eafbjbad85a…`），不能与本地 `md5sum` 比对；需要内容级证明时下载回来对比本地副本 |
| 下载（CLI） | 本地文件 `md5sum` 与下载前的本地副本/已知值比对，并核对 `size` | 一致 = 成功；不一致或缺失 = 重试一次；仍不一致 = 停止 |
| 移动 / 重命名 | 查源是否存在、目标是否存在，比对 `fsid` | 源消失且目标出现且 `fsid` 不变 = 成功（实测 `fsid` 不随重命名/移动改变）；源在目标无 = 可重试；两者都在 = 停止并报告 |
| 复制 | 目标位置是否出现，`fsid` 是否不同、`size` 是否与源一致 | 出现 = 成功 |
| 删除（应用目录内） | `ls` 目标路径 | 目标消失 = 成功 |
| 删除（应用目录外，中转） | 原位置消失 + 中转目录出现且 `fsid` 一致 → CLI 删除后中转目录为空 | 每步都满足 = 成功；任一步不满足 = 停止并报告，不继续删 |
| 转存 | `file_sharelink_taskquery <task_id>`；CLI 无任务查询时按目标目录核对 | 任务成功/落点出现 = 成功 |
| 读正文 | 已创建的任务只重查（`file_content_get` / `get-content-result`） | 不重复创建任务（重复创建消耗配额） |

只读命令（`ls`、`search`、`search-content`、`file_list`、`file_meta`）可以重试 3 次，间隔 2 秒。**无法确认状态时停止并报告**，不要重试。

MCP 失败的两种形态要分清：

- 会话未建立（`initialize` 无应答）：请求没发出去，换新会话重试即可；
- 请求已发出但应答丢失：必须走上面的核对流程。

## 4. 中转流程

中转目录：`/apps/bdpan/_staging/<kind>-<id>/`，`kind` ∈ `up` / `dl` / `read` / `del`。任务状态在**本机**记录（不写网盘）：

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/staging.sh new up     # → "<id> _staging/up-<id>/"
bash ${CLAUDE_SKILL_DIR}/scripts/staging.sh path <id>
bash ${CLAUDE_SKILL_DIR}/scripts/staging.sh status <id>
bash ${CLAUDE_SKILL_DIR}/scripts/staging.sh set <id> status done
bash ${CLAUDE_SKILL_DIR}/scripts/staging.sh list
bash ${CLAUDE_SKILL_DIR}/scripts/staging.sh clean <id>   # 仅 status=done
bash ${CLAUDE_SKILL_DIR}/scripts/staging.sh stale 7      # 未清理且超过 7 天
```

状态：`preparing → remote_ready → local_done → done → cleaned`；失败记 `failed`。**只有 `done` 允许 `clean`**；失败或中断保留现场并告诉用户文件在哪里。

### 4.1 上传本地文件到任意位置

1. `staging.sh new up` → 得到 `_staging/up-<id>/`；
2. `bdpanw.sh upload <本地文件> _staging/up-<id>/<文件名>`；
3. 核对：`ls` 该目录，`md5` 与本地一致；
4. MCP `file_move`：`filelist=[{"path":"/apps/bdpan/_staging/up-<id>/<文件名>","dest":"<目标目录>"}]`；
5. 核对目标目录出现该文件且 `fsid` 一致；
6. `staging.sh set <id> status done`，`staging.sh clean <id>`。

### 4.2 下载任意位置的文件到本地

1. `staging.sh new dl` → `_staging/dl-<id>/`；
2. MCP `file_copy`：`filelist=[{"path":"<源文件>","dest":"/apps/bdpan/_staging/dl-<id>","newname":"<文件名>"}]`（`filelist` 是 JSON 字符串）；
3. 核对目标出现（`file_list`），记为 `remote_ready`；
4. `bdpanw.sh download _staging/dl-<id>/<文件名> <本地路径>`；本地已存在同名文件时按上游规则先确认覆盖；
5. 核对本地 `md5` 与远端 `md5`；一致后 `set status done`；
6. `clean <id>`：`bdpanw.sh rm _staging/dl-<id> --force`。

### 4.3 读应用目录之外的 txt/md 正文

与下载相同，只是把第 4 步换成 `bdpanw.sh get-content <fsid>`，读到后清理中转副本。Office/PDF 直接用 MCP `file_content_create` + `file_content_get`，不需要中转。

### 4.4 清理策略

- 只在 `done` 后清理；`failed` / 中断保留并报告路径；
- `del` 任务在 CLI 删除成功后中转目录应为空，再 `set status done` + `clean`（`clean` 会删掉空任务目录）；
- 启动时用 `staging.sh stale 7` 查看超过 7 天未清理的任务，列出后**询问用户**再清理；
- 中断的下载可能在本地留下 `.part` 文件（CLI 行为，见第 8 节），清理本地临时文件时一并处理。

## 5. 应用目录之外的删除（显式确认后启用）

**可以由 AI 主动建议，也可以由用户直接要求，但执行前必须获得用户的明确允许。** “明确允许”指用户清楚、肯定地同意你列出的对象，不要求用户预先说出路径。用户含糊、沉默、只问方法时不执行。

### 5.1 为什么是中转删除

MCP 没有删除工具，CLI 只能删 `/apps/bdpan` 内的内容。唯一可行路径是：MCP 把目标移动进 `/apps/bdpan/_staging/del-<id>/`，再用 CLI 删除。这意味着**文件会先离开原目录**，确认时必须把这一点告诉用户。

### 5.2 确认协议

1. 用 MCP `file_list` / `file_meta` 确认目标存在且唯一，记录完整路径、类型（文件/文件夹）、大小、`fsid`；
2. 向用户逐条列出：完整路径、类型、大小、将移动到 `我的应用数据/bdpan/_staging/del-<id>/` 后删除、**删除不可恢复**；
3. 等待用户明确回复“可以/删吧/同意”。明确允许可以是用户对你建议的回复，不要求预先点名路径；回复含糊、表示取消、或只问删除方法时，不执行任何移动；
4. 同一批对象已确认且集合未变时无需重复确认；新增路径、改写路径、扩大范围（例如从单个文件变成整个文件夹）必须重新确认。

### 5.3 执行与核对

1. `staging.sh new del` 创建任务；
2. `staging.sh set <id> note <原完整路径>` 记录来源，供失败回退；
3. MCP `file_move`：`filelist=[{"path":"<原路径>","dest":"/apps/bdpan/_staging/del-<id>"}]`（`filelist` 是 JSON 字符串）。移动文件夹时它会作为目标目录的子目录落入，最终路径为 `_staging/del-<id>/<名称>`；
4. 用 MCP `file_list` 核对：原位置已消失、中转目录出现同名项、`fsid` 与原值一致（实测移动不改变 `fsid`）；任一项不满足 → 停止，报告两侧实际路径；
5. `bdpanw.sh rm <中转路径> --force`（`--json` 由包装脚本自动加）；
6. 用 CLI `ls` 确认中转目录为空；
7. `staging.sh set <id> status done`，`staging.sh clean <id>`。

### 5.4 失败处理

- 移动失败：文件仍在原位，报告错误，不重试删除；
- 核对不一致：停止并保留现场，不继续删除；
- 删除失败：文件已在中转目录，报告实际路径；用户要求恢复时用 MCP `file_move` 按 `note` 记录的原路径移回，**不得**用再次删除掩盖失败；
- 任何一步无法确认结果时停止并报告，不盲目重试。

### 5.5 禁止事项

- 不擅自执行删除；提出建议时必须说明理由、对象和影响；未获明确允许不得删除；
- 可以一次列出多个对象由用户一次允许；未列入的对象不得顺手删除；
- 不删除分享链接中的文件（只处理用户自己网盘里的对象）；
- 不为了“清理空间”自行删除用户文件；
- 不使用 `/apps/bdpan` 之外的中转目录。

合规说明：开放平台《权限与配额》明确禁止“通过接口参数、路径拼接、历史链接、缓存记录等方式绕过权限边界”。同一账号下用两个官方授权通道协作操作自己的文件，技术上可行，也符合“用户明确授权删除自己文件”的意图，但这是官方文档未描述的组合用法；仅限个人自用，风险由使用者承担。若平台后续提供原生删除能力，应改用原生接口。

## 6. Token 生命周期（MCP）

- 个人授权走隐式模式：Access Token **30 天有效、不能刷新**，到期只能重新授权。
- 官方个人授权链接（不需要创建应用，也不需要 OAuth 回调）：

  ```text
  https://openapi.baidu.com/oauth/2.0/authorize?response_type=token&client_id=QHOuRXiepJBMjtk0esLhrPoNlQyYd0mF&redirect_uri=oob&scope=basic,netdisk&qrcode=1
  ```

  授权成功后浏览器跳到 `https://openapi.baidu.com/oauth/2.0/login_success#expires_in=2592000&access_token=...`；`expires_in=2592000` 就是 30 天。复制整条地址栏 URL 即可，不需要只挑 token。
- 重新授权的最小操作：`mcp-token.sh --auth-url` 打印链接 → 用户登录/扫码 → 用户复制回跳 URL → `mcp-token.sh --clipboard` 直接读取剪贴板（不打印 token）→ `--status` 确认 → 重启/重连 MCP。剪贴板不可用时让用户存临时文件，再用 `--file`。
- **真源在 1Password**（shared-credentials），本 skill 不拥有 token；`scripts/mcp-token.sh` 只负责把库里的 token 同步进宿主配置。完整约定、剩余时间算法和轮换流程见 [docs/maintenance/token.md](../../../docs/maintenance/token.md)。
- 失效特征：HTTP 400 + `{"errno":2003,"show_msg":"auth fail:token fail"}`。遇到时提示用户重新授权，不要重试。
- 写入配置用 `scripts/mcp-token.sh`：

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/mcp-token.sh --file <含 token 或回跳 URL 的文件>
bash ${CLAUDE_SKILL_DIR}/scripts/mcp-token.sh --stdin < <文件>
bash ${CLAUDE_SKILL_DIR}/scripts/mcp-token.sh --status
```

  - 原子写入（临时文件 + rename），失败自动回滚；
  - 备份**脱敏**（`Authorization` 值替换为 `Bearer <redacted>`），不留明文副本；
  - 在本机记录 token 的 sha256 摘要与**签发日期**；重写同一个 token 不会重置日期；从密钥库同步时可用 `--issued-at <日期>` 保留真实签发日期；超过 25 天打印续期警告；
  - `--status` 只读本地记录，输出 `issued_at` / `age_days` / `remaining_days` / `expires_at`；
  - `--host zcode`（默认）写 ZCode 配置；`--host hermes` 写 Hermes 的 `.env`（见 [hosts/hermes.md](./hosts/hermes.md)）；`--config <path>` 覆盖目标文件。
- **剩余时间**：MCP token 是 4 段 base64url、不是 JWT，没有 `exp`，MCP `user_info` 也不返回有效期，因此只能按 `issued_at + 30 天` 估算；CLI token 的到期时间可以用 `bdpan whoami --json` 的 `expires_at` 精确读取。两者不是同一个 token。
- 注意：宿主配置文件里的 token 是**明文**，不要同步到云盘或提交进仓库。

## 7. 遥测

- `bdpanw.sh` 默认 `BDPANW_TELEMETRY=minimal`：`--agentname` + `--session-id`，不含用户原话。
- `full`：额外带 `--session-input`（用户原话）；`none`：不带任何公共参数。
- 包装脚本只能控制显式参数。CLI 二进制自身还有上报端点与 `--anonymous-id` 等，skill 层无法关闭，不要宣称“完全无遥测”。

## 8. 实测确认与已知限制

- **CLI 下载的 `.part` + 原子替换（2026-11-25 实测）**：下载中出现 `<目标>.part`；中途终止进程后，原有同名文件**完好无损**（哨兵内容未变），`.part` 残留（约 3.2MB）；完整重下后本地 md5 与原始一致、`.part` 自动消失。结论：旧文件不会被破坏，但**中断会留下 `.part`**，需要调用方清理。
- **中转删除（2026-11-25 实测）**：文件与文件夹经 MCP `file_move` 进入 `_staging/del-<id>/` 后，`fsid` 保持不变；CLI `rm` 成功后原位置与中转目录均消失。移动文件夹时它作为子目录落入目标目录。
- **百度返回的 `md5` 不是标准 MD5**：值里含非十六进制字符（如 `fc8f9eafbjbad85a…`、`74993c5c0n…`），不能与本地 `md5sum` 比对；同一内容两次上传会得到相同的该值（可用于“同内容”判断），但不能用于本地↔远端比对。
- **`fsid` 不随重命名/移动改变（实测）**，可作为移动/重命名核对的唯一标识；复制会产生新 `fsid`。
- CLI 的 `ls /` = 应用根目录；全盘根目录用 MCP `file_list`。
- `file_keyword_search` 是模糊匹配，可能命中含相关词的其他文件，不能据此断言“不存在”。
- MCP 会话建立有随机失败（服务端 202 后不应答）；宿主会自动重连，失败时提示用户在 Settings → MCP 重连（Hermes：新开会话或 `/reload-mcp`）并重试。
- MCP 写操作失败形如 `{"errno":12,"info":[{"errno":-9,...}]}`（外层任务级、内层文件级）。
- `file_semantics_search` 结果结构为 `data[].list[]`；`file_keyword_search` 为顶层 `list[]`。
- MCP `file_meta` 一次最多 10 个 fsid；`file_content_create` 一次 1–5 个 fsid。
- 大文件/大目录的 MCP `file_copy` / `file_move` 可能返回 `taskid`；MCP 没有通用的复制/移动任务查询，需按目标目录核对（见第 3 节）。
- 容量、单文件上限、转存数量上限等属服务端规则，见 `reference/bdpan-commands.md` 与开放平台文档。
