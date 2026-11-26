#!/usr/bin/env bash
# mcp-token-hermes.sh — Hermes target for `mcp-token.sh --host hermes`.
#
# Hermes keeps MCP bearer tokens out of config.yaml: the server entry holds the template
# `Authorization: Bearer ${MCP_BAIDU_NETDISK_API_KEY}` and the value lives in the profile's
# .env (what `hermes mcp add --auth header` produces). This helper keeps that split:
#   * adds the mcp_servers entry through `hermes config set` (Hermes' own config writer) when missing
#   * replaces the value in .env with shell only: read, rewrite, atomic rename, re-read and compare
#     a digest. No Python, no Hermes internals — runs on macOS' bash 3.2 and everywhere else
#   * keeps the file mode and every other line; re-running with the same token changes nothing
#
# The token arrives in the environment and is never printed, logged or put on a command line.
#
# usage: MCP_TOKEN=<token> BDPANW_TOKEN_SHA256=<sha256> bash mcp-token-hermes.sh <hermes-home>/.env
# env:   HERMES_BIN  hermes CLI to use; default is `hermes` on PATH, then <hermes-home>/bin
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
ENV_FILE="$HOME_DIR/$(basename "$ENV_FILE")"

msys=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) msys=1;; esac
# The hermes CLI is a native program and Hermes' terminal disables MSYS path conversion, so hand
# it a Windows-style home instead of /c/... one.
if [ "$msys" = 1 ]; then HERMES_HOME="$(cygpath -w "$HOME_DIR")"; else HERMES_HOME="$HOME_DIR"; fi
export HERMES_HOME

sha256_hex() {                # sha256 of stdin as lowercase hex (GNU, then macOS/Perl shasum)
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    return 1
  fi | cut -d' ' -f1
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Same quoting rule as Hermes' own .env writer: only values with '#' or quotes or whitespace.
serialize_value() {
  case "$1" in
    *'#'*|*'"'*|*"'"*|*[[:space:]]*)
      printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" ;;
    *) printf '%s' "$1" ;;
  esac
}

env_key_of_line() {           # KEY of a .env line (export prefix and spaces tolerated, like Hermes)
  local body="$1"
  case "$body" in "export "*) body="${body#export }" ;; esac
  printf '%s' "${body%%=*}" | tr -d '[:space:]'
}

write_env_value() {           # write_env_value <file> <key> <value>
  local file="$1" key="$2" value="$3" dir tmp lock waited=0 name line found=0 serialized mode ending last_ending
  dir="$(dirname "$file")"
  serialized="$(serialize_value "$value")"
  # Hermes' own lock is a native flock we cannot share; this serialises our own concurrent runs.
  lock="$file.lock.d"
  while ! mkdir "$lock" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -ge 10 ] && break
    sleep 1
  done
  tmp="$(mktemp "$dir/.env-token.XXXXXX")" || { rmdir "$lock" 2>/dev/null; return 1; }
  last_ending=""
  if [ -f "$file" ]; then
    mode="$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null || true)"
    [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null
    while IFS= read -r line || [ -n "$line" ]; do
      ending=""   # keep the file's own line ending (a CRLF .env must not gain an LF-only line)
      case "$line" in *$'\r') ending=$'\r' ;; esac
      name="$(env_key_of_line "$line")"
      if [ "$name" = "$key" ]; then
        if [ "$found" = 0 ]; then
          printf '%s=%s%s\n' "$key" "$serialized" "$ending" >> "$tmp"; found=1
        fi
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
      last_ending="$ending"
    done < "$file"
  fi
  if [ "$found" = 0 ]; then
    # The loop already terminated the last line with \n; no extra separator is needed.
    printf '%s=%s%s\n' "$key" "$serialized" "$last_ending" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock" 2>/dev/null; return 1; }
  fi
  if ! mv "$tmp" "$file"; then rm -f "$tmp"; rmdir "$lock" 2>/dev/null; return 1; fi
  rmdir "$lock" 2>/dev/null
  return 0
}

read_env_value() {            # last assignment of <key> in <file>, surrounding double quotes removed
  local file="$1" key="$2" line name value last=""
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    name="$(env_key_of_line "$line")"
    [ "$name" = "$key" ] || continue
    value="${line#*=}"
    value="${value%$'\r'}"
    case "$value" in \"*\") value="${value#\"}"; value="${value%\"}" ;; esac
    last="$value"
  done < "$file"
  [ -n "$last" ] || return 1
  printf '%s' "$last"
}

# ---- locate the hermes CLI (only for the server entry; the token write needs no helper) ----
find_hermes() {
  local candidate
  for candidate in "${HERMES_BIN:-}" hermes "$HOME_DIR/bin/hermes.exe" "$HOME_DIR/bin/hermes"; do
    [ -n "$candidate" ] || continue
    command -v "$candidate" >/dev/null 2>&1 && { command -v "$candidate"; return 0; }
  done
  return 1
}
HERMES="$(find_hermes)" || fail "hermes CLI not found; add the server by hand: hermes mcp add $SERVER --url $URL --auth header"

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

# ---- 2. the value -------------------------------------------------------------------
write_env_value "$ENV_FILE" "$ENV_KEY" "$MCP_TOKEN" || fail "could not write $ENV_KEY to $ENV_FILE"
saved="$(read_env_value "$ENV_FILE" "$ENV_KEY")" || fail "$ENV_KEY is missing from $ENV_FILE after the write"
saved_hash="$(printf '%s' "$saved" | sha256_hex)" || fail "no sha256 tool (sha256sum or shasum) to verify the write"
[ "$saved_hash" = "$BDPANW_TOKEN_SHA256" ] || fail "the saved value does not match; the .env write was not verified"

# ---- 3. report ---------------------------------------------------------------------
printf '{"ok":true,"env":"%s","key":"%s","token_length":%s},"server_added":%s}\n' \
  "$(json_escape "$ENV_FILE")" "$ENV_KEY" "${#MCP_TOKEN}" "$SERVER_ADDED"
