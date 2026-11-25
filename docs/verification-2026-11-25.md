# 百度网盘 skill 双通道验证报告

- 日期：2026-11-25
- 范围：`bdpan-storage` 仓库的 `baidu-drive` skill、官方 `bdpan` CLI、百度网盘官方 MCP Server、ZCode 宿主
- 状态：验证全部完成；双通道 skill 的实现方案已获批准，但按用户要求暂停，尚未修改仓库
- 相关计划：`docs/` 外无其他记录文件；本报告即本次工作的完整留档

## 0. 文档说明与脱敏约定

本文档按时间顺序记录本次验证的**全部过程、每条命令、每项结果、每个问题和处理方式**，不省略步骤。

出于安全与隐私，以下内容**不写入**本文档，其余细节全部保留：

- 任何凭据、令牌、授权码、Service Account token、API Key；
- 账号标识（用户名、uid 等）、账号容量以外的个人数据；
- 用户网盘中真实文件的名称与路径（仅保留本次自建测试文件的名字）；
- 内网服务域名与内网 IP（用“内网反代域名（略）”“内网主机（略）”代替），公开域名（如 `pan.baidu.com`、`mcp-pan.baidu.com`）正常出现。

## 1. 结论摘要

### 1.1 六项需求的落地方式与验证结果

| 需求 | 做法 | 验证结果 |
|---|---|---|
| 创建文件夹 / 按文本内容建文件 | MCP `make_dir`、`file_upload_by_content` | 通过，含网盘根目录 |
| 查找 | MCP `file_keyword_search`、`file_semantics_search` | 通过，全盘范围 |
| 移动 / 重命名 / 复制 | MCP `file_move`、`file_rename`、`file_copy` | 通过 |
| 上传本地文件到任意位置 | CLI 上传到 `/apps/bdpan`，MCP 移到目标目录 | 通过（中转） |
| 下载任意位置的文件到本地 | MCP 复制到 `/apps/bdpan`，CLI 下载，再删副本 | 通过（中转），内容逐字节一致 |
| 删除任意位置的文件 | MCP 移到 `/apps/bdpan`，CLI 删除 | 通过（中转），删除后 MCP 侧确认消失 |

### 1.2 关键事实

1. **`/apps/bdpan` 的目录边界属于 bdpan CLI 自身**（内置 PathGuard + 应用授权范围），不是 skill 规则，改 skill 无法放开。实测：`路径超出授权目录范围`、`路径穿越攻击被阻止`、盘符路径被服务端以 `errno=-7` 拒绝。
2. **百度网盘官方 MCP Server 覆盖全盘**。实测 `file_list` 列根目录返回 10 个文件夹；全盘关键词/语义搜索能找到 `/apps/bdpan` 内的文件。
3. **MCP 实际提供 25 个工具**，文档只列了 15 个。多出的包括：`file_upload_by_content`、`file_content_create`、`file_content_get`、`file_sharelink_list/verify/transfer/taskquery/download`、`file_upload`、`file_download`。
4. **MCP 没有删除工具**；`file_upload`、`file_download`、`file_sharelink_download` **不传输文件**，只生成让 Agent 调用本地 CLI 的提示词，且目标限定 `/apps/bdpan`。真正由服务端执行、覆盖全盘的是列表、搜索、详情、建目录、复制、移动、重命名、按 URL/文本存文件、读 Office/PDF 正文、分享转存。
5. **MCP 能读也能写 `/apps/bdpan`**，因此本地文件的全盘进出、全盘删除可以借 `/apps/bdpan` 中转，三条中转路径均实测通过。
6. **ZCode 里 25 个工具全部注册且可调用**；日志记录 `toolCount: 25`，直接调用三个“疑似缺失”的工具均成功。

### 1.3 仍不确定 / 未做的事

- 双通道 skill 的代码实现（方案已批准，暂停中）。
- Hermes Agent、dsh 两个宿主的适配（本轮只验证 ZCode）。
- MCP 个人令牌 30 天有效且不能刷新，约 2026-12-25 到期，需重新授权。
- 官方文档中的“目录级授权标识”参数、20020 错误码两处定义冲突、个人使用应用的调用频率上限，文档没有讲清，未实测。

## 2. 环境与初始状态

### 2.1 机器与工具链

| 项目 | 值 |
|---|---|
| 操作系统 | Windows 10.0.26200 x64 |
| Shell | Git Bash（MINGW64_NT-10.0-26200，bash 5.3.15） |
| 包管理 / 运行时 | Node.js v24.19.0；Python 3.13.15；jq 位于 `C:\Users\YF\bin\jq` |
| WSL | 未检测到可用发行版 |
| 网络 | 本机代理 TUN 模式 + fake-ip（DNS 198.18.0.2，域名解析为 198.18.x.x），无 `HTTP(S)_PROXY` 环境变量 |
| bdpan CLI（初始） | 未安装 |

### 2.2 仓库状态（开始时）

```
分支：custom（跟踪 origin/custom）
远端：origin = https://github.com/YYFF925/bdpan-storage.git
      upstream = https://github.com/baidu-netdisk/bdpan-storage.git
与 upstream/main 的差异：0 ahead / 0 behind（完全一致）
工作区：clean
```

仓库共 40 个受版本控制的文件，两个 skill：

- `skills/baidu-drive/`：v1.7.7，网盘文件管理（本次对象）
- `skills/baidu-wenku-aippt-personal/`：文库 AI PPT（未涉及）

`baidu-drive` 的 12 个文件：

```
SKILL.md                     612 行，Agent 行为规范
VERSION                      v1.7.7
reference/bdpan-commands.md  1254 行，命令手册与 JSON 契约
reference/authentication.md  148 行
reference/examples.md        422 行
reference/notes.md           26 行
reference/troubleshooting.md 413 行
scripts/install.sh           282 行
scripts/login.sh             261 行
scripts/update.sh            329 行
scripts/uninstall.sh         155 行
scripts/memory-backup.sh     848 行
```

### 2.3 初始判断（后被实测确认）

- 仓库里没有任何功能实现代码；能力全部来自闭源 `bdpan` CLI（百度 CDN 下载）。skill 只是“给 Agent 看的说明书 + 辅助脚本”。
- 因此“改 skill”只能改 Agent 行为规则，不能改 CLI 能力。
- 脚本路径依赖 `${CLAUDE_SKILL_DIR}`；ZCode 自带 skill 使用 `${ZCODE_SKILL_DIR}`，二者不通用（后续在 ZCode 文档中确认了处理方式）。

## 3. 阶段一：仓库与 skill 结构分析

### 3.1 做过的读取

- 完整读取 `SKILL.md`（612 行）、`reference/bdpan-commands.md`（1254 行）、`examples.md`、`troubleshooting.md`、`authentication.md`、`notes.md`。
- 完整读取五个脚本：`install.sh`、`login.sh`、`update.sh`、`uninstall.sh`、`memory-backup.sh`。
- 读取 `.github/workflows/*.yml`、`Makefile`、`CHANGELOG.md`、`docs/contributing.md`、`.env.example`、另一个 skill 的 `SKILL.md`。
- 读取 `~/.agents/skills/weknora-manager`、`~/.agents/skills/shared-credentials` 等宿主侧 skill（后续使用）。

### 3.2 分析结论

- **skill 的职责**：触发规则、安全约束、确认分级、每个 CLI 命令的调用方式与结果展示规则（大量篇幅用于修补 Agent 实测暴露的问题：漏“点击查看”链接、泄露 fsid、误报转存成功、误删等）。
- **CLI 的结构**：安装器（从 CDN 下载）→ 安装器再从配置接口取当前版本二进制 → 安装到版本目录并配置 PATH。
- **发布链路**：`VERSION` 变更触发 GitHub Release；两个 workflow 都带上游仓库判断（fork 不自动发布）。
- **发现的问题（当时即记录，后续实测确认）**：
  1. `README.md`、`Makefile`、`docs/contributing.md` 仍残留旧目录名 `baidu-netdisk`；
  2. `SKILL.md` 要求 CLI 3.8.9，`install.sh` 里安装器版本是 3.8.4（后证实安装器实际装的是 3.8.9，见 6.1）；
  3. `update.sh` 从百度配置接口拉官方 skill 包覆盖目录（会冲掉 fork 定制）；
  4. 文档提到 `bdpan init` 命令（后证实已不存在）。

## 4. 阶段二：限制归属分析（skill / CLI / 服务端）

### 4.1 方法

四条证据线交叉：

1. skill 与 reference 文档中的措辞（“客户端快速失败”“CLI 校验”“服务端最终校验”等）；
2. 上游 GitHub issue 的用户实测报告与维护者回复；
3. 从百度 CDN 下载安装器与 CLI 二进制，做**静态字符串检查**（不执行）；
4. 后续在真实账号上运行 CLI 实测。

### 4.2 证据：上游 issue

检索 `baidu-netdisk/bdpan-storage` 的 issue（全部非 PR issue 列表），与本次结论相关的：

| Issue | 内容 | 结论 |
|---|---|---|
| #33（open） | 增加全盘访问的权限；只能访问 bdpan 文件夹 | 开放至今无回应；目录边界非 skill 可改 |
| #42（closed） | 文件名含 `..` 被误判为路径穿越，报“路径穿越攻击被阻止” | 确认路径校验在 bdpan 二进制内；3.8.9 修复 |
| #49（open） | 分片上传单片超时写死、无参数可调、无断点续传 | CLI/SDK 层限制 |
| #53（open） | 3.8.7 文件 API 客户端忽略 HTTP(S)_PROXY | CLI 层限制 |
| #56（open） | 3.8.8 分享验证 406，且错误 JSON 的进程退出码仍为 0 | 实测复现了“错误仍退出 0” |
| #26（closed） | 请求 upload 支持 `--overwrite` | 3.8.9 加入，代价是 skill 必须自己做覆盖确认 |
| #24（closed） | 非 VIP 时在 prompt 中提示开通会员 | 实现为 `bdpan vip` + skill 规则 |
| #17、#19 | 大文件上传 OOM、下载超时 | 均为 CLI 层修复 |
| #47 | 特定文件类型上传被服务端拒绝（precreate block_list 为空） | 服务端校验 |

