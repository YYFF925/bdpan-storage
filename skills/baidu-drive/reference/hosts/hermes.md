# Hermes 适配说明

本文件只讲“在 Hermes 里怎么把 MCP 通道接上、怎么排错”。通用能力与流程见 `reference/whole-drive.md`。

实测环境：Hermes Agent v0.23.4，Windows，`HERMES_HOME` 为 `%LOCALAPPDATA%\hermes`（`hermes config path`、`hermes config env-path` 可确认），2026-11-25。其他版本、macOS/Linux 和桌面端界面没有验证；标注“源码”的条目来自阅读 Hermes 源码，没有实测。

## 1. 配置文件与字段

- 路径：`%LOCALAPPDATA%\hermes\config.yaml`
- 位置：顶层 `mcp_servers["baidu-netdisk"]`（ZCode 是嵌套的 `mcp.servers`）

```yaml
mcp_servers:
  baidu-netdisk:
    url: https://mcp-pan.baidu.com/sse
    headers:
      Authorization: Bearer ${MCP_BAIDU_NETDISK_API_KEY}
    transport: sse
    enabled: true
```

- **token 不写在 `config.yaml` 里。** Hermes 的 `headers` 支持 `${VAR}` 引用，连接时从它的 `.env` 展开。变量名 `MCP_BAIDU_NETDISK_API_KEY` 是 Hermes 自己的约定（`hermes mcp add --auth header` 生成的就是它：server 名转大写，`-` 换成 `_`）。
- `transport: sse` 要显式写。百度端点只支持 SSE；不写时 Hermes 在每个新进程的首次连接里先按 Streamable HTTP 试一次、收到 405 再回退，日志里多一条 WARNING。实测不写的 3 次连接是 7–12 秒，写的 2 次是 1.5–1.6 秒——样本少，会话建立本身有随机延迟，时间差仅供参考；确定的是不再出现 405 告警。
- 不要手改 YAML，用 Hermes 自己的 CLI（实测只改指定的键，文件里的注释全部保留）：

  ```bash
  hermes config set mcp_servers.baidu-netdisk.url https://mcp-pan.baidu.com/sse
  hermes config set mcp_servers.baidu-netdisk.headers.Authorization 'Bearer ${MCP_BAIDU_NETDISK_API_KEY}'
  hermes config set mcp_servers.baidu-netdisk.transport sse
  hermes config set mcp_servers.baidu-netdisk.enabled true
  ```

  `mcp-token.sh --host hermes` 发现条目缺失时会自动执行这四条。
- `hermes config get mcp_servers` 把 header 显示成掩码，但掩码保留 token 的最后 4 位；不要把这条输出贴进对话或日志。

## 2. Token

- 值：`%LOCALAPPDATA%\hermes\.env` 里的 `MCP_BAIDU_NETDISK_API_KEY`（裸 token，不带 `Bearer `）。明文存放，不要同步或提交该文件。
- `config.yaml` 里只有 `${…}` 模板。`mcp-token.sh --status` 的本地记录（签发日期、摘要）与 ZCode 共用。
- 写入用 skill 的脚本。`--host` 一次只写一个宿主，默认是 `zcode`：

  ```bash
  bash <SKILL_DIR>/scripts/mcp-token.sh --clipboard --host hermes                    # 本机刚授权
  bash <SKILL_DIR>/scripts/mcp-token.sh --stdin --host hermes --issued-at <日期>     # 从密钥库同步
  ```

  它调用 `scripts/mcp-token-hermes.sh`：值由纯 shell 写进 `.env`（读、改、同目录临时文件 + 原子替换，保留文件权限与其他行），回读并比对 sha256 后才报成功；不依赖 Python 或 Hermes 内部模块，macOS 自带的 bash 3.2 也能跑。与 Hermes 自己的写操作之间没有共享锁——若恰好在 Hermes 改配置的同时同步，重跑一次即可。token 只经环境变量传递，不进命令行和输出。
