# 开放平台文档：抓取、对比、入库

百度网盘开放平台文档是判断“平台允许什么、新增了什么”的第一手来源。它不是 API，不会推送变更，只能定期重抓。

- 入口：<https://pan.baidu.com/union/doc/>
- 页面是 Starlight 静态站，URL 尾部加 `.md` 即得 markdown 源（例：`/union/doc/基础网盘服务/上传/预上传.md`）。
- 2026-11-25 抓取结果：292 个唯一页面，约 1.27 MB，0 失败。

## 1. 抓取

```bash
node docs/maintenance/tools/scrape-union-docs.mjs /tmp/bdpan-docs-$(date +%Y%m%d)
```

脚本逻辑（与 2026-11-25 的手工抓取一致）：

1. GET 索引页，收集所有 `/union/doc/...` 链接，去重、过滤静态资源；
2. 每页请求 `<路径>.md`；
3. 在第一个标题后插入“栏目路径 | 抓取时间”；
4. 以 `栏目__子栏__页面.md` 扁平命名，避免同名覆盖；
5. 并发 6、失败重试 3 次；输出 JSON 摘要，任一页失败则退出 1。

`pages` 是去重后的页面数（按输出文件名去重；索引里可能有编码变体指向同一页），`written` 是成功写出的文件数；两者不一致时看 `failed[]`，不要静默忽略。2026-11-25 实测：292 页 / 292 文件 / 0 失败，约 5 秒。

## 2. 先看哪里

每季度重抓后，按优先级看这些页面（文件名是扁平化后的）：

| 主题 | 页面 |
|---|---|
| 权限边界 | `使用入门__权限与配额.md`、`使用入门__创建应用.md` |
| 授权方式 | `使用入门__接入授权__快速授权.md`、`使用入门__接入授权__*` |
| 错误码 | `平台简介__错误码.md` |
| MCP Server | `mcp-server__*`（工具表、授权、更新日志） |
| 更新日志 | `更新日志__文档更新日志.md` |
| 上传/下载/管理 | `基础网盘服务__上传__*`、`基础网盘服务__下载*`、`基础网盘服务__管理*` |

重点判断四件事：

1. `/apps/{appname}` 之外的访问权限有没有变化；
2. 目录级授权的“标识”有没有写清楚；
3. MCP 工具表有没有新增/删除（文档可能滞后于实测，以工具清单为准）；
4. 是否出现原生删除、跨目录删除、或新的全盘接口。

已知文档矛盾（2026-11-25）：

- 错误码 20020：一页说“下游服务异常”，另一页说“路径不在允许的访问范围内”；
- “目录级授权标识”全站未说明具体字段；
- MCP 文档只列 15 个工具，实测 25 个。

遇到矛盾时，以**实测行为和错误码**为准，并在 `reference/whole-drive.md` 记录“文档说什么、实测是什么”。

## 3. 与上一版对比

```bash
diff -rq /tmp/bdpan-docs-20260201 /tmp/bdpan-docs-20260501 | head -50
```

先看新增/删除的文件名，再看改动页的 diff：

```bash
diff -u /tmp/bdpan-docs-20260201/使用入门__权限与配额.md \
        /tmp/bdpan-docs-20260501/使用入门__权限与配额.md
```

只把影响路由、权限、删除策略的变化写进 `reference/whole-drive.md`；不要整篇复制进仓库。

## 4. 入库 WeKnora（可选，但推荐）

凭据：`weknora-ai`（shared-credentials / 1Password）。脚本：

```bash
python "$HOME/.agents/skills/weknora-manager/scripts/weknora.py" --credential-path weknora-ai ping
```

当前知识库（2026-11-25 建）：

- 名称：`百度网盘开放平台文档`
- id：`4b967e84-4ead-4861-9e27-aaf4cf91a62b`
- 内容：292 篇（291 篇批量 + `_index.md`）

重抓后的入库策略：**每次快照建一个新库**，保留旧库用于对比；不要往旧库里重复上传（会产生重复条目）。建库前先确认嵌入/摘要模型 id 仍然有效：

```bash
python "$HOME/.agents/skills/weknora-manager/scripts/weknora.py" --credential-path weknora-ai -- kb list
python "$HOME/.agents/skills/weknora-manager/scripts/weknora.py" --credential-path weknora-ai -- model list
```

建库与上传（把 `<KB_ID>` 换成新建的 id）：

```bash
python "$HOME/.agents/skills/weknora-manager/scripts/weknora.py" --credential-path weknora-ai -- \
  kb create "百度网盘开放平台文档 $(date +%Y-%m-%d)" \
  --description "pan.baidu.com/union 全站 markdown 快照" \
  --embedding-model <EMBEDDING_ID> --chat-model <CHAT_ID>

python "$HOME/.agents/skills/weknora-manager/scripts/weknora.py" --credential-path weknora-ai -- \
  doc upload "<抓取目录>" --recursive --glob '*.md' --kb <KB_ID>
```

上传是异步解析：轮询 `kb view` 的 `knowledge_count` / `is_processing`，处理完再做召回验证。验证问法要贴近文档正文，例如：

- “2026 年 6 月 3 日后创建的应用有哪些目录限制”
- “单个文件上传大小上限按会员类型分别是多少”
- “MCP 工具 file_list 的 dir 参数是什么”

宽泛问法（“MCP 有哪些工具”）可能命中相关页而不是工具表，这不代表入库失败。

## 5. 记录

每次重抓后更新 [README.md](./README.md) 基线的“开放平台文档”行（页数、抓取日期、KB id）。文档内容是公开资料，不涉及账号数据；不要把个人网盘路径或 token 写进抓取结果或知识库。