### 4.3 证据：配置接口

- `https://pan.baidu.com/act/v2/api/conf?conf_key=nd_ai_bdpan` 返回 CLI 3.8.9 的各平台下载地址（linux、linux-arm、mac-arm、mac-intel、win），说明安装器是“引导式”：自身 3.8.4，装出来的是配置里的当前版本。
- `...&conf_key=bd_skills` 返回官方 skill 版本 **1.7.6**（url 指向百度对象存储的 `baidu-drive-v1.7.6.zip`，带 checksum）。官方版本号低于仓库的 1.7.7，意味着当前 `update.sh` 不会覆盖 1.7.7，但 fork 若把版本号改小就会被覆盖。

### 4.4 证据：二进制静态检查（未执行）

从 CDN 下载到独立临时目录（用完删除）：

- 安装器：`bdpan-installer-windows-amd64.exe`，15,289,344 字节，SHA256 `194f5174…` 与 `install.sh` 钉的值一致；Go 构建（go1.25.0）。
- CLI：`bdpan-3.8.9-windows-amd64.zip`，6,490,414 字节；内含 `bdpan.exe`（18,167,808 字节，SHA256 `26a74a97…`，与包内 `checksums.txt` 一致）、`README.md`、`CHANGELOG.md`、`VERSION`。

用 Node 脚本按 UTF-8 扫描字符串并按关键字取上下文，得到的直接证据：

| 类别 | 发现的字符串 |
|---|---|
| 路径边界 | `路径超出授权目录范围`、`路径穿越攻击被阻止`、`fsid 必须指向 /apps/bdpan 应用目录内的文件`、`分享目录不能包含 .. 路径段`、`新名称不能包含路径分隔符或遍历序列`、`转存结果路径不在目标目录下`、`上传返回的位置不在指定目录`、`搜索响应包含授权范围外的文件，已停止返回内容`、`OUT_OF_SCOPE`、`NO_PERMISSION` |
| 目录初始化 | `初始化根目录失败: scene: mkdir check: file list: ...` |
| 服务端权限校验迹象 | `目录授权校验失败，请重新执行 bdpan login`、`搜索授权校验失败`、`无权限访问指定目录，请检查授权范围`、`40103 … 请确认文件在应用目录内` |
| 读正文限制 | `一次最多读取 %d 个文件`、`已按单文件 50 万字上限截断`、`正文超过 %dMB 上限，已中止读取`、`超出文本预览接口 20MB 的上限`、`支持一次传入多个 fsid（最多 5 个）`、`当日读取配额已用完（错误码 40108）` |
| 分页限制 | `--page-size 必须在 1 到 50 之间` |
| 分享参数 | `无效的有效期: %d，合法取值: 0（永久）、1、7、30` |
| 上传规则 | `单文件上传必须指定远端文件名`、`当前仅支持单文件覆盖；文件夹请不带 --overwrite 正常上传`、`默认同名不同内容自动重命名；--overwrite 显式替换单个文件，无额外CLI确认。文件夹不支持该参数。` |
| 公共参数 | `json:"agentname"`、`json:"session_id"`、`json:"session_input"`、`json:"agent_reply"`，以及上报端点 `https://pan.baidu.com/rest/2.0/xpan/skill?method=report` |
| 环境变量 | `BDPAN_AUTH_CODE`、`BDPAN_CALLBACK_PORT`、`BDPAN_CONFIG_DIR`、`BDPAN_CONFIG_PATH`、`BDPAN_SANDBOX_GATEWAY`、`BDPAN_SANDBOX_SCENE_UID`、`BDPAN_VERSION` |
| 自更新 | `发现新版本: %s (当前版本: %s)`、`新版本 %s 已下载，运行 'bdpan update apply' 手动应用`、`已自动更新到 %s（当前: %s），下次启动生效`、`检查是否有新版本的 bdpan CLI 可用，但不执行更新` |
| 登录方式 | `--get-auth-url`、`--set-code`、`--set-code-stdin`、`--device-code`（`使用设备码登录模式（无需手动复制授权码）`）、浏览器回调（`BDPAN_CALLBACK_PORT`、`已打开浏览器`） |
| 命令缺失 | 二进制中**没有** `SKILL.md`、`bd_skills`、`CLAUDE_SKILL_DIR`、`scripts/` 等字样，说明 CLI 不读写 skill 文件 |

同时读取了 CLI 包内自带的 `README.md` / `CHANGELOG.md`（官方对自身能力的说明），确认：

- CLI 自带 README 写“作用域隔离：应用仅限 `/apps/bdpan` 目录”“内置 PathGuard”；
- CHANGELOG 3.8.9 明确“Agent 覆盖前在聊天中确认，CLI 不增加额外确认”“Skill 侧删除…CLI 仍支持 rm”——即确认环节属 skill，能力属 CLI。

### 4.5 结论：限制归属表

| 限制 | 层 | 依据 |
|---|---|---|
| 文件操作仅限 `/apps/bdpan`、`..` 段与编码穿越被拒 | CLI（+服务端授权） | 二进制字符串 + 实测报错 |
| 单文件上传必须给文件名；`--overwrite` 仅单文件；同名默认另存 | CLI | 二进制字符串 + 实测 |
| `share --period` 仅 0/1/7/30 | CLI | 二进制字符串 |
| `get-content` 一次 ≤5 个、单文件 50 万字截断、txt/md 20MB 上限 | CLI（部分服务端） | 二进制字符串 + 文档错误码 |
| `--page-size` ≤50 | CLI | 二进制字符串 |
| 启动时自动检查更新、可自动升级二进制 | CLI | 二进制字符串 + 自带 README |
| 文件 API 不走系统代理 | CLI | issue #53 |
| 读取正文每日配额（40108）、并发（40107） | 服务端 | 错误码 |
| 转存数量上限 500/3000/50000；异步任务 | 服务端 | 文档 + 实测 |
| 公共参数（agentname/session-input/session-id） | skill 要求（CLI 不强制） | 二进制 `json:"…"` + 实测缺省可运行 |
| 登录只能走 login.sh | skill 规则 | CLI 本身支持四种登录方式 |
| 删除、覆盖、同名下载需确认 | skill 规则 | CLI 不弹确认 |
| 强制 `--json`、回端链接展示、隐藏 fsid | skill 规则 | 展示层规则 |
| 大文件 50MB 阈值后台下载 | skill 规则 | 为绕 Agent Bash 超时 |
| 记忆备份仅 4 种 Claw | 脚本（`memory-backup.sh` 的 `detect_agent`） | 代码写死 |
| Windows 原生“不支持” | skill 仓库 README 的说法 | CLI 自身支持 Windows，CDN 有 windows-amd64 包 |

## 5. 阶段三：开放平台文档研究

### 5.1 抓取方法

- 文档站为 Starlight 静态站，每个页面提供 markdown 源：把页面 URL 尾部加 `.md` 即可（例如 `/union/doc/基础网盘服务/上传/预上传.md`）。
- 从 `/union/doc/` 首页 HTML 提取全部 `/union/doc/...` 链接，共 294 条（含 2 条重复编码变体），去重后 **292 个唯一页面**。
- 用 Node 并发抓取（并发 6），每页在标题后注入一行 `> 栏目路径：A / B / C　|　抓取时间：2026-11-25`，并以 `栏目__子栏__页面.md` 扁平命名，避免同名覆盖。
- 结果：292 个文件，约 1.27 MB，0 失败。
- 分工：授权/目录范围/配额/MCP 页面本人逐页精读；其余按板块交给 4 个并行子代理盘点，每条影响结论的内容再回原文抽查。

### 5.2 目录范围（最关键）

`使用入门/权限与配额`（更新于 2026-07-03）：

- 默认给应用一个目录：`/apps/{appname}`（网盘里显示为“我的应用数据/{appname}”）；
- “权限内目录”包括默认目录，以及**用户后续通过平台授权能力增加或调整的其他目录**；
- “权限外目录”应用不得访问、读取、下载、删除或操作；
- 文件类接口必须同时满足：目录在权限内、操作类型有接口权限、行为符合用户授权。

`使用入门/创建应用`（更新于 2026-11-11）：

- “2026 年 6 月 3 日后在平台创建的应用，以下接口仅支持访问 `/apps/{appname}` 目录下的文件”：`file?method=download`、`multimedia?method=listall`、`file?method=filemanager`、`file?method=precreate`、`file?method=meta`、`file?method=move`；
- 应用用途分“个人使用”（免审核、限 10 用户）与“公开发布”（需上线审核、不限用户）；
- 个人认证可建 1 个应用，企业认证最多 10 个；硬件与小程序类只能企业。

`使用入门/接入授权/快速授权`（更新于 2026-09-03）：

- “当您的应用需要访问用户网盘中的部分文件，但不需要全盘权限时，可使用目录级授权……用户在授权页选择目录，应用仅能访问所选目录及其子目录”；
- 新授权协议：`https://pan.baidu.com/union/oauth/authorize?scope=nd_open_read,nd_open_write`，token 接口 `https://pan.baidu.com/xpan/oauth/get?method=token`，返回 `authorized_paths`；
- 文档注明“目录级授权必须传递目录级授权标识”，但全文没有说明这个标识是什么。

其他相关页面（摘要）：

