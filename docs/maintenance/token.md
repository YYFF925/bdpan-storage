# Token：位置、剩余时间、1Password 集成

先分清两个 token，它们不是同一个东西：

| Token | 用途 | 存放位置 | 有效期 |
|---|---|---|---|
| CLI token | `bdpan` CLI 登录（whoami、上传下载、删除…） | `~/.config/bdpan/config.json`（**不要读取或输出内容**） | `bdpan whoami --json` 的 `expires_at`；上游文档称快过期自动刷新 |
| MCP token | 连接官方 MCP Server `https://mcp-pan.baidu.com/sse` | ZCode：配置里的 `mcp.servers["baidu-netdisk"].headers.Authorization`；Hermes：`.env` 里的 `MCP_BAIDU_NETDISK_API_KEY` | 授权后 30 天，不能刷新 |

本页主要讲 MCP token。CLI token 的登录、续期走 `scripts/login.sh`，不在本项目维护范围内。

## 1. 当前写在哪里

MCP token：

- 值：`%USERPROFILE%\.zcode\cli\config.json` → `mcp.servers["baidu-netdisk"].headers.Authorization`，形式是 `Bearer <token>`；
- 本地元数据：`%LOCALAPPDATA%\baidu-drive\mcp-token\state.env`（Windows）或 `~/.cache/baidu-drive/mcp-token/state.env`（Linux/macOS），内容只有：
  - `token_sha256`：token 的 sha256 前 16 位；
  - `issued_at`：本地记录的签发时间。
- 注意：ZCode 配置里的 token 是**明文**；不要同步到云盘、不要提交进仓库。`mcp-token.sh` 写配置时只生成脱敏备份（`Authorization` 替换为 `Bearer <redacted>`）。

Hermes（2026-11-25 起）：

- 值：`%LOCALAPPDATA%\hermes\.env` 里的 `MCP_BAIDU_NETDISK_API_KEY`（裸 token）。这是 Hermes 自己的约定：`config.yaml` 里只写 `Authorization: Bearer ${MCP_BAIDU_NETDISK_API_KEY}`，连接时才展开，所以 `config.yaml` 里没有明文；
- `config.yaml` 的 `mcp_servers.baidu-netdisk` 另有 `url`、`transport: sse`、`enabled: true`；
- 本地元数据与 ZCode 共用同一个 `state.env`，`mcp-token.sh --status` 不区分宿主；
- 细节与已知限制见 [hosts/hermes.md](../../skills/baidu-drive/reference/hosts/hermes.md)。

CLI token：

- 由 `bdpan login` 写入 `~/.config/bdpan/config.json`；本 skill 明确禁止读取该文件内容。
- 到期时间可以直接查：

```bash
bash skills/baidu-drive/scripts/bdpanw.sh whoami | jq -r '.expires_at'
```

2026-11-25 实测：`2026-12-25T09:44:50+08:00`。

上游 `reference/authentication.md` 写明“Token 快过期时工具会自动刷新”，所以正常情况下不需要每 30 天手动登录。当天无法实测刷新行为（尚未接近到期）；如果 `whoami` 返回未登录、或操作报 Token 过期，按 `scripts/login.sh` 重新登录即可。建议每月看一次 `expires_at` 是否在临近到期时向后移动；不移动就说明自动续期没有生效。

## 2. 剩余时间能不能拿到

**MCP token：拿不到服务端确认的精确到期时间，只能按签发时间估算。**

依据：

- token 是 83 个字符、4 段 base64url（形如 `xxx.<32>.<39>.<6>`），**不是 JWT**，没有可解码的 `exp`；
- MCP `user_info` 只返回账号信息（`errno`、`vip_type` 等），没有 token 有效期字段；
- 开放平台文档只写“Access Token 30 天、不可刷新”，没有 token introspection / 查询接口；
- 失效特征是 HTTP 400 + `{"errno":2003,"show_msg":"auth fail:token fail"}`，不是提前给出剩余时间。

本地能做的估算：

```bash
bash skills/baidu-drive/scripts/mcp-token.sh --status
```