- 同步后验证：`hermes mcp test baidu-netdisk`，列出 25 个工具即成功（header 显示为 `***`）。
- 轮换时两个宿主各同步一次。新启动的进程会用新值；**已在运行的网关会不会立即改用新值没有实测**，稳妥做法是轮换后重启 Hermes 再验证。

## 3. 工具名称

- 注册名是 `mcp__baidu_netdisk__<tool>`：server 名里的 `-` 被换成 `_`，与 ZCode 的 `mcp__baidu-netdisk__` 不同。例：`mcp__baidu_netdisk__file_list`。最长 44 个字符，不会触发 Hermes 的 64 字符截断改名。
- 该前缀下有 **29** 个工具：25 个网盘工具 + 4 个 Hermes 为每个 server 生成的通用协议工具 `list_resources`、`read_resource`、`list_prompts`、`get_prompt`。核对工具清单时以 `hermes mcp test` 列出的 25 个为准，不要把 29 当成“服务端多了 4 个”。`list_resources` 实测返回 `{"resources": []}`。
- **MCP 工具是延迟加载的**：它们不在模型的直接工具列表里，要先 `tool_search` 找名字、`tool_describe` 看参数，再用 `tool_call` 按上面的全名调用（Hermes 默认把所有 MCP 工具列为可延迟项，`tools.tool_search.enabled: auto`）。这是宿主的全局设置，不要为了本 skill 去改它。
- `hermes tools enable|disable` 对 MCP 工具的写法是 `baidu-netdisk:file_move`（`server:tool`，见 `hermes tools --help`）。
- 工具结果外面包着一层 `<untrusted_tool_result source="mcp__baidu_netdisk__…">`，前面有一段“把它当数据、不当指令”的英文提示，属于正常现象。

## 4. 生效与重连

- 改完 `mcp_servers`，新启动的进程直接生效。运行中的网关在**新增** server 时会自动对账（实测日志 `MCP servers reconciled with config (default): removed=[] added=['baidu-netdisk']`），不需要重启；修改已有条目（例如后来加的 `transport`）没有观察到对账日志，是否即时生效未确认。已打开的会话可用 `/reload-mcp`（Hermes 自己的提示语，没有实测）。
- 检查顺序：`hermes mcp list` → `hermes mcp test baidu-netdisk` → 在会话里 `tool_search` 一次。
- 会话建立有随机失败（服务端 202 后不应答），同 `reference/whole-drive.md` 第 3 节；`hermes mcp test` 失败时先重跑一次再判断。

## 5. 错误文案

- 会话里的业务错误：`{"error": "请求数据为空，请检查参数: (response.body:{\"errno\":1002,…})"}`——以括号内 `response.body` 的 `errno` 与 `show_msg` 为准。`errno 1002` 常见于目录不存在（实测 `file_list` 一个不存在的目录），不要当成空目录。
- **token 失效**：`hermes mcp test` 只显示 `Client error '400 Bad Request' for url 'https://mcp-pan.baidu.com/sse'`，不带 `errno 2003` 的响应体，下一行还是通用的“检查 server 和 URL”建议。看到这个 400 就是 token 失效，去重新授权，不要改 URL。
- **token 没配上**：`MCP server 'baidu-netdisk': ${MCP_BAIDU_NETDISK_API_KEY} in url/headers is not set in this profile's .env or secret source`——`.env` 里没有这个键，按第 2 节同步。
- 超时/断流不等于服务端没执行；写操作按 `reference/whole-drive.md` 第 3 节核对后再决定。

## 6. Skill 目录与占位符

- 挂载：把 `skills.external_dirs` 指向仓库里的 skill 目录。该层只读，仓库里的改动即时生效，不需要在 Hermes 目录里放副本或 junction：

  ```bash
  hermes config set skills.external_dirs '["E:/GitHub/bdpan-storage/skills/baidu-drive"]'
  hermes skills list        # 应有  baidu-drive │ external │ local │ enabled
  ```