- `平台简介/错误码`：20011（审核中限前 10 用户）、20012（访问超限/限流）、20013（无接口权限）、20016/20017（token 过期/无效）、**20020（路径不在允许的访问范围内）**、31064（上传路径错误）、31365（文件总大小超限：普通 4GB/会员 10GB/超会 20GB）。
- `基础网盘服务/上传/能力说明`：文件必须上传到 `/apps/{appname}`；分片数量 ≤1024；单步上传 ≤2GB。
- `基础网盘服务/下载`：应用只能有一个文件夹用于存储、上传和下载；`dlink` 8 小时有效；必须带 `User-Agent: pan.baidu.com`；超过 50MB 不允许浏览器直接下载。
- `基础网盘服务/文件分享服务新/接入指南`：付费能力、仅企业开发者；转存单次 500/3000/50000；分享接口有频次限制；与企业版不互通。
- `faq/管理文件`：搜索接口每人每日 2000 次；`listall` 每分钟 8–10 次。
- `faq/上传`：上传每天不超过 10 万次（errno 9013）。
- `faq/分享文件`：旧的创建分享接口自 2022-08-01 起不再接受申请。

### 5.3 官方 MCP Server 文档

`mcp-server/*`（2026-07-28 版）：

- 个人使用无需创建应用：官方授权链接（`client_id=QHOuRXiepJBMjtk0esLhrPoNlQyYd0mF`、`scope=basic,netdisk`、`qrcode=1`、`redirect_uri=oob`），从浏览器地址栏取 Access Token（30 天、不可刷新）；
- 连接：`https://mcp-pan.baidu.com/sse`，`Authorization: Bearer <token>`；
- 文档列出的工具只有 15 个（实测 25 个，见 8.2）。

### 5.4 能力盘点（文档层面）

- 基础网盘服务：账号与容量、文件信息（列表/递归/详情/关键词/语义/分类/图片/文档/视频/BT）、上传（预上传→分片→创建、单步上传、上传域名）、下载、管理（复制/移动/重命名/删除/建目录）、分享（建链/验码/详情/列表/转存/任务查询/下载地址/音视频流/回调）、最近服务（需购买）、播单。
- 网盘特权服务：云解压、文档处理（≤200MB）、智能化（OCR/翻译等，只有音频转文稿有接口）、群组服务；全部需购买“特殊权益”。
- AI 创作能力：AI 视频笔记、人像美化、文档扫描、智能 PPT（生成接口计费）、音视频转写与纪要；均需商务下发权益。
- Agent 能力：GenFlow 流式对话接口 `/wenchain/genflow/chat`（`channel` 决定可调度的工具集）。
- 定制化图片能力：按时间列图片、按标签/关键词检索、智能分类标签；设备相册增删查（需设备绑定）。
- 设备管理：注册/绑定/解绑/列表/专属空间/设备可见文件列表（仅企业、硬件类应用）。
- NAS 服务：NAS 上传下载任务、会员激活码（需购买、硬件类应用）。
- 智能小程序入驻：小程序运行在网盘客户端内，按资源类型授权（仅企业）。
- SDK：Golang/Python/PHP 封装；Android/iOS 端侧 SDK（iOS 需邮件申请，审核 6–10 个工作日）。
- 硬性数值：单文件 4/10/20GB（普通/会员/超会）；分片 4/16/32MB、≤1024 片；单步 ≤2GB；转存 500/3000/50000；搜索 2000/日；递归列表 8–10/分；上传 10 万/日；未审核应用 10 次/时、10 用户；Access Token 30 天。

### 5.5 文档矛盾与空白

- 错误码 20020：`快速授权` 页说“下游服务异常”，`平台简介/错误码` 页说“路径不在允许的访问范围内”，两处冲突；
- “目录级授权标识”是什么，全站未写；
- “个人使用”应用的接口频率上限，文档未写；
- 9 个列表/搜索接口（`list`、`search`、`unisearch`、`btlist`、`categorylist`、`categoryinfo`、`imagelist`、`doclist`、`videolist`）页面没有目录范围声明，新应用能不能读 `/apps/{appname}` 之外，文档没有回答。

## 6. 阶段四：CLI 安装与登录（Windows 实测）

### 6.1 用仓库原版 `install.sh` 安装

从空临时目录执行（避免安装器落在仓库里）：

```bash
bash "E:/GitHub/bdpan-storage/skills/baidu-drive/scripts/install.sh"
```

过程与结果：

1. `detect_os` 识别为 windows，`detect_arch` 为 amd64；
2. 下载 `bdpan-installer-windows-amd64.exe`（3.8.4，15,289,344 字节）；
3. SHA256 校验通过（与 `install.sh` 钉的值一致）；
4. 执行 `./bdpan-installer-windows-amd64.exe --yes`，安装器输出 README/快速开始等内容；
5. **安装器把 CLI 装到 `C:\Users\YF\AppData\Local\bdpan\bdpan.exe`，并把该目录写入用户 PATH（注册表 `HKCU\Environment` 第 20 项）**；
6. 安装完成后 `install.sh` 的验证步骤报 `[ERROR] 安装失败，请检查 PATH 是否包含 ~/.local/bin`（exit 1），因为它只在当前 shell 里检查 `command -v bdpan`，而当前进程看不到注册表 PATH 的变更；
7. 因此后续的 `bdpan install --force`（版本注册）没有执行。

后续核查：

- 安装器把版本目录命名为 `~/.local/bdpan/versions/3.8.4/`，但里面的二进制实际是 **3.8.9**（版本目录标错）；
- `bdpan version --no-check-update` 显示：`bdpan: 3.8.9 Git Commit: 67623c2 Build Time: 2026-10-29T14:48:47+08:00`；
- 二进制 SHA256 `26a74a97…` 与 CDN 3.8.9 包内 `checksums.txt` 一致。

### 6.2 补做版本注册

```bash
bdpan install --force --no-check-update
```

输出：`已安装版本: 3.8.9`、`安装位置: C:\Users\YF\.local\bdpan`、`可执行文件: C:\Users\YF\.local\bin\bdpan`、提示 PATH 未包含。

- 版本目录变为 `~/.local/bdpan/versions/3.8.9/bdpan`（无 `.exe` 后缀），`current-version` 写入 3.8.9；
- `bdpan update list` 从“没有已安装的版本”变为 `✓ 3.8.9 (当前)`；
- `~/.local/bin/bdpan`（无 `.exe`）被创建：Git Bash 能执行，PowerShell/cmd 不能。

### 6.3 PATH 调查中的一个假阴性

最初用 `reg query "HKCU\Environment" /v Path | grep -i bdpan` 查不到内容，误以为安装器没写 PATH。原因：**Git Bash 把 `/v` 当成路径转换**，`reg.exe` 收到错误参数并静默失败。后来用 PowerShell `[Environment]::GetEnvironmentVariable('Path','User')` 才看到第 20 项 `C:\Users\YF\AppData\Local\bdpan`。

### 6.4 `login.sh` 的非交互行为（实测）

```bash
bash scripts/login.sh --continue-task </dev/null
```

输出到免责声明后的确认提示即停止：

```
已阅读上述安全须知，确认继续登录? [y/N] exit=1
```

- 原因：`read -n 1 -r` 在 EOF 处失败，脚本 `set -e` 直接退出；
- 结果：连授权链接都没有去取，`~/.config/bdpan/` 未被创建；
- 结论：原版 `login.sh` 不能在 Agent 的非交互 shell 中完成登录。

### 6.5 实际登录（PowerShell → Git Bash）

用户在 PowerShell 里执行：

```powershell
& "C:\Program Files\Git\bin\bash.exe" -c 'export PATH=$HOME/AppData/Local/bdpan:$PATH; bash /e/GitHub/bdpan-storage/skills/baidu-drive/scripts/login.sh'
```

按提示输入 `y`、浏览器打开授权链接、粘贴 32 位授权码。

后台每 30 秒轮询一次 `whoami --json`，在第 8 次检测时发现已登录（09:44:53）。登录后：

```json
{"authenticated":true,"has_valid_token":true,"expires_at":"2026-12-25T09:44:50+08:00","vip_type":2,"is_svip":true,"entitlement_status":"known"}
```

账号为超级会员；令牌 30 天有效。

### 6.6 其余 CLI 检查

- `bdpan version`（默认带更新检查）退出 0，未提示新版本（已是最新 3.8.9）。
- `bdpan whoami` 未登录时输出“⚠ 未登录 / 请执行以下命令进行授权: bdpan login”，JSON 模式为 `{"authenticated":false,…}`。
- 未登录时执行 `ls` 任意路径，一律先返回 `{"code":1,"data":null,"error":"请先执行 bdpan login 命令"}`，**退出码 0**。

## 7. 阶段五：CLI 冒烟测试（逐条记录）

> 全部在测试目录 `/apps/bdpan/_zcode-smoke-20261125` 内进行，测试文件均为本次创建，结束时已删除。

### 7.1 容量查询

命令（默认带更新检查）：

```bash
bdpan quota --json
```

结果：退出 0；stdout 为合法 JSON；stderr 0 字节。

```json
{"code":0,"error":"","data":{"total_display":"30.01 TiB","used_display":"11.57 TiB","free_display":"18.43 TiB","usage_percent":38.57,"expire":false}}
```

### 7.2 路径校验（已登录，关闭 MSYS 路径转换）

| 参数 | 结果 |
|---|---|
| `/my-documents` | `{"code":1,"data":null,"error":"路径超出授权目录范围"}`，exit 0 |
| `/etc/passwd` | 同上 |
| `~` | 同上 |
| `/apps/other/file.txt` | 同上 |
| `../x` | `{"code":1,…, "error":"路径穿越攻击被阻止"}`，exit 0 |
| `/apps/bdpan/../../x` | 同上 |
| `/apps/bdpan`、`/apps/bdpan/` | 正常返回数组 |

结论：POSIX 形式的越界路径在本地被 PathGuard 拒绝；所有业务错误退出码仍为 0。

### 7.3 盘符路径与 Git Bash 路径转换

