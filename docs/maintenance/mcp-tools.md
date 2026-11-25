# MCP 工具清单：基线、导出、比对

MCP Server 没有版本号，也没有“检查更新”接口。**工具清单（名称 + 参数 schema）就是契约**。基线文件：

- [contracts/mcp-tools.baseline.json](./contracts/mcp-tools.baseline.json)
- 抓取日期：2026-11-25
- 工具数：25
- 服务端标识：`MCP SSE Server 1.0.0`，协议 `2024-11-05`
- 结构：`{ok, stage, server, count, tools[], captured_at}`；每个 tool 含 `name`、`description`、`required`、`props`、`schema`

## 1. 导出当前清单

token 从 1Password 取（见 [token.md](./token.md)），只进子进程环境，不落文件、不进 argv：

```bash
python "$USERPROFILE/.agents/skills/shared-credentials/scripts/credentials.py" run \
  --id baidu-netdisk-mcp -- \
  node docs/maintenance/tools/mcp-call.mjs tools > /tmp/mcp-tools.current.json
```

检查结果：

```bash
jq -r '.ok, .count, .server.version' /tmp/mcp-tools.current.json
```

`mcp-call.mjs` 是维护工具，放在 `docs/maintenance/tools/`，**不被 skill 加载**，也不参与日常文件操作。它会自动处理官方的 `ping`、换新会话重试；token 只从 `MCP_TOKEN` 或 token 文件读取，输出和错误里都会脱敏。

## 2. 比对

```bash
node docs/maintenance/tools/compare-mcp-tools.mjs \
  docs/maintenance/contracts/mcp-tools.baseline.json /tmp/mcp-tools.current.json
```

输出：

```json
{
  "ok": false,
  "added": ["new_tool"],
  "removed": ["old_tool"],
  "changed": [
    { "name": "file_move", "fields": ["required", "schema"], "props_added": [], "props_removed": [] }
  ]
}
```

- 退出 0：无变化；
- 退出 1：有变化；
- 退出 2：文件读不了或结构不对。

## 3. 变更分类与处理

| 变化 | 影响 | 处理 |
|---|---|---|
| 新增工具 | 可能是新能力（例如原生删除、跨目录权限） | 先读 schema，做一次只读验证；评估是否改变路由；写进 `reference/whole-drive.md`；涉及删除时先讨论再启用 |
| 删除工具 | 现有路由可能失效 | 从文档和路由里移除；找替代工具；在回归里标注“不可用” |
| `required` / `props` / `schema` 变化 | 调用会报参数错误 | 按新 schema 改调用示例；先用只读调用验证；更新 `whole-drive.md` 与宿主文档 |
| 仅 `description` 变化 | 可能是行为/限制变化 | 记录差异；用只读调用确认实际行为，不只看文案 |
| 工具数不变但行为变化 | schema 看不出来 | 只能靠回归和实际使用发现；出现异常时按 [whole-drive.md 第 3 节](../../skills/baidu-drive/reference/whole-drive.md) 核对 |

变更确认后：

1. 把 `/tmp/mcp-tools.current.json` 复制为新的 baseline，补 `captured_at`；
2. 更新本页和 [README.md](./README.md) 的基线表；
3. 跑一遍 [regression.md](../../skills/baidu-drive/reference/regression.md) 的 MCP 部分；
4. 是否提交由用户决定。

## 4. 本 skill 依赖的核心工具

| 用途 | 工具 |
|---|---|
| 列目录 / 搜索 | `file_list`、`file_doc_list`、`file_image_list`、`file_video_list`、`file_keyword_search`、`file_semantics_search` |
| 详情 | `file_meta`（一次 ≤10 个 fsid） |
| 建目录 | `make_dir`（`rtype` 0 冲突失败 / 1 改名 / 2 按 MD5 / 4 覆盖） |
| 整理 | `file_copy`、`file_move`、`file_rename`（`filelist` JSON 字符串、`async` 0/1/2、`ondup`） |
| 写文件 | `file_upload_by_content`（≤2 万字）、`file_upload_by_url` |
| 读正文 | `file_content_create`（1–5 个 fsid）、`file_content_get` |
| 分享 / 转存 | `file_sharelink_set`、`file_sharelink_list`、`file_sharelink_verify`、`file_sharelink_transfer`、`file_sharelink_taskquery` |
| 账号 | `user_info`、`get_quota` |
| 只生成 CLI 提示词 | `file_upload`、`file_download`、`file_sharelink_download`（不传输文件，不要用于实际进出） |

## 5. 已知参数与行为（2026-11-25 实测）

- **`filelist` 是 JSON 字符串**，不是数组，也不是顶层 `path`/`dest`：
  `filelist=[{"path":"/源","dest":"/目标目录","newname":"可选"}]`。
- `file_move` 移动文件夹时，文件夹作为目标目录的子目录落入。
- `file_list` 对不存在的目录返回 `errno 1002`，不要当成空目录。
- `file_keyword_search` 是模糊匹配，不能据此断言“不存在”。
- `file_semantics_search` 结果是 `data[].list[]`；`file_keyword_search` 是顶层 `list[]`。
- 写操作失败可能是 `{"errno":12,"info":[{"errno":-9,...}]}`：外层任务级、内层文件级。
- `file_meta` 一次最多 10 个 fsid；`file_content_create` 一次 1–5 个。
- 会话建立有随机失败（202 后不应答）；维护客户端会自动换新会话，宿主侧在 Settings → MCP 重连。
- 大目录复制/移动可能返回 `taskid`，MCP 没有通用任务查询，按目标目录核对。
