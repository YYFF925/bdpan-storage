#!/bin/bash
# update.sh — 本 fork 的更新入口（分轨更新，不覆盖定制）
#
# 本脚本不再从百度配置接口下载官方 skill 包覆盖 skill 目录：
# 官方包会把本 fork 的 SKILL.md、reference/、scripts/ 改动一并覆盖。
#
# 三类对象分开更新：
#   官方 skill     → 本仓库 git fetch upstream && git merge upstream/main
#   本 fork 定制   → 自己的 git 提交
#   bdpan CLI     → 保留官方渠道（bdpan update / 官方安装器），升级后做最小回归
#   MCP Server    → 百度服务端维护；工具清单变化时先对比再使用
#
# 用法:
#   bash update.sh            打印当前版本与更新指引
#   bash update.sh --check    只读查询官方 skill 版本，与本地 VERSION 比较
#
# --yes 被忽略：本 fork 禁止静默更新。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="${SKILL_DIR}/VERSION"
CONFIG_API="https://pan.baidu.com/act/v2/api/conf?conf_key=bd_skills"

usage() {
    cat >&2 <<'EOF'
用法: bash update.sh [选项]

选项:
  --check, -c   只读查询官方 skill 版本并比较，不更新任何文件
  --help, -h    显示帮助信息

本 fork 的更新是分轨的：
  官方 skill → git fetch upstream && git merge upstream/main
  本 fork 定制 → 自己的 git 提交
  bdpan CLI → 官方渠道（bdpan update），升级后按 reference/regression.md 回归
  MCP Server → 百度服务端维护
禁止用官方 skill 包覆盖本目录，禁止静默升级。
EOF
}

local_version() {
    if [ -f "$VERSION_FILE" ]; then tr -d '[:space:]' < "$VERSION_FILE"; else echo "unknown"; fi
}

fetch_official_version() {
    local response=""
    if command -v curl >/dev/null 2>&1; then
        response="$(curl -fsSL --connect-timeout 10 --max-time 30 "$CONFIG_API" 2>/dev/null)" || return 1
    elif command -v wget >/dev/null 2>&1; then
        response="$(wget -qO- --timeout=30 "$CONFIG_API" 2>/dev/null)" || return 1
    else
        echo "update: curl/wget not found" >&2
        return 1
    fi
    printf '%s' "$response" | sed 's/\\u0026/\&/g' | grep -o 'version=[0-9][^"\\&]*' | head -1
}

check_only="no"
for arg in "$@"; do
    case "$arg" in
        --check|-c) check_only="yes" ;;
        --yes|-y)   echo "update: 忽略 --yes（本 fork 禁止静默更新）" >&2 ;;
        --help|-h)  usage; exit 0 ;;
        *)          echo "update: 未知参数 $arg" >&2; usage; exit 2 ;;
    esac
done

local="$(local_version)"
echo "本地 skill 版本: ${local}"

info="$(fetch_official_version)" || {
    echo "update: 无法读取官方版本（网络不可用）" >&2
    exit 1
}
official="${info#version=}"
if [ -z "$official" ]; then
    echo "update: 配置接口没有返回版本" >&2
    exit 1
fi
echo "官方 skill 版本: ${official}"
if [ "$official" = "$local" ]; then
    echo "状态: 官方版本与本 fork 相同"
else
    echo "状态: 官方版本与本地不同；本 fork 有独立改动，禁止用官方包覆盖"
fi

if [ "$check_only" = "yes" ]; then
    exit 0
fi

cat <<'EOF'

更新指引（分轨）：

1. 官方 skill（上游变更）——在本仓库执行：
     git fetch upstream
     git merge upstream/main
   SKILL.md / scripts 出现冲突时逐项复核：本 fork 的全盘章节、
   bdpanw.sh、staging.sh、mcp-token.sh 不能被覆盖掉。

2. 本 fork 的定制——走自己的 git 提交。

3. bdpan CLI——保留官方渠道（bdpan update 或官方安装器）：
     bdpan update check
     bdpan update
   升级后按 reference/regression.md 做最小回归：
     whoami / ls 空目录 / 越界路径 / 上传下载 md5 / 同名上传 / 搜索 / 读正文

4. MCP Server——百度服务端维护；工具清单变化时，先用 tools/list 对比再使用。

禁止：用官方 skill 包覆盖本目录；静默升级 CLI；在没有回归的情况下换 CLI 版本。
EOF
