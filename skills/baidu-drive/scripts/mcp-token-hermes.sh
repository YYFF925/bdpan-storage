#!/usr/bin/env bash
# mcp-token-hermes.sh — Hermes target for `mcp-token.sh --host hermes`.
#
# Hermes keeps MCP bearer tokens out of config.yaml: the server entry holds the template
# `Authorization: Bearer ${MCP_BAIDU_NETDISK_API_KEY}` and the value lives in the profile's
# .env (what `hermes mcp add --auth header` produces). This helper keeps that split:
#   * adds the mcp_servers entry through `hermes config set` (Hermes' own config writer) when missing
#   * writes the value through Hermes' own save_env_value, so the file lock, quoting and atomic
#     replace are the same ones the running gateway uses
#   * re-reads the file and compares a digest before reporting success
#
# The token arrives in the environment and is never printed, logged or put on a command line.
#
# usage: MCP_TOKEN=<token> BDPANW_TOKEN_SHA256=<sha256> bash mcp-token-hermes.sh <hermes-home>/.env
# env:   HERMES_PYTHON  interpreter to use; default is the first one that can import hermes_cli
#        HERMES_BIN     hermes CLI to use; default is `hermes` on PATH, then <hermes-home>/bin
# prints: one JSON line {"ok":true|false, ...}   exits: 0 success, 1 failure, 2 usage
set -u

SERVER="baidu-netdisk"
ENV_KEY="MCP_BAIDU_NETDISK_API_KEY"
URL="https://mcp-pan.baidu.com/sse"

fail() {
  printf '{"ok":false,"error":"%s"}\n' "$(printf '%s' "$1" | tr -d '"\\' | tr '\n' ' ')"
  exit 1
}

[ $# -eq 1 ] && [ -n "${MCP_TOKEN:-}" ] && [ -n "${BDPANW_TOKEN_SHA256:-}" ] || {
  echo "usage: MCP_TOKEN=<token> BDPANW_TOKEN_SHA256=<sha256> bash mcp-token-hermes.sh <hermes-home>/.env" >&2
  exit 2
}
ENV_FILE="$1"
HOME_DIR="$(cd "$(dirname "$ENV_FILE")" 2>/dev/null && pwd)" || fail "directory of $ENV_FILE not found"
[ -f "$HOME_DIR/config.yaml" ] || fail "$HOME_DIR has no config.yaml, so it is not a Hermes home"

msys=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) msys=1;; esac
# Python and the hermes CLI are native programs and Hermes' terminal disables MSYS path
# conversion, so hand them Windows-style paths instead of /c/... ones.
if [ "$msys" = 1 ]; then
  HERMES_HOME="$(cygpath -w "$HOME_DIR")"
  ENV_FILE_ARG="$(cygpath -w "$ENV_FILE")"
else
  HERMES_HOME="$HOME_DIR"
  ENV_FILE_ARG="$ENV_FILE"
fi
export HERMES_HOME

# ---- locate the hermes CLI and an interpreter that can import hermes_cli ------------
find_hermes() {
  local candidate
  for candidate in "${HERMES_BIN:-}" hermes "$HOME_DIR/bin/hermes.exe" "$HOME_DIR/bin/hermes"; do
    [ -n "$candidate" ] || continue
    command -v "$candidate" >/dev/null 2>&1 && { command -v "$candidate"; return 0; }
  done
  return 1
}

imports_hermes() { "$1" -c 'import hermes_cli.config' >/dev/null 2>&1; }

newest_venvs() { # venv interpreters under <home>/installs, newest environment first
  local venv
  find "$HOME_DIR/installs" -maxdepth 5 -type d -name venv 2>/dev/null | while IFS= read -r venv; do
    [ -x "$venv/Scripts/python.exe" ] && printf '%s\t%s\n' "$(stat -c %Y "$venv" 2>/dev/null || echo 0)" "$venv/Scripts/python.exe"
    [ -x "$venv/bin/python" ] && printf '%s\t%s\n' "$(stat -c %Y "$venv" 2>/dev/null || echo 0)" "$venv/bin/python"
  done | sort -rn | cut -f2-
}