- 直接给 CLI 传 `C:/Program Files/Git/apps/bdpan`、`C:\apps\bdpan`、`E:/x`、`D:\apps\bdpan`：**PathGuard 不拦**，请求发到服务端，返回 `errno=-7`（JSON `code:1`），stderr 另有“内部服务错误”面板（含错误 ID）。
- 默认（不关闭转换）的 Git Bash 中，原生程序收到的参数实测为：`/apps/bdpan` → `C:/Program Files/Git/apps/bdpan`；`/apps/bdpan/my-documents/x.txt` → `C:/Program Files/Git/apps/bdpan/my-documents/x.txt`；相对路径 `backup/x.txt` 不变。
- 结论：Git Bash 下绝对形式的远程路径永远走不通，除非关闭转换；关闭转换后本地路径必须用 Windows 形式或相对形式（MSYS `/tmp/...` 会报“本地路径不存在”）。

### 7.4 建目录与上传

| 测试 | 命令要点 | 结果 |
|---|---|---|
| 建目录 | `bdpan mkdir _zcode-smoke-20261125 --json` | `{"status":"ok",…}`，含 `return_markdown` |
| 上传：Windows 风格本地路径 | `bdpan upload C:/…/hello.txt _zcode-smoke-20261125/…` | `code:0`，`action:created`，`saved_path` 正确 |
| 上传：MSYS 本地路径（关闭转换） | `bdpan upload /tmp/…/hello.txt …` | 退出 1，`error:"本地路径不存在: GetFileAttributesEx /tmp/…"` |
| 上传：反斜杠本地路径 | `bdpan upload C:\…\hello.txt …` | 成功 |
| 上传：相对本地路径 | `cd <临时目录>; bdpan upload ./hello.txt …` | 成功 |
| 上传：中文+空格文件名 | `zcsmoke20261125-你好 world.txt` | 成功，`saved_path` 正确 |
| 上传：整个文件夹 | `bdpan upload <本地目录>/ <远端目录>/` | 成功，`saved_path` 为目录；stderr 有 35 字节进度输出 |

JSON 信封（upload）：`{"code":0,"data":{…},"error":""}`，`data` 含 `message/remote/remote_path/saved_path/action/requested_path/conflict_detected/verification/content_verified/fsid/return_url/return_markdown/…`。

### 7.5 列表、搜索

- `bdpan ls <目录> --json`：数组，元素含 `fs_id/fsid/path/server_filename/size/isdir/md5/server_mtime/server_ctime/return_url/return_hint/return_markdown/return_target_type/client_return_target_type/client_return_url/web_return_url`；本次 5 项均带 `return_markdown`。
- `bdpan search <关键词> --json --no-dir`：顶层 `items[]`，`total`、`has_more` 等；命中 2 个测试文件，均带 `return_markdown`。
- `bdpan search-content <词> --dir <新目录> --json`：`{"code":1,"error":"搜索范围必须是存在且有权限访问的目录","status":"unsupported"}`，exit 1（该目录刚建立，未被内容搜索索引识别）。
- `bdpan search-content <词> --json`（应用根目录）：`code:0`、`status:"succeeded"`、`total:0`，退出 0。

### 7.6 下载

| 测试 | 结果 |
|---|---|
| 单文件下载 | 成功（`code:0`，`return_markdown`），内容与原文件 SHA256 一致 |
| 中文文件名下载 | 成功 |
| 文件夹递归下载 | 成功，落地 `a.txt`、`sub/b.txt` |
| 本地已存在同名文件 | **直接覆盖**，无提示、无确认（sentinel 内容被替换） |

### 7.7 读正文

`bdpan get-content <fsid> --json`（txt 同步）：`code:0`，`data` 数组第一项含 `name`、`content`（有内容）、`return_markdown`，无 `task_id`。

### 7.8 整理类命令

- `bdpan rename <路径> <新名称> --json` → `{"status":"ok",…}`，含 `return_markdown`；
- `bdpan cp <源> <目标目录> --json` → 同上；
- `bdpan mv <源> <目标目录> --json` → 同上。

### 7.9 同名上传的三种行为

| 场景 | `action` | 实际落点 |
|---|---|---|
| 同内容重复上传 | `unchanged` | 原路径 |
| 不同内容、同名、默认 | `renamed` | 自动另存为 `…hello(1).txt`，`conflict_detected:true` |
| 不同内容、同名、`--overwrite` | `overwritten` | 原路径；`verification:metadata`、`content_verified:false` |
| 文件夹 + `--overwrite` | 拒绝 | exit 1，`error:"当前仅支持单文件覆盖；文件夹请不带 --overwrite 正常上传"` |

### 7.10 本节发现的问题（后续 fork 需处理）

1. 服务端错误时退出码为 0，本地校验错误为 1；成败只能看 JSON。
2. JSON 信封不统一：`ls` 为数组；`upload/download` 用 `code`；`mkdir/rm/cp/mv/rename` 用 `status`（无 `code`）。
3. `ls` 空目录时返回目录自身（名称与路径都等于所查目录，`isdir:true`），易被误判为“里面有个同名子文件夹”。
4. 偶发 `errno=20013`（接口权限不足）出现在 `ls` 的“初始化根目录”检查，重试即恢复（约 25 次调用出现 1 次）。
5. Git Bash 默认路径转换会改写绝对远程路径；PathGuard 只拦 POSIX 形式，盘符路径漏到服务端。
6. 下载时本地同名文件被静默覆盖。
7. `bdpan init` 已不存在（文档过时）。

## 8. 阶段六：MCP Server 验证

### 8.1 接入准备

- 官方个人使用授权链接（`client_id=QHOuRXiepJBMjtk0esLhrPoNlQyYd0mF`、`scope=basic,netdisk`、`qrcode=1`、`redirect_uri=oob`）→ 用户在浏览器授权，保存完整回跳 URL；
- 令牌保存在本地临时文本文件（非对话），验证后即删除；
- 端点 `https://mcp-pan.baidu.com/sse`，`Authorization: Bearer <token>`。

### 8.2 自建验证客户端（含踩坑过程）

由于 ZCode 当时还没重启，先写了一个最小 MCP 客户端 `%TEMP%\zc-mcp-tools\mcp-call.mjs`（Node 24，HTTP+SSE）：

- GET `/sse` 收 `endpoint` 事件 → POST JSON-RPC 到该 endpoint → 应答经 SSE 流返回；
- 令牌从文件读取，任何输出/错误都做脱敏；提供 `handshake / tools / call / batch` 四种模式。

开发过程中遇到的问题：

1. **服务端 `ping` 与客户端请求撞号**：服务端会主动向客户端发 `{"id":1,"method":"ping"}`，客户端误当成 `initialize` 的应答。修复：区分“带 method 的消息”（服务端请求/通知）与“应答”，并对 ping 回 `{"id":1,"result":{}}`；客户端改用字符串 id（`c1`、`c2`…）避免撞号。
2. **脚本语法错误**：一次重写时把 `'Content-Type': 'application/json'` 少写了冒号，`node --check` 报错后修正。
3. **`START` 未定义**：调试日志引用了未定义变量，补上。
4. 关闭路径转换后，`jq`/`node` 收不到 `/tmp/...` 这类 MSYS 路径 → 统一改用 `cygpath -m` 的 Windows 路径。

### 8.3 会话建立不稳定（重要）

- 最早一批：握手/工具列表/4 个调用全部成功。
- 随后一次 5 个调用全部卡在 `initialize`：SSE 已建立、`POST initialize` 返回 HTTP 202、流上只收到服务端 ping，等 90 秒无应答。
- 间隔一段时间后单次握手 1 秒成功，随后又失败。
- 连续 5 次握手探测：2 次成功（1 秒、0 秒），3 次超时（12 秒）。
- 结论：**建会话是随机不稳定的**；一旦建立，一个会话内 8 个调用 10 秒内完成（稳定）。对策：短超时 + 换新会话重试（脚本默认最多 12 次，每次 8 秒超时、间隔 2.5 秒）。
- 另一条经验：一次调用新建一个会话会加剧问题，批量操作应在一个会话内完成。

### 8.4 工具清单（实测 25 个）

```
file_content_create  file_content_get    file_copy        file_doc_list
file_download        file_image_list     file_keyword_search  file_list
file_meta            file_move           file_rename      file_semantics_search
file_sharelink_download  file_sharelink_list  file_sharelink_set
file_sharelink_taskquery  file_sharelink_transfer  file_sharelink_verify
file_upload          file_upload_by_content  file_upload_by_url
file_video_list      get_quota           make_dir         user_info
```

关键语义（来自工具描述原文与实测）：

- **`file_upload` / `file_download` / `file_sharelink_download` 不传输文件**：只校验本机路径并生成一段 `upload_prompt`/`download_prompt`，要求 Agent 去执行本地 `bdpan` CLI；`file_download` 明确“只允许访问网盘应用数据目录（即 /apps/bdpan/）……不支持访问其他网盘目录，不支持分享链接”。
- **`file_upload_by_content`**：服务端直接写入，任意目录（默认 `/来自：mcp_server`），内容 ≤2 万字，可指定文件名。
- **`file_content_create` / `file_content_get`**：按 fsid 读 Office/PDF 正文；异步任务；一次 1–5 个 fsid；页参数仅单文件 Word/PDF/PPT；Excel 不支持分页；正文超 2 万字转临时下载链接（2 小时）。
- **`file_sharelink_transfer`**：`short_url`（22 位短链去掉首位）、`fsid_list`（字符串 JSON 数组）、`to_path`（任意绝对路径）；带提取码的先 `file_sharelink_verify` 取 `spwd`。
- **`make_dir`**：`path` 绝对路径（中文需 urlencode），`rtype` 冲突策略。
- **`file_copy/file_move/file_rename`**：`filelist` 为 JSON 字符串，`async` 0/1/2，`ondup` fail/newcopy/overwrite/skip；移动文件夹会放进目标目录内部。
- **无删除工具**。

### 8.5 只读验证结果

