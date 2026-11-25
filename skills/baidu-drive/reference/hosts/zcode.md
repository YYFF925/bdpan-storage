# ZCode 适配说明

本文件只讲“在 ZCode 里怎么把 MCP 通道接上、怎么排错”。通用能力与流程见 `reference/whole-drive.md`。

## 1. 配置文件与字段

- 路径：`~/.zcode/cli/config.json`
- 位置：`mcp.servers["baidu-netdisk"]`（注意是嵌套的 `mcp.servers`，不是顶层 `mcpServers`）
- 字段（严格校验，出现未知字段会整条 server 被丢弃）：

```json
{
  "mcp": {
    "servers": {
      "baidu-netdisk": {
        "type": "sse",
        "url": "https://mcp-pan.baidu.com/sse",
        "headers": { "Authorization": "Bearer <token>" }
      }
    }
  }
}
```

- 不要手工拼 JSON。用 skill 的脚本写入（原子写入 + 脱敏备份）：

```bash
bash <SKILL_DIR>/scripts/mcp-token.sh --file <含 token 或回跳 URL 的文件>
```

## 2. 获取 Token（个人使用）

1. 打开官方授权链接（客户端 `client_id` 固定、`scope=basic,netdisk`、`qrcode=1`、`redirect_uri=oob`，见官方 MCP 文档）；
2. 用百度网盘 App 扫码并授权；
3. 浏览器跳到 `https://openapi.baidu.com/oauth/2.0/login_success#...`，复制**整条地址**；
4. 保存到本地文本文件（**不要把 token 贴进对话**）；
5. 执行 `mcp-token.sh --file <该文件>`，然后删除该文件。

Token 30 天有效、不能刷新；到期重新走一遍。`mcp-token.sh` 会记录签发日期，超过 25 天提示续期。

## 3. 工具名称

ZCode 里工具名带前缀：`mcp__baidu-netdisk__<tool>`，例如

- `mcp__baidu-netdisk__file_list`
- `mcp__baidu-netdisk__file_move`
- `mcp__baidu-netdisk__get_quota`

写文档或对用户描述时用不带前缀的工具名（`file_list`），调用时按 ZCode 的实际注册名。

## 4. 生效与重连

- MCP server 在**会话启动时**连接：改完配置需要新开会话（或重启 ZCode）。
- 查看状态：**Settings → MCP**；显示 `failed` 时先看错误文案里的原因。
- 服务端偶发“接受请求但不应答”（`initialize` 无回复）：在 Settings → MCP 重连，或新开会话重试。
- 工具列表变化时（服务端升级），用 `tools/list` 核对，不要假设数量固定（当前 25 个）。

## 5. 错误文案

- ZCode 把 MCP 业务错误显示为：`The system is busy, please try again later: (response.body:{"errno":...,"show_msg":"..."})`
  —— 首句有误导性，**以括号内的 `errno` 与 `show_msg` 为准**。
- 常见：`errno 2003 / auth fail:token fail` = token 失效，重新授权；`errno 1002` = 请求为空（常见于目录不存在）。
- 超时/断流不等于服务端没执行；写操作按 `reference/whole-drive.md` 第 3 节核对后再决定。

## 6. Skill 目录与占位符

- ZCode 从 `~/.zcode/skills`、`~/.agents/skills` 以及工作区的 `.zcode/skills`、`.agents/skills` 发现 skill；同名时按发现顺序取第一个。
- 本 skill 的脚本路径写的是 `${CLAUDE_SKILL_DIR}`；在 ZCode 里它等于**加载 skill 时给出的 Base directory**。ZCode 自带 skill 使用 `${ZCODE_SKILL_DIR}`，本 skill 不依赖它。
- 安装到 ZCode：把仓库的 `skills/baidu-drive` 以目录联接方式挂到 `~/.agents/skills/baidu-drive`，改仓库即时生效。

## 7. 不要做的事

- 不要在 skill 里内置 MCP 客户端、后台服务或会话管理；ZCode 已经提供 MCP 工具。
- 不要把 token 写进仓库、日志或对话；宿主配置里的 token 是明文，别同步到云盘。
- 不要为 ZCode 单独维护一份 skill 逻辑；宿主差异只写在本文件里。