find_python() {
  local candidate found=""
  if [ -n "${HERMES_PYTHON:-}" ]; then
    imports_hermes "$HERMES_PYTHON" && { printf '%s\n' "$HERMES_PYTHON"; return 0; }
    return 1
  fi
  # Inside a Hermes terminal `python` already is the runtime's interpreter.
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    imports_hermes "$candidate" && { found="$candidate"; break; }
  done < <(command -v python 2>/dev/null; command -v python3 2>/dev/null; newest_venvs)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

HERMES="$(find_hermes)" || fail "hermes CLI not found; add the server by hand: hermes mcp add $SERVER --url $URL --auth header"
PY="$(find_python)" || fail "no Python that can import hermes_cli; set HERMES_PYTHON to the Hermes runtime interpreter"

# ---- 1. the server entry (without it the token is never used) ----------------------
SERVER_ADDED=false
if ! "$HERMES" config get "mcp_servers.$SERVER.url" >/dev/null 2>&1; then
  # Single quotes keep ${...} a template; Hermes resolves it from .env at connect time.
  # The server speaks SSE only: naming the transport skips a Streamable HTTP attempt that 405s.
  "$HERMES" config set "mcp_servers.$SERVER.url" "$URL" >/dev/null 2>&1 &&
  "$HERMES" config set "mcp_servers.$SERVER.headers.Authorization" 'Bearer ${'"$ENV_KEY"'}' >/dev/null 2>&1 &&
  "$HERMES" config set "mcp_servers.$SERVER.transport" sse >/dev/null 2>&1 &&
  "$HERMES" config set "mcp_servers.$SERVER.enabled" true >/dev/null 2>&1 ||
    fail "could not add mcp_servers.$SERVER to the Hermes config"
  SERVER_ADDED=true
fi

# ---- 2. the value, through Hermes' own writer --------------------------------------
result="$(MCP_TOKEN="$MCP_TOKEN" BDPANW_ENV_KEY="$ENV_KEY" BDPANW_TOKEN_SHA256="$BDPANW_TOKEN_SHA256" \
  "$PY" - "$ENV_FILE_ARG" 2>/dev/null <<'PY'
import hashlib
import json
import os
import sys

try:
    key = os.environ["BDPANW_ENV_KEY"]
    expected = os.environ["BDPANW_TOKEN_SHA256"]
    token = os.environ["MCP_TOKEN"]

    from hermes_cli.config import get_env_path, load_env, save_env_value

    save_env_value(key, token)
    same_file = os.path.samefile(str(get_env_path()), sys.argv[1])
    saved = load_env().get(key) or ""
    if not same_file:
        outcome = {"ok": False, "error": "HERMES_HOME does not resolve to the given .env; nothing verified"}
    elif hashlib.sha256(saved.encode()).hexdigest() != expected:
        outcome = {"ok": False, "error": "the saved value does not match; Hermes refused the .env write"}
    else:
        outcome = {"ok": True, "env": str(get_env_path()), "key": key, "token_length": len(token)}
except Exception as error:  # the message is not echoed: it could quote the value
    outcome = {"ok": False, "error": "Hermes writer failed: " + type(error).__name__}
# Compact separators: the caller looks for the literal "ok":true, as in the ZCode writer's output.
print(json.dumps(outcome, separators=(",", ":")))
PY
)" || fail "the Hermes writer did not run"
case "$result" in
  *'"ok":true'*) ;;
  *) printf '%s\n' "$result"; exit 1;;
esac

# ---- 3. report ---------------------------------------------------------------------
printf '%s' "$result" | tr -d '\n'
printf ',"server_added":%s}\n' "$SERVER_ADDED"