| 测试 | 结果 |
|---|---|
| `file_list` `dir="/"` | `errno:0`，10 个条目（均为目录） |
| `file_list` `dir="/apps/bdpan"` | 正常返回（含本次测试目录） |
| `file_keyword_search` 关键词=测试标记 | 命中 3 个测试文件（位于 `/apps/bdpan` 内） |
| `file_semantics_search` 自然语言 | 成功；结构为 `data[].list[]`，命中同样 3 个文件 |
| `file_meta`（测试文件 fsid） | 成功；注意返回的 `path` 是 **URL 编码**（`%2Fapps%2Fbdpan%2F…`） |
| `user_info` / `get_quota` | 成功，与 CLI 同账号 |

### 8.6 写入验证（MCP 写 `/apps/bdpan`）

在测试目录内：

| 操作 | 结果 |
|---|---|
| `make_dir` 建子目录 | 成功（返回 fs_id、status 0） |
| `file_upload_by_content` 写 `mcp-note.txt`（98 字节） | 成功（fsid 515052780393757） |
| `file_rename` 重命名 CLI 上传的文件 | 成功（`errno:0`，`to_path` 正确） |
| `file_move` 移入子目录 | 成功 |
| `file_copy` 复制到另一子目录 | 成功（`to_fs_id` 608957980357971） |

CLI 侧核对：`bdpan ls` 能看到上述全部文件；`bdpan download` 下载 `mcp-note.txt` 内容正确。

### 8.7 全盘中转三条路径（决定性验证）

| 路径 | 步骤 | 结果 |
|---|---|---|
| 全盘上传 | CLI 上传 `zcsmoke-stage.txt` 到 `/apps/bdpan` → MCP `file_move` 到网盘根目录临时文件夹 | 成功，根目录可见 |
| 全盘下载 | MCP `file_copy` 从根目录临时文件夹复制回 `/apps/bdpan/…` → CLI 下载 → 比对 SHA256 | 成功，内容逐字节一致 |
| 全盘删除（前半） | MCP `file_move` 把根目录文件移回 `/apps/bdpan` | 成功 |
| 清理 | MCP `file_move` 把空临时文件夹移入测试目录 | 成功；根目录恢复为原来的 10 项，无遗留 |

### 8.8 删除路径（后半）与最终清理

删除前逐项列清单，目录内 6 目录 + 13 文件全部为本次测试文件：

```bash
bdpan rm "_zcode-smoke-20261125" --force --json
# → {"status":"ok"}  exit 0
```

验证：

- `bdpan ls --json`（应用根目录）→ 2 项，测试目录不存在；
- `bdpan ls _zcode-smoke-20261125` → `{"code":1,"error":"找不到指定的文件或目录（错误码 -9）…"}`；
- MCP `file_list` 同一路径 → `errno 1002`（“请求数据为空，请检查参数”）。

### 8.9 ZCode 原生工具验证

重启 ZCode 后：

- `bdpan` 已在 PATH（`C:\Users\YF\AppData\Local\bdpan\bdpan`），登录态保持；
- `mcp__baidu-netdisk__get_quota` 调用成功，容量与 CLI 一致；
- 曾误判“ZCode 只注册 22 个工具”，实际测试 `file_semantics_search`（正常返回空结果）、`file_content_get`（假 taskid → `errno 40102 任务不存在`）、`file_sharelink_verify`（假短链 → `errno 13000 share link record not found`）均可用；
- ZCode 日志（`~/.zcode/cli/log/zcode-2026-11-25.jsonl`）记录 `mcp.server.connected`、`toolCount: 25`（connectDurationMs 461、listToolsDurationMs 112），`mcp.tools.snapshot_applied` 为 98 个工具 / 9 个 server；
- 业务错误的显示格式：`The system is busy, please try again later: (response.body:{"errno":…,"show_msg":…})` —— 首句有误导性，真实原因在括号内。

### 8.10 ZCode 配置写入

- 文件：`~/.zcode/cli/config.json`（原 1521 字节 → 1777 字节）；
- 新增：`mcp.servers["baidu-netdisk"] = { type: "sse", url: "https://mcp-pan.baidu.com/sse", headers: { Authorization: "Bearer <token>" } }`；
- 备份：`~/.zcode/cli/config.json.bak-20261125-032630`（原文件）。2026-11-25 下午经确认删除；该备份是“添加 MCP server 之前”的配置，**不含** Authorization 头（当时 grep 计数为 0）。此后 `mcp-token.sh` 只生成脱敏备份（`Bearer <redacted>`）；
- 原有的 `hindsight`（stdio）配置逐字节未变；
- 临时令牌文件已删除。

### 8.11 与宿主相关的两个结论

- ZCode 识别 skill frontmatter 的键为 `name`、`description`、`when_to_use`、`license`、`metadata`；`allowed-tools` 在 ZCode 不生效（MCP 工具调用不受其限制）；
- `description` 只有前约 250 个字符参与触发判断；`~/.agents/skills` 与 `~/.zcode/skills` 都支持目录链接（现有 `ego-browser` 即为链接触达 `C:\Program Files` 下的目录，且 ZCode 确实加载了它）。

## 9. 问题与处理清单

| # | 现象 | 根因 | 处理 |
|---|---|---|---|
| 1 | `install.sh` 末尾报安装失败 | 当前 shell 看不到注册表 PATH 变更；脚本在同一个 shell 里验证 | 手动补 `bdpan install --force`；新开终端/ZCode 后 PATH 生效 |
| 2 | `reg query … /v Path` 查不到 PATH 条目 | Git Bash 把 `/v` 当路径转换 | 改用 PowerShell `GetEnvironmentVariable` |
| 3 | 安装器版本目录标成 3.8.4，二进制是 3.8.9 | 安装器用自身版本命名目录 | 不影响运行；`bdpan install --force` 后版本管理器显示 3.8.9 |
| 4 | `~/.local/bin/bdpan` 无 `.exe` 后缀 | CLI 自安装在 Windows 的命名问题 | Git Bash 可用；PowerShell/cmd 需 `.exe` |
| 5 | `login.sh` 非交互退出 1 | `read` 在 EOF 失败 + `set -e` | 在真实终端执行；fork 计划加两步非交互模式 |
| 6 | `bdpan ls /apps/bdpan` 返回 errno -7 | Git Bash 默认路径转换 | 关闭转换（`MSYS_NO_PATHCONV=1`）且远程路径用相对形式 |
| 7 | 关闭转换后本地 `/tmp/...` 路径报“本地路径不存在” | 原生程序不认 MSYS 路径 | 本地路径用 Windows 形式（`cygpath -m`） |
| 8 | 盘符路径绕过本地 PathGuard | PathGuard 只识别 POSIX 越界形式 | 服务端以 -7 拒绝；fork 的包装脚本统一拦截 |
| 9 | 业务错误退出码 0 | CLI 行为 | 按 JSON 内容判断成败 |
| 10 | JSON 信封不一致 | 各命令实现不同 | 包装脚本做归一化 |
| 11 | `ls` 空目录返回目录自身 | CLI bug/怪癖 | 包装脚本修正为 `[]` |
| 12 | 偶发 `errno=20013` | 服务端限流/权限抖动（未定论） | 只读命令重试 |
| 13 | 下载静默覆盖本地同名文件 | CLI 行为 | 确认由 skill 负责 |
| 14 | `search-content --dir` 新目录报范围无效 | 内容搜索索引未识别新目录 | 根目录搜索正常；新目录稍后或换方式 |
| 15 | MCP 握手随机无应答 | 服务端/链路不稳定（多实例或代理，未定论） | 短超时 + 换会话重试；批量合并到一个会话 |
| 16 | MCP 工具列表比文档多 10 个 | 文档滞后 | 以 `tools/list` 实测为准 |
| 17 | MCP `file_upload/file_download` 不传文件 | 设计为生成 CLI 提示词 | 改用 CLI + 中转方案 |
| 18 | MCP 无删除工具 | 平台限制 | 中转 + CLI 删除 |
| 19 | `file_meta` 路径为 URL 编码 | 接口行为 | 使用时解码 |
| 20 | MCP 业务错误显示为 “system is busy” | 宿主包装文案 | 读括号内 `errno`/`show_msg` |
| 21 | Notepad 启动后窗口不可见 | 窗口在终端后/后台 | 改用 `Read-Host` 写文件 |
| 22 | 凭据库 `op` 读取失败：WriteSessionToFile / 域名解析 | 本机部署副本落后于库：库（提交 `89c2e78`）早已改为 `os.environ.copy()` 保留系统环境，并增加了 winget 安装路径查找；部署副本仍是旧版 | 用 `deploy sync --overwrite-local` 把 `shared` 与 `agent:cursor` 两份部署更新到库版本（`agent:antigravity` 本就一致）；临时补丁未进库，已弃用 |
| 23 | weknora-manager 取不到凭据（“no credential record at /service/weknora/ai”） | weknora.py 仍用旧的路径式取法；新凭据库按 `credential_id` 组织，`--path` 作为 id 别名可用 | 用 `--credential-path weknora-ai` 调用 |

## 10. 当前机器状态与遗留事项

### 10.1 已安装 / 已配置

| 项目 | 状态 |
|---|---|
| bdpan CLI | 3.8.9，`C:\Users\YF\AppData\Local\bdpan\bdpan.exe`，已在用户 PATH；已登录（超会，令牌到 2026-12-25） |
| ZCode MCP | `baidu-netdisk`（type=sse，`https://mcp-pan.baidu.com/sse`），25 个工具可用；旧的 `config.json.bak-20261125-032630` 已删除，现由 `mcp-token.sh` 生成脱敏备份 |
| 辅助脚本 | `%TEMP%\zc-mcp-tools\mcp-call.mjs`（批量、重试）、`summarize.mjs`、`tools.json`（25 个工具 schema）；不含凭据 |
| 抓取的文档 | `%TEMP%\bdpan-union-docs-npbM6y\flat`（291 个）+ `flat-excluded\_index.md`（1 个，已单独上传） |
| WeKnora 知识库 | 空间 `ai`（credential_id `weknora-ai`）下新建“百度网盘开放平台文档”（`4b967e84-4ead-4861-9e27-aaf4cf91a62b`），292 篇已上传 |
| shared-credentials | 库（`D:\GitHub\SkillManagerVault`，提交 `89c2e78`）已含正确修复并推送；本机三份部署（`shared`、`agent:cursor`、`agent:antigravity`）已对齐库，sha256 一致；`lobster` 域副本与 `code` 域内容相同，随库同步 |
| 网盘测试数据 | 已全部删除；根目录恢复原状 |
| 仓库 | clean，未改动 |