输出：

```text
issued_at=2026-11-25T14:48:41
age_days=0
remaining_days=29
expires_at=2026-12-25T14:48:41+0800
expired=no
```

`issued_at` 优先来自本地记录；从 1Password 同步时可以用 `--issued-at` 传入真实签发日期，避免换机器后重置。剩余天数按 `issued_at + 30 天` 计算，是**窗口估算**，不是服务端回执。

CLI token 则相反：`whoami` 直接返回精确的 `expires_at`，且上游文档说明会自动续期；MCP token 不支持刷新，30 天后必须重新授权。

## 3. 1Password 集成（已启用）

真源放在 shared-credentials 的 1Password 库里，本项目只负责“取出来、同步进宿主配置”，不负责签发和续期。`credentials.py` 冷启动可能很慢（2026-11-25 实测 `check` 超过 2 分钟才返回），脚本里调用要给足超时。

### 3.1 条目（已建立，2026-11-25）

| 项 | 实际值 |
|---|---|
| Vault | `Agent Credentials` |
| 标题 | `百度网盘 MCP Token` |
| `credential_id` | `baidu-netdisk-mcp`（冻结契约，改它等于改调用方） |
| 字段 | `MCP_TOKEN`（ASCII id，放在“凭据”段；值是裸 token） |
| 字段 | `ISSUED_AT`，值为 `2026-11-25T14:48:41` |
| 元数据 | `_CREDENTIAL_INFO`：target.url=`https://mcp-pan.baidu.com/sse`，expires_at=`2026-12-25T14:48:41+08:00`，`metadata_status=complete` |

2026-11-25 核对：`run` 注入的 token 长度 83、sha256 前 16 位与本地状态完全一致；拿库里的 token 直接做 MCP 握手成功（服务端 `MCP SSE Server 1.0.0`）。

字段值只通过 `credentials.py set` 的弹窗、`--file` 或管道写入；不要粘进对话。

#### 权限说明

本机 shared-credentials 的 Service Account 对 `Agent Credentials` 只有读权限；2026-11-25 首次由本机创建条目时报：

```text
ERROR: op item create failed: ... Permission: (101) You do not have permission to perform this action
```

条目最终由 Hermes（有写权限）创建。本机只读即可完成读取、同步和验证；以后轮换时如果本机 SA 仍无写权限，继续由 Hermes 更新，或先给 SA 授予 Create/Edit 权限。不要反复重试或改用 `op read`。

### 3.2 同步到宿主

`mcp-token.sh` 一次只写一个宿主（`--host` 默认是 `zcode`），两个宿主各同步一次。

ZCode：

```bash
python "$USERPROFILE/.agents/skills/shared-credentials/scripts/credentials.py" run \
  --id baidu-netdisk-mcp -- \
  sh -c 'printf %s "$MCP_TOKEN" | bash "$HOME/.agents/skills/baidu-drive/scripts/mcp-token.sh" --stdin --issued-at "$ISSUED_AT"'
```

- `run` 把“凭据”段字段注入子进程环境，token 只存在于该子进程；
- `mcp-token.sh` 从 stdin 读，不把 token 放上命令行；
- 本机刚重新授权时也可以直接用 `--clipboard`（见 3.4），不必经过 1Password；但之后要把新 token 登记回库；
- `--issued-at "$ISSUED_AT"` 在字段存在时保留真实签发日期；为空时脚本按“新 token，现在签发”处理；
- 脚本输出只包含配置路径、脱敏备份路径、token 长度和签发日期，不输出 token。

同步后：

1. `mcp-token.sh --status` 确认 `issued_at` / `remaining_days`；
2. 重启 ZCode 或在 Settings → MCP 重连；
3. 做一次只读验证（`user_info` 或 `file_list` 根目录）。

2026-11-25 实测：从库中 `run` 注入 token，按上面的命令写入临时 config，`token_length=83`、`issued_at` 保留、Authorization header 正确；未触碰真实 ZCode 配置。