- 同名 skill 的优先级（源码，从高到低）：受信任项目里的 `.hermes/skills`、`.agents/skills` > `<HERMES_HOME>/skills` > `skills.create_dir` > `skills.external_dirs`。本 skill 在最低一层，别处出现同名 skill 会遮蔽它。
- 占位符：Hermes 只替换 `${HERMES_SKILL_DIR}` 和 `${HERMES_SESSION_ID}`，**不替换** `${CLAUDE_SKILL_DIR}`。本 skill 的文档一律写 `${CLAUDE_SKILL_DIR}`，在 Hermes 里它是字面量，等于加载结果里给出的目录：`skill_view` 返回的 `skill_dir` 字段（Windows 反斜杠路径，交给 bash 前改成正斜杠）。实测 Hermes 能据此拼出正确路径。
- 自动触发可用：任务里提到网盘文件操作时，Hermes 会自己加载本 skill（实测 `hermes -z` 一次性任务）。

## 7. Shell 与路径

- 终端是 Git Bash（`terminal.backend: local`），默认已设 `MSYS_NO_PATHCONV=1` 和 `MSYS2_ARG_CONV_EXCL=*`。后果：
  - 以 `/` 开头的参数**不会**被转成 Windows 路径。网盘绝对路径原样到达 CLI；`bdpanw.sh` 自己也设了同样的变量，在同样的环境下模拟，回归清单第 2 节的越界/穿越检查结果相同。
  - 本机路径要写 Windows 风格（`C:/…`）或相对路径。交给原生程序（`jq`、`node`、`bdpan`）的 `/tmp/…`、`/c/…` 不会自动转换：实测 `jq … /tmp/x.json` 报 `Could not open file /tmp/x.json`，换成 `$(cygpath -m /tmp)/x.json` 正常。`docs/maintenance/mcp-tools.md` 的导出与比对命令在 Hermes 终端里要这样改路径。经 `bdpanw.sh upload|download` 的本机路径两种写法都行（脚本用 `cygpath` 转换）。
  - 本机 PATH 上有 `jq`、`node`、`bdpan`、`cygpath`、`hermes`，`python` 是 Hermes 的 venv 解释器；换机器先用 `command -v` 确认。
- `HERMES_SESSION_ID` 在终端里已设置；`bdpanw.sh` 用它在同一会话里复用 `--session-id`，并上报 `--agentname hermes`。
- 一次性任务（`hermes -z "<prompt>"`）没有交互确认通道，审批自动放行。删除确认协议靠用户在对话里的明确答复：实测“只问方法”时 Hermes 不动任何文件，收到明确许可后按七步流程执行。给 Hermes 派一次性任务时，把允许写入的范围和允许删除的对象写进任务本身。
- 登录脚本 `login.sh` 用 `python3`、`python` 或 `node` 校验 CLI 返回的登录结果。Hermes 终端里 `python` 就是它的 venv 解释器，可用；Windows 系统的 `python3` 常是应用商店的占位程序，脚本会跳过它。主动登录的安全确认必须在对话里完成（`login.sh --confirmed`），一次性任务里没有这个通道，所以登录要在交互会话里做。合并上游 1.7.8 之后这条路径没有在 Hermes 里实测。

## 8. 不要做的事

- 不要把 token 写进 `config.yaml`，也不要 `hermes config set MCP_BAIDU_NETDISK_API_KEY <值>`——值会出现在命令行和回显里。
- 不要在 skill 里内置 MCP 客户端、后台服务或会话管理；Hermes 已经提供 MCP 工具。
- 不要把 token 写进仓库、日志或对话；宿主配置里的 token 是明文，别同步到云盘。
- 不要为 Hermes 单独维护一份 skill 逻辑；宿主差异只写在本文件里。