### 10.2 遗留

1. **双通道 skill 已实施并通过验收**（见第 13 节）；已提交到 `custom` 分支。
2. **Hermes Agent / dsh 适配**：暂缓。已查清：Hermes 主目录在 `%LOCALAPPDATA%\hermes`，读取项目内 `.agents/skills` 或配置 `skills.external_dirs`；dsh 为 DeepSeek Harness（`@deepseek-ai/dsh`），插件式架构，skill 加载方式尚未查清。
   - 2026-11-25 晚更新：Hermes 已适配并实机验证，见 `skills/baidu-drive/reference/hosts/hermes.md`；dsh 仍未做。
3. **MCP 令牌续期**：约 2026-12-25 到期，需重新授权并更新 ZCode 配置（计划中的 `mcp-token.sh` 即为此准备）。
4. **shared-credentials 的 Hermes 侧**：不需要单独改文件；`lobster` 域副本与库同源，拉取库即得到同一修复。
5. **四个既有暂停部署**（与本次凭据修复无关，需你裁决保留本地还是按库覆盖）：`code/credential-onboarding` → `agent:antigravity`；`code/skill-manager-maintenance`、`code/weknora-manager`、`code/weknora-search` → `shared`。均因受管副本被外部修改而暂停（`paused_local_change`）。
5. **WeKnora 解析**：292 篇文档解析中，完成后需验证召回。
6. **官方文档空白项**：目录级授权标识、20020 双定义、个人使用应用频率上限、新应用读接口范围——需实测或向平台确认。

## 11. 文档入库记录（WeKnora，2026-11-25）

本节记录“把抓取的 292 页开放平台文档入库到知识库”的完整过程，包括凭据层排障。

### 11.1 前置与目标

- 文档已在本地：`%TEMP%\bdpan-union-docs-npbM6y\flat`（291 个）+ `flat-excluded\_index.md`（1 个）。
- 目标：默认空间 `ai`（credential_id `weknora-ai`）下新建专用知识库并全部入库，解析完成后验证召回。

### 11.2 凭据层排障（1Password）

现象：`credentials.py check` 报 `op whoami` 失败：`POST /api/v3/auth/start: dial tcp: lookup my.1password.com: getaddrinfow: A non-recoverable error occurred during a database lookup`；但 `credentials.py list --recursive` 能返回条目。

排查步骤与事实：

1. 当前 `shared-credentials` 为 v2.0.0：真源已从 Infisical 迁到 **1Password**（Infisical 2026-11-23 停用）；身份来自 `~/.config/op/sa-token`。
2. `op` 已安装；`nslookup`、`curl`、Node 的 `dns.lookup` 都能解析 `my.1password.com`（走本机代理 fake-ip）；`op` 直连（无 token）报“没有配置账户”，带 token 时 `op whoami`/`op item list` 成功（缓存路径），但真正 `op read` 失败。
3. `credentials.py` 是后端路由：`BACKEND_ENV`/`DEFAULT_BACKEND` 选中后端后委托给 `backend_onepassword.py`（同一目录）。
4. 读代码发现 `backend_onepassword.py` 的 `_op()` 构造**极简环境**：仅 `PATH`、`HOME`、`OP_SERVICE_ACCOUNT_TOKEN`、`OP_LOAD_DESKTOP_APP_SETTINGS`，在 Windows 上把 `SystemRoot`、`USERPROFILE`、`LOCALAPPDATA` 等系统变量全部丢掉。
5. 对照实验（`env -i`）：
   - A：完全按极简环境 → `op read` 失败，报 `failed to model.WriteSessionToFile`；
   - B：再加 `SystemRoot` → 仍是会话文件错误；
   - C：补齐 `SystemRoot/WINDIR/USERPROFILE/LOCALAPPDATA/APPDATA/TEMP/TMP/COMSPEC/PATHEXT` → **`op read` 成功（exit 0）**。
6. 先按上述结论在**部署副本**上打了补丁（备份到 `%TEMP%`），随后核对库时发现：**库（`D:\GitHub\SkillManagerVault`，提交 `89c2e78`，2026-11-25）早已修好**——`_op()` 改为 `os.environ.copy()` 保留系统与代理环境，并新增 winget 包路径查找。真正的问题是 `shared` 与 `agent:cursor` 两份**部署副本过期**（`agent:antigravity` 与库一致）。因此“提交修复”实际是让部署跟上库，而不是往库里写新补丁。
7. 处理：把临时备份移出部署目录；对 `shared`、`agent:cursor` 执行 `deploy sync --ref code/shared-credentials --target <t> --overwrite-local`（`agent:antigravity` 为 `unchanged`）；`sync push` 返回“没有需要上传的改动，已是最新”（库已提交并推送）；三份部署的 `backend_onepassword.py` 与库 sha256 完全一致。临时补丁被库版本取代，不再使用。

### 11.3 weknora-manager 与凭据库的版本错配

- `weknora.py` 仍按旧模型调用：`credentials.py list --path /service/weknora/ai`，并据此报 `no credential record at /service/weknora/ai`。
- 新凭据库按 `credential_id` 组织；实测 `list --path <credential_id>` 可用（`--path` 被当作 id 别名），且条目字段为 `WEKNORA_API_KEY`、元数据 `target.url` 指向服务入口。
- 解决：统一用 `--credential-path weknora-ai` 调用（无需改 weknora.py）。

### 11.4 连通与选库

- `weknora.py --credential-path weknora-ai ping` → `ok: true`，host 为内网反代入口（略），CLI 为自带的 `weknora.exe`。
- `kb list` → 空间 `ai`（tenant 10001）下只有 1 个库“Grok Bot”（88 篇）。
- `model list` → `Qwen3-Embedding-8B-mxfp8`（Embedding，`06779ddb-…`）、`deepseek-v4.1-flash`（KnowledgeQA，`3e9b387f-…`）、`Qwen3-Reranker-8B-mxfp8`（Rerank，`581fc6f6-…`）。

### 11.5 建库

```bash
python weknora.py --credential-path weknora-ai -- kb create "百度网盘开放平台文档" \
  --description "百度网盘开放平台（pan.baidu.com/union）全站文档镜像，292 页 markdown，2026-11-25 抓取；…" \
  --embedding-model 06779ddb-16e7-4d28-bce8-b6347428797a \
  --chat-model 3e9b387f-5c1c-4ce4-9d11-6ebdc37c6062
```

返回：`id = 4b967e84-4ead-4861-9e27-aaf4cf91a62b`，嵌入与摘要模型已绑定，`knowledge_count: 0`。

### 11.6 上传

1. 先用 `_index.md`（4949 字节）单文件验证：上传成功（doc id `59a703a4-…`），`parse_status: finalizing`。
2. 把 `_index.md` 移出批量目录（避免重复上传）。
3. 批量上传：

```bash
python weknora.py --credential-path weknora-ai -- doc upload \
  "<抓取目录>" \
  --recursive --glob '*.md' --kb 4b967e84-4ead-4861-9e27-aaf4cf91a62b
```

结果：14:02:45 开始、14:02:58 结束，291 个条目全部 `ok:true`、0 失败；知识库 `knowledge_count` 变为 292（291 + `_index.md`）。

### 11.7 解析与验收

- 上传是异步解析：`is_processing: true`，`processing_count` 从 252 逐步下降（14:04 为 220、14:07 为 154、14:08 为 0），**14:08 解析完成**。
- 召回验证结果（`search chunks`，`--limit 5`）：
  - “新创建的第三方应用有哪些目录限制” → 命中 `使用入门__创建应用.md`（含“2026年6月3日后…仅支持”原文片段）与 `更新日志__文档更新日志.md`、`基础网盘服务__上传__能力说明.md`，命中精确；
  - “单个文件上传大小上限按会员类型分别是多少” → 命中 `基础网盘服务__上传__能力说明.md`（“普通用户 4GB / 会员 10GB / 超级会员 …”），命中精确；
  - “目录级授权返回哪个字段” → 命中 `使用入门__接入授权__快速授权.md` 的“返回字段”段落，命中精确；
  - “官方 MCP Server 提供哪些工具”（原始措辞）→ 命中的是 `mcp-server__反馈支持`、`使用概述`、`更新日志` 等相关页，未直接命中工具表；
  - 换更具体的措辞“MCP 工具参数 file_list 的 dir 参数” → 前 4 条全部来自 `mcp-server__tools-能力文档.md`，命中精确。
- 结论：292 篇全部可检索；查询措辞越贴近文档正文，命中越精确；不含关键字面表述的宽泛问法依赖语义召回，可能命中相关页而不是目标页。
- 实例侧观察：搜索能返回片段，但 `kb view` 的 `chunk_count` 始终为 0（计数未更新），不影响检索与问答。

## 12. 附录

### A. MCP 客户端用法（mcp-call.mjs）

```bash
# 握手（打印服务端信息）
node mcp-call.mjs <token-file> handshake
# 列出工具（名称/描述/参数 schema）
node mcp-call.mjs <token-file> tools
# 单次调用
node mcp-call.mjs <token-file> call file_list '{"dir":"/"}'
# 批量（一个会话内顺序执行，结果一行一个 JSON）
node mcp-call.mjs <token-file> batch batch.json
```

`batch.json` 形如：`[{"tool":"file_list","args":{"dir":"/"},"pauseMs":600}, …]`。
环境变量：`MCP_DEBUG=1`、`MCP_REPLY_TIMEOUT_MS`、`MCP_INIT_TIMEOUT_MS`、`MCP_SESSION_ATTEMPTS`。

