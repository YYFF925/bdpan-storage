# 更新检查与合并

本文覆盖官方 skill、`bdpan` CLI、MCP Server 三条更新轨道，以及各自的检查命令和冲突处理。开放平台文档单独见 [open-docs.md](./open-docs.md)。

## 0. 先记版本

```bash
cat skills/baidu-drive/VERSION
bash skills/baidu-drive/scripts/bdpanw.sh version
```

把 skill 版本、CLI 版本、MCP 工具数记在一起，升级后对照。基线见 [README.md](./README.md)。

## 1. 官方 skill（git upstream）

### 检查

```bash
cd <repo>
git fetch upstream --prune
git log --oneline --no-decorate HEAD..upstream/main   # 落后哪些提交
git rev-list --left-right --count HEAD...upstream/main # 左=本地独有，右=上游独有
bash skills/baidu-drive/scripts/update.sh --check      # 官方 conf_key 里的 VERSION
```

`update.sh --check` 比较的是官方渠道公布的 skill 版本；git 落后提交数看的是仓库内容。两者都要看：官方可能只发版本号、也可能先合并代码。

### 合并

```bash
git merge upstream/main
```

预期冲突只有两类：

| 文件 | 原因 | 处理 |
|---|---|---|
| `skills/baidu-drive/scripts/update.sh` | 本 fork 有意重写（停用官方包覆盖，改分轨更新） | **保留本 fork 版本**；如果上游新增了版本检查逻辑，手工把有价值的部分并进来 |
| `skills/baidu-drive/SKILL.md` | 本 fork 改了 description 和“全盘管理”章节 | 保留本 fork 的 frontmatter 与全盘章节；上游对原有规则行的修正照收 |

其他文件（`reference/bdpan-commands.md`、`install.sh`、`login.sh` 等）优先接受上游；`login.sh` / `install.sh` 如果上游也修了同一处，合并后以“两种修复都保留”为目标，无法兼容时以本 fork 的 Windows / 非交互行为为准，并在提交说明里写清。

**禁止** `git merge -X ours`、`git checkout --ours` 整文件丢弃上游。合并后：

1. 跑 [regression.md](../../skills/baidu-drive/reference/regression.md)；
2. 更新 [README.md](./README.md) 的基线表；
3. 检查 `VERSION` 是否需要跟上游同步（本 fork 的 VERSION 跟上游走，不单独编号）。

### 发布渠道

GitHub 仓库右侧 **Watch → Custom → Releases** 订阅 upstream 的 release/commit 通知，是最省事的“主动发现”。个人自用，不需要额外的监控服务。

## 2. `bdpan` CLI

### 检查

```bash
bash skills/baidu-drive/scripts/bdpanw.sh version
```

当前基线 3.8.9（skill 1.7.7 的配套版本）。CLI 是闭源二进制，版本变化可能带来参数和 JSON 变化。

### 更新

```bash
bdpan update          # 由用户明确触发；Agent 不自动执行
```

升级后立刻跑回归。`bdpanw.sh` 每次调用都带 `--no-check-update`，避免任务中途被自更新打断；这不会阻止用户主动升级。

### 依赖面

本 fork 依赖的命令、参数、JSON 字段清单在 [contracts/cli-surface.txt](./contracts/cli-surface.txt)。重点：

- 信封：`code` / `status` / `errno` / `authenticated`；`bdpanw.sh` 按内容判成败；
- 上传：`data.action`、`data.saved_path`、`data.size`；
- 列表：`fsid` / `fs_id`、`return_markdown`；
- `whoami`：`expires_at`（CLI token 的精确到期时间）；
- 删除：`rm --force` 对文件夹递归；
- 读正文：`task_id`、`status`；
- 转存：`task_id`、`status=submitted`。

出现 `unknown command` / `unknown flag` / 字段缺失：

1. 停止，不改用旧参数或猜测参数；
2. 记录命令、版本、原样错误；
3. 跑回归确认影响面；
4. 更新 `bdpanw.sh`（信封/路径）或文档（参数），并把新契约写进 `cli-surface.txt`。

## 3. MCP Server

MCP 是服务端能力，没有可安装的版本，也没有公开的版本查询接口。**工具清单就是契约**：

```bash
# token 从 1Password 取（见 token.md），不落文件、不进 argv
python "$USERPROFILE/.agents/skills/shared-credentials/scripts/credentials.py" run \
  --id baidu-netdisk-mcp -- node docs/maintenance/tools/mcp-call.mjs tools \
  > /tmp/mcp-tools.current.json

node docs/maintenance/tools/compare-mcp-tools.mjs \
  docs/maintenance/contracts/mcp-tools.baseline.json /tmp/mcp-tools.current.json
```

- 退出 0：无变化；
- 退出 1：有增删或 schema 变化，按 [mcp-tools.md](./mcp-tools.md) 分类处理；
- 会话建立随机失败：客户端会自动换新会话重试；仍失败时在 ZCode Settings → MCP 重连，不要重复发写操作。

如果出现原生删除工具，或平台开放了跨目录删除权限：先评估，再把全盘删除从“移动 + CLI 删除”切到原生工具；切换前保留当前实现作为回退。

## 4. 提交前检查

- 回归通过，失败项已记录且未静默忽略；
- 维护手册的基线和契约文件已更新；
- 没有把 token、授权码、真实文件名、内部地址写进文档或提交；
- 未自动提交（是否提交由用户决定）。