Hermes：同一条命令加 `--host hermes`（本机刚授权的场景是 `mcp-token.sh --clipboard --host hermes`）。脚本把值写进 Hermes 的 `.env`，`config.yaml` 只保留 `${…}` 模板，`mcp_servers.baidu-netdisk` 条目缺失时会自动补建；同步后跑 `hermes mcp test baidu-netdisk`，列出 25 个工具即成功。2026-11-25 实测（真实 Hermes，真 token）：17 秒完成，输出 `server_added:false`，`issued_at` 保持原值，`.env` 里该键只有一行，`config.yaml` 和 `.env` 相对运行前逐项一致；`config.yaml` 相对接入前只多了 `mcp_servers.baidu-netdisk` 下的键和 `skills.external_dirs`，注释全部保留。

### 3.3 为什么还需要“同步”这一步

ZCode 当前的 MCP 配置是静态 header，文档没有提供环境变量或命令式 header 的插值。MCP 连接在会话启动时建立，宿主不会每次去 1Password 取 token。Hermes 的 header 支持 `${VAR}` 引用，但引用的是它自己 `.env` 里的值，同样不会去 1Password 取。因此：

- **1Password 是唯一真源**；
- `mcp-token.sh` 只是“把真源写进宿主配置”的同步器，不拥有 token、不判断续期；
- 如果未来宿主支持直接引用密钥库（例如 Hermes 自带的 `hermes secrets onepassword`），这一步可以删掉；那需要把 1Password 的 Service Account token 交给 Hermes，是否启用另行决定。

### 3.4 重新授权（最小操作）

官方个人授权链接（不需要创建应用，也不需要 OAuth 回调）：

```text
https://openapi.baidu.com/oauth/2.0/authorize?response_type=token&client_id=QHOuRXiepJBMjtk0esLhrPoNlQyYd0mF&redirect_uri=oob&scope=basic,netdisk&qrcode=1
```

`bash scripts/mcp-token.sh --auth-url` 会打印同一条链接，避免去文档里找。

1. 打开链接，登录百度账号并授权（可扫码）；
2. 成功后浏览器地址栏是 `https://openapi.baidu.com/oauth/2.0/login_success#expires_in=2592000&access_token=...`；复制**整条 URL**（`expires_in=2592000` 就是 30 天）；
3. 运行 `bash scripts/mcp-token.sh --clipboard`（Hermes 里加 `--host hermes`）。脚本从剪贴板读取，不打印 token；不需要粘进对话或保存文件。剪贴板不可用时，把 URL 存到临时文件，再用 `--file`；
4. 运行 `--status` 确认 `issued_at` 和剩余天数；
5. 重启 ZCode / 重连 MCP（Hermes：同步后新开会话；轮换后稳妥起见重启 Hermes），做一次只读验证；
6. 已接入 1Password 时，把新的 `MCP_TOKEN` / `ISSUED_AT` 更新回库；顺序可以是“先库后本机”或“先本机后库”，但两边最终要一致。

### 3.5 轮换与过期处理

1. 重新走 3.4，拿到新 token（或 `login_success` URL）；
2. 在 1Password 里更新 `MCP_TOKEN` 和 `ISSUED_AT`（弹窗输入，值不进对话）；
3. 执行 3.2 的同步命令（两个宿主各一次）；
4. 重启 ZCode / 重连 MCP（Hermes 稳妥起见重启）；
5. 只读验证；
6. 旧 token 失效属于预期；确认新 token 可用后再清理旧备份（备份本身已脱敏）。

多台机器各自同步自己的 ZCode 配置；不要把 `config.json` 在机器间复制，也不要把 token 写进任何仓库文件。

## 4. 安全规则

- token、授权码不进对话、工具输出、日志、Git、文档；
- 只报长度、sha256 前缀、字段名；
- 不直接 `op read` 把值打到 stdout；读取走 `credentials.py run`；
- 不把 token 放进命令行参数（`ps` 可见）；`mcp-token.sh` 只接受 `--file` / `--stdin`；
- 写配置用原子写入，失败回滚；备份必须脱敏；
- 发现 `2003 auth fail` 时停止并提示重新授权，不重试、不猜测。