### B. 文档抓取脚本逻辑

1. GET `https://pan.baidu.com/union/doc/` 取 HTML；
2. 正则提取 `href="/union/doc/..."`，过滤静态资源，去重；
3. 每个页面请求 `<页面路径>.md`（服务端返回 `text/markdown`）；
4. 在标题后插入“栏目路径 + 抓取时间”，文件名用 `栏目__子栏__页面.md` 扁平化；
5. 并发 6，失败重试；统计成功数与各板块数量。

### C. 25 个 MCP 工具参数速查

| 工具 | 关键参数 |
|---|---|
| `file_list` / `file_doc_list` / `file_image_list` / `file_video_list` | `dir`、`page` |
| `file_meta` | `fsids`（≤10） |
| `file_keyword_search` | `key`、`dir`、`page`、`num` |
| `file_semantics_search` | `query`、`dir`、`category`、`file_ext`、`num`、`search_type`、`sources`、`stream` |
| `make_dir` | `path`、`rtype` |
| `file_copy` / `file_move` / `file_rename` | `filelist`（JSON 字符串）、`async`(0/1/2)、`ondup` |
| `file_upload_by_url` | `url`、`dir`、`filename` |
| `file_upload_by_content` | `content`(≤2万字)、`dir`、`filename` |
| `file_upload` / `file_download` | 只生成 CLI 提示词，不传输 |
| `file_content_create` | `fsids`(1–5)、`page_start`、`page_end` |
| `file_content_get` | `taskid` |
| `file_sharelink_set` | `fsid_list`、`period`、`pwd`、`remark` |
| `file_sharelink_list` | `short_url`、`spwd`、`dir`、`page`、`page_size`、`order_by`、`desc_order` |
| `file_sharelink_verify` | `short_url`、`pwd` |
| `file_sharelink_transfer` | `short_url`、`fsid_list`、`spwd`、`to_path` |
| `file_sharelink_taskquery` | `task_id` |
| `file_sharelink_download` | `url`、`local`、`pwd`、`transfer_dir`（只生成提示词） |
| `user_info` / `get_quota` | 无参数 |

### D. 证据文件位置

- 抓取的文档：`%TEMP%\bdpan-union-docs-npbM6y\flat`（291）、`flat-excluded\_index.md`
- MCP 工具 schema：`%TEMP%\zc-mcp-tools\tools.json`
- 批量上传日志：`%TEMP%\weknora-upload.log`
- ZCode 配置：`~/.zcode/cli/config.json`；脱敏备份 `~/.zcode/cli/config.json.bak-<时间戳>`（旧的 `bak-20261125-032630` 已删除）
- shared-credentials 备份：`~/.agents/skills/shared-credentials/scripts/backend_onepassword.py.bak-20261125-140056`
- ZCode 运行日志（MCP 连接记录）：`~/.zcode/cli/log/zcode-2026-11-25.jsonl`

## 13. 双通道 skill 实施与验收记录（2026-11-25 下午）

### 13.1 改动清单

修改（4 个，均在上游文件上增量修改）：

| 文件 | 改动 |
|---|---|
| `skills/baidu-drive/SKILL.md` | 重写 description（前 120 字写明“全盘管理”）、新增 `when_to_use`；新增“本 fork：全盘管理（双通道）”章节（通道、路由、中转、失败核对、删除规则、遥测、MCP 重新授权）；更新与登录章节改写；+126 行 |
| `skills/baidu-drive/scripts/login.sh` | 新增 `--issue-url`（只打印授权链接）与 `--complete`（从 stdin 读授权码）；`--complete` 绕开“已登录”早退并提示将覆盖现有登录；+71 行 |
| `skills/baidu-drive/scripts/install.sh` | Windows：安装后临时补 PATH、用绝对路径执行 `install --force`、补 `bdpan.exe` 启动文件、失败提示与重启提示；+34 行 |
| `skills/baidu-drive/scripts/update.sh` | 停用“下载官方包覆盖”；改为分轨更新（`git merge upstream` / 官方 CLI 渠道 / MCP 服务端）+ 只读 `--check`；整体重写（329 → 约 120 行） |

新增（6 个）：

| 文件 | 行数 | 职责 |
|---|---|---|
| `scripts/bdpanw.sh` | 228 | CLI 适配：找二进制、MSYS 路径处理、遥测参数（默认 minimal）、强制 `--json --no-check-update`、按 JSON 判成败、空目录修正。不做重试、不管 MCP |
| `scripts/staging.sh` | 168 | 按任务隔离的中转目录 + 本机轻量状态（new/path/status/set/list/clean/stale） |
| `scripts/mcp-token.sh` | 206 | token 原子写入、脱敏备份、签发日期记录（同一 token 不重置）、25 天提醒 |
| `reference/whole-drive.md` | 187 | 全盘能力、路由、失败核对、中转流程、删除确认协议、合规、token、限制 |
| `reference/hosts/zcode.md` | 75 | ZCode 的 MCP 配置、工具命名、错误文案、重连、占位符 |
| `reference/regression.md` | 96 | CLI 升级/合并上游后的最小回归清单 |

其他：`~/.agents/skills/baidu-drive` 建成指向仓库的目录联接（ZCode 已发现该 skill）；`docs/verification-2026-11-25.md` 为本报告。

### 13.2 验收测试结果

**单元测试（假 bdpan，不碰网盘）**：通过 20 项——遥测三种模式、session-id 形状与覆盖、上传/下载本地路径转换、远程路径原样、空目录修正（相对/绝对）、越界退出码、`code:1`/`authenticated:false`/非零退出判定、`version` 文本放行、staging 新建/状态/清理/拒绝提前清理/list、token 写入/保留其他 server/脱敏备份/同 token 保留签发日期/换 token 更新日期。

**真实网盘（专用测试目录，已全部清理）**：

| 项目 | 结果 |
|---|---|
| whoami / quota / version | 通过（SVIP；30.01 TiB / 剩余 18.43 TiB；version 输出 JSON） |
| mkdir、绝对路径 `ls /apps/bdpan`、越界路径 | 通过；越界返回 `路径超出授权目录范围` |
| 空目录 `ls` | 仓库的 `[]` 修正生效（真实 CLI 返回目录自身的怪癖被修掉） |
| 上传（Windows 路径 / MSYS 路径） | 通过（MSYS 路径被正确转换；`action=created`、`saved_path` 正确） |
| 同名上传 / `--overwrite` | `a(1).txt` 另存；`--overwrite` 覆盖成功 |
| 下载 + md5 | 本地 md5 与原始一致 |
| `.part` 原子替换 | **实测**：下载中有 `<目标>.part`；终止进程后旧文件完好、`.part` 残留；重下后 md5 一致、`.part` 消失 |
| search / get-content | 通过（search 为模糊匹配，会命中含相关词的文件） |
| staging new/upload/clean | 通过；清理后目录不存在、`_staging` 为空、`stale 0` |
| MCP 全盘写入 | 根目录 `make_dir`、`file_upload_by_content`、`file_rename`、`file_move`、跨目录 `file_copy` 全部成功 |
| `fsid` 稳定性 | 重命名、移动后 `fsid` 不变；复制产生新 `fsid` |
| 跨通道可见性 | CLI 能看到并读取 MCP 写的文件（同一 `fsid`） |
| 清理 | 根目录测试夹移入应用测试夹后统一 `rm`；网盘根目录恢复 10 项、应用根目录恢复 2 项 |
| mcp-token（真实 token） | 写入成功、其他 server 保留、备份无明文、同 token 保留签发日期 |
| login.sh 参数分支 | `--help`、冲突参数、空/格式错/无效授权码三种失败均退出 1；登录态未受影响 |
| update.sh | `--check` 显示本地 v1.7.7 vs 官方 1.7.6；未知参数退出 2 |
| skill 发现 | ZCode 会话内已列出 `baidu-drive`（来自 `~/.agents/skills/baidu-drive/SKILL.md`） |

### 13.3 实测修正的假设

1. **百度返回的 `md5` 不是标准 MD5**（含 `j`/`o`/`i` 等非十六进制字符），不能与本地 `md5sum` 比对；同内容两次上传该值相同。核对改为 `size` + `action` + `fsid`，需要内容证明时下载回来比对。
2. **`fsid` 不随重命名/移动改变**，可作为身份核对依据。
3. **`.part` + 原子替换已被实测证实**（此前只是 CHANGELOG 声明），且中断会留下 `.part`。
4. `search` 是模糊匹配。
5. **CLI 的 `ls /` = 应用根目录**，不是网盘根目录；全盘根目录只能用 MCP。
6. MCP 写操作失败形如 `{"errno":12,"info":[{"errno":-9,...}]}`。
7. 并行发起“移动 + 复制同一文件”会竞态：复制拿到 `-9`（源已移走），写操作需串行。

### 13.4 与上游的差异（tracked 文件）

```
skills/baidu-drive/SKILL.md           | 126 +++++++++++-
skills/baidu-drive/scripts/install.sh |  34 ++-
skills/baidu-drive/scripts/login.sh   |  71 +++++-
skills/baidu-drive/scripts/update.sh  | 408 ++++++--------------------------
4 files changed, 307 insertions(+), 332 deletions(-)
```

新增 6 个文件（见 13.1），`VERSION`、`reference/bdpan-commands.md` 等上游文档、两个发布 workflow 均未改。

### 13.5 遗留问题

- 已提交到 `custom` 分支。
- 未做 Hermes Agent / dsh 适配（只保留了宿主适配文档位）。
- 2026-11-25 晚更新：Hermes 已适配并实机验证，见 `skills/baidu-drive/reference/hosts/hermes.md`；dsh 仍未做。
- 全盘删除已按用户要求启用（2026-11-25 晚，见第 14 节）：需用户明确允许（AI 可主动建议），走中转删除。
- MCP token 约 2026-12-25 到期，需重新授权并再次执行 `mcp-token.sh`。
- MCP 会话建立仍有随机失败，依赖宿主重连。
- 大目录的 MCP 复制/移动可能异步返回 `taskid`，而 MCP 无通用任务查询，需按目标目录核对。
- 中断下载留下的 `.part` 需调用方清理（skill 未自动清理本地文件）。
- 工作区存在 ZCode 自己生成的 `.zcode/plans/`（未跟踪，非本任务产物）。

## 14. 全盘删除启用（2026-11-25 晚，用户决策）

### 14.1 策略变更

用户明确要求启用 `/apps/bdpan` 之外的删除，条件是：**必须获得用户的明确允许后才能执行**；允许 AI 在任务过程中主动提出删除建议，“明确允许”不等于用户预先说出路径。此前“保持关闭”的决定（GPT 第 1 条调整）由用户本人推翻；实现仍采用“移动 + 删除”，因为 MCP 没有删除工具。

### 14.2 实现

- `SKILL.md`：路由表删除行改为“可主动建议 + 明确允许 → 中转 → CLI 删除”；新增七步中转删除流程与失败处理；description 同步。
- `scripts/staging.sh`：`new` 增加 `del` 类型。
- `reference/whole-drive.md`：第 5 节从“不启用”改写为“显式确认后启用”，含确认协议、执行核对、失败回退、禁止事项；第 3 节增加中转删除核对行；第 4 节增加 del 任务清理；第 8 节记录实测结论。
- `reference/regression.md`：新增 5.1 全盘删除回归项。

### 14.3 实测（专用测试目录，已清理）

| 步骤 | 结果 |
|---|---|
| MCP 建根目录测试夹、写入文件与子文件夹 | 通过 |
| 文件：move 到 `_staging/del-<id>/` | 通过；`fsid` 不变；原目录不再列出该文件 |
| CLI `rm` 文件；`ls` 中转目录 | 通过；输出 `[]` |
| 文件夹（含一个文件）：move + CLI `rm` | 通过；子文件一并删除；原目录为空 |
| 测试根文件夹本身按同一流程删除 | 通过；网盘根目录恢复 10 项、应用根目录恢复 2 项 |
| staging 任务记录 | 三个任务均 `cleaned`，`_staging` 已删除 |

### 14.4 实测发现

- **MCP 写操作的实际参数是 `filelist` JSON 字符串**（`[{"path":...,"dest":...,"newname":...}]`），不是顶层 `path`/`dest`。文档已按实际 schema 修正（`file_move`、`file_copy`）。
- CLI `rm` 对文件夹是递归删除（测试文件夹内的 `inner.txt` 一并删除），无需额外参数。
- 移动文件夹到目标目录时，文件夹作为子目录落入，最终路径为 `_staging/del-<id>/<名称>`。
- 中转删除的 `fsid` 在移动前后不变，可作为核对依据。

### 14.5 残余风险

- 这是官方文档未描述的组合用法；文件在删除前会短暂离开原目录，删除失败时停在中转目录，需按 `note` 记录移回。
- 删除不可逆；确认话术必须列出完整路径、类型、大小和“不可恢复”。
- 平台若后续提供原生删除接口，应改用原生接口。

### 14.6 定义修正（同日，用户反馈）

初版把“明确删除”实现成“用户必须先点名完整路径”，导致 AI 不能提出删除建议，牺牲了使用体验。用户澄清：**明确删除 = 用户明确允许**；AI 可以在任务过程中建议删除（说明对象、理由、影响），用户明确同意即可执行，不要求预先说出路径。已据此修正 `SKILL.md` 与 `whole-drive.md`；安全底线不变：未获明确允许不执行、含糊不算允许、对象集合变化重新征求。

## 15. 维护手册与 token 归属（2026-11-25 晚）

### 15.1 新增的维护资料

| 文件 | 内容 |
|---|---|
| `docs/maintenance/README.md` | 四条契约、固定节奏、变更处理顺序、当前基线 |
| `docs/maintenance/updates.md` | 官方 skill / CLI / MCP 的检查与更新，合并冲突处理 |
| `docs/maintenance/open-docs.md` | 开放平台文档抓取、对比、WeKnora 入库 |
| `docs/maintenance/mcp-tools.md` | MCP 工具清单基线、导出、比对、变更分类 |
| `docs/maintenance/token.md` | 两个 token 的位置、剩余时间、1Password 集成与轮换 |
| `docs/maintenance/tools/mcp-call.mjs` | 只读 MCP 维护客户端（支持 `MCP_TOKEN` 环境变量，维护用，不被 skill 加载） |
| `docs/maintenance/tools/compare-mcp-tools.mjs` | 两份工具清单的差异比较 |
| `docs/maintenance/tools/scrape-union-docs.mjs` | 开放平台文档抓取 |
| `docs/maintenance/contracts/mcp-tools.baseline.json` | 25 个 MCP 工具的 schema 基线（2026-11-25） |
| `docs/maintenance/contracts/cli-surface.txt` | CLI 命令、参数、JSON 字段的依赖面 |

### 15.2 实测

- MCP 清单导出：连接成功，`count=25`，与基线比对 `ok=true`（无增删、无 schema 变化）；
- 文档抓取：292 页 / 292 文件 / 0 失败，约 5.4 秒；栏目路径与抓取时间注入正确；
- 脚本语法：三个 `.mjs` 通过 `node --check`；
- `mcp-token.sh --status`：输出 `issued_at=2026-11-25T14:48:41`、`remaining_days=29`、`expires_at=2026-12-25T14:48:41+0800`；
- `--issued-at`：用假 token 测试，签发日期按传入值保存（`2026-11-20T00:00:00`），同一 token 重写不重置；非法日期退出 2。

### 15.3 Token 结论

- MCP token 当前写在 `~/.zcode/cli/config.json` → `mcp.servers["baidu-netdisk"].headers.Authorization`；本地元数据在 `%LOCALAPPDATA%\baidu-drive\mcp-token\state.env`。
- MCP token 是 83 字符、4 段 base64url，不是 JWT，没有 `exp`；MCP `user_info` 不返回有效期，平台也没有 introspection 接口，因此**只能按签发时间 + 30 天估算**。
- CLI token 与 MCP token 不是同一个：CLI token 的 `expires_at` 可由 `bdpan whoami --json` 精确读取（实测 `2026-12-25T09:44:50+08:00`）。
- 1Password（shared-credentials）作为唯一真源：`credential_id=baidu-netdisk-mcp`、字段 `MCP_TOKEN`/`ISSUED_AT`，`metadata_status=complete`；本项目只用 `mcp-token.sh` 把 token 同步进宿主配置，不负责签发和续期。ZCode 当前不支持 header 的环境变量插值，所以同步步骤暂时保留。
- 条目由 Hermes（有写权限）于 2026-11-25 创建；本机 Service Account 只读。核对：token 长度 83、sha256 与本地状态一致，MCP 握手成功。
- 已提交到 `custom` 分支。

### 15.4 MCP 重新授权入口（2026-11-25 晚）

- 官方文档给出的个人授权链接（无需创建应用、无需 OAuth 回调）：

  ```text
  https://openapi.baidu.com/oauth/2.0/authorize?response_type=token&client_id=QHOuRXiepJBMjtk0esLhrPoNlQyYd0mF&redirect_uri=oob&scope=basic,netdisk&qrcode=1
  ```

- 授权成功后浏览器跳到 `https://openapi.baidu.com/oauth/2.0/login_success#expires_in=2592000&access_token=...`；`expires_in=2592000` 即 30 天，从官方文档层面确认了有效期。
- `mcp-token.sh` 新增：
  - `--auth-url`：打印上面的授权链接，不需要 token；
  - `--clipboard`：从系统剪贴板读取回跳 URL 或裸 token，直接写入配置，不打印 token；Windows 用 `powershell Get-Clipboard`，macOS 用 `pbpaste`，Linux 用 `wl-paste`/`xclip`。
- 实测：`--auth-url` 输出与官方文档一致；用 stub `powershell.exe` 模拟剪贴板，能从 `login_success` URL 提取 token、写入假配置、记录 `issued_at`，冲突参数退出 2；未读取真实剪贴板。
- `SKILL.md` 新增“MCP 授权过期（30 天）”运行手册；`whole-drive.md` 第 6 节与 `docs/maintenance/token.md` 同步了链接、最小操作和 1Password 顺序。
- 用户操作被压缩到三步：打开链接并授权 → 复制回跳 URL → 运行 `--clipboard`（可由 Agent 执行）。

### 15.5 1Password 写入（2026-11-25 晚）

- 本机尝试：从 ZCode 配置读取 token，经 stdin 管道交给 `credentials.py set`；第一次 `op item create` 被拒绝：

  ```text
  ERROR: op item create failed: ... Permission: (101) You do not have permission to perform this action
  ```

  本机 Service Account 对 `Agent Credentials` 只有读权限，所以未创建、未泄露。
- 由 Hermes（有写权限）完成创建：vault `Agent Credentials`，标题 `百度网盘 MCP Token`，`credential_id=baidu-netdisk-mcp`，字段 `MCP_TOKEN`、`ISSUED_AT`，`metadata_status=complete`，`expires_at=2026-12-25T14:48:41+08:00`。
- 本机只读核对：`run` 输出 `token_len=83`、sha256 前 16 位 `4158ef14871cb19f` 与本地 state 一致、`issued_at` 一致；用库里的 token 做 MCP 握手成功（`MCP SSE Server 1.0.0`）。
- 同步链路实测：从 1Password `run` 注入 token → `mcp-token.sh --stdin --issued-at` 写入临时 config，`token_length=83`、`issued_at` 保留、Authorization header 正确；未触碰真实 ZCode 配置。
- 结论：1Password 已成为真源；ZCode 配置仍是静态副本，轮换时按 `docs/maintenance/token.md` 同步。已提交到 `custom` 分支。
