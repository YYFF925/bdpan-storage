#!/usr/bin/env bash
# mcp-token.sh — write the Baidu Netdisk MCP access token into a host configuration
# file without letting the value reach the terminal, the conversation or a backup.
#
# What it does:
#   * reads the token from a file, stdin, or the OS clipboard (a whole login_success URL is accepted)
#   * validates it and edits only mcp.servers["baidu-netdisk"].headers.Authorization
#   * writes atomically (temp file + rename) and verifies the result by re-reading
#   * writes a REDACTED backup (Authorization values masked) instead of one that
#     contains the token, and never keeps a plaintext copy
#   * records the token's issue date locally; rewriting the same token keeps the
#     original date, so the 30-day reminder cannot be reset by re-running the script
#
# The MCP token from the personal authorization link is valid for 30 days and cannot
# be refreshed; when it expires the user must authorize again and re-run this script.
#
# usage:
#   bash mcp-token.sh --auth-url
#   bash mcp-token.sh --file <token-file> [--issued-at <date>] [--host zcode] [--config <path>]
#   bash mcp-token.sh --stdin [--issued-at <date>] [--host zcode]
#   bash mcp-token.sh --clipboard [--issued-at <date>] [--host zcode]
#   bash mcp-token.sh --status
#
# --auth-url prints the official personal authorization URL (no token, no network).
# --clipboard reads the copied login_success URL or raw token from the OS clipboard;
# --issued-at preserves the real authorization date when syncing from a vault;
# --status prints the recorded issue date, age, remaining days and expiry estimate.
#
# exits: 0 success, 1 failure, 2 usage
set -u

here="$(cd "$(dirname "$0")" && pwd)"
usage() {
  cat >&2 <<'EOF'
usage: bash mcp-token.sh (--file <token-file> | --stdin | --clipboard) [--issued-at <date>] [--host zcode] [--config <path>]
       bash mcp-token.sh --auth-url
       bash mcp-token.sh --status

The source may contain either the raw access token or the whole login_success URL.
--auth-url prints the official personal authorization URL.
--clipboard reads the copied URL/token from the OS clipboard (Windows/macOS/Linux).
--issued-at accepts YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS and keeps the real authorization date.
--status reads the local record only (no token, no network).
Only --host zcode is configured automatically in phase 1; other hosts need --config.
EOF
}

HOST="zcode"
CONFIG=""
SOURCE=""
STDIN=0
CLIPBOARD=0
STATUS=0
AUTH_URL_MODE=0
ISSUED_AT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2;;
    --config) CONFIG="${2:-}"; shift 2;;
    --file) SOURCE="${2:-}"; shift 2;;
    --stdin) STDIN=1; shift;;
    --clipboard) CLIPBOARD=1; shift;;
    --issued-at) ISSUED_AT="${2:-}"; shift 2;;
    --status) STATUS=1; shift;;
    --auth-url) AUTH_URL_MODE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "mcp-token: unknown argument $1" >&2; usage; exit 2;;
  esac
done

AUTH_URL='https://openapi.baidu.com/oauth/2.0/authorize?response_type=token&client_id=QHOuRXiepJBMjtk0esLhrPoNlQyYd0mF&redirect_uri=oob&scope=basic,netdisk&qrcode=1'
if [ "$AUTH_URL_MODE" = 1 ]; then
  printf '%s\n' "$AUTH_URL"
  exit 0
fi

# ---- local state: token hash + issue date (never the token itself) -------------
msys=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) msys=1;; esac
if [ -n "${BDPANW_STATE_DIR:-}" ]; then
  STATE="$BDPANW_STATE_DIR"
elif [ "$msys" = 1 ]; then
  STATE="${LOCALAPPDATA:-$HOME/AppData/Local}/baidu-drive"
else
  STATE="${XDG_CACHE_HOME:-$HOME/.cache}/baidu-drive"
fi
STATE_DIR="$STATE/mcp-token"
STATE_FILE="$STATE_DIR/state.env"

if [ "$STATUS" = 1 ]; then
  [ -f "$STATE_FILE" ] || { echo "mcp-token: no recorded token state at $STATE_FILE" >&2; exit 1; }
  issued="$(sed -n 's/^issued_at=//p' "$STATE_FILE" | tail -1)"
  [ -n "$issued" ] || { echo "mcp-token: the state file has no issued_at" >&2; exit 1; }
  issued_epoch="$(date -d "$issued" +%s 2>/dev/null || echo "")"
  [ -n "$issued_epoch" ] || { echo "mcp-token: unreadable issued_at: $issued" >&2; exit 1; }
  now_epoch="$(date +%s)"
  expires_epoch=$(( issued_epoch + 30 * 86400 ))
  age_days=$(( (now_epoch - issued_epoch) / 86400 ))
  if [ "$now_epoch" -ge "$expires_epoch" ]; then
    remaining_days=0; expired=yes
  else
    remaining_days=$(( (expires_epoch - now_epoch) / 86400 )); expired=no
  fi
  expires_at="$(date -d "@$expires_epoch" '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'issued_at=%s\nage_days=%s\nremaining_days=%s\nexpires_at=%s\nexpired=%s\n' \
    "$issued" "$age_days" "$remaining_days" "$expires_at" "$expired"
  [ "$expired" = yes ] && echo "WARNING: the 30-day MCP token window has ended; re-authorize." >&2
  [ "$expired" = no ] && [ "$remaining_days" -le 5 ] && echo "WARNING: the MCP token expires within ${remaining_days} days." >&2
  exit 0
fi

if [ -z "$CONFIG" ]; then
  case "$HOST" in
    zcode) CONFIG="$HOME/.zcode/cli/config.json";;
    *) echo "mcp-token: host '$HOST' has no default config yet; pass --config <path>" >&2; exit 2;;
  esac
fi

sources=0
[ -n "$SOURCE" ] && sources=$((sources + 1))
[ "$STDIN" = 1 ] && sources=$((sources + 1))
[ "$CLIPBOARD" = 1 ] && sources=$((sources + 1))
if [ "$sources" -gt 1 ]; then
  echo "mcp-token: use only one of --file, --stdin, --clipboard" >&2; exit 2
fi
if [ "$sources" -eq 0 ]; then
  echo "mcp-token: a token source is required (--file <path>, --stdin or --clipboard)" >&2; exit 2
fi

if [ "$CLIPBOARD" = 1 ]; then
  if command -v powershell.exe >/dev/null 2>&1; then
    raw="$(powershell.exe -NoProfile -Command Get-Clipboard)"
  elif command -v powershell >/dev/null 2>&1; then
    raw="$(powershell -NoProfile -Command Get-Clipboard)"
  elif command -v pbpaste >/dev/null 2>&1; then
    raw="$(pbpaste)"
  elif command -v wl-paste >/dev/null 2>&1; then
    raw="$(wl-paste -n)"
  elif command -v xclip >/dev/null 2>&1; then
    raw="$(xclip -selection clipboard -o)"
  else
    echo "mcp-token: --clipboard is not supported here; use --file or --stdin" >&2; exit 1
  fi
elif [ "$STDIN" = 1 ]; then
  raw="$(cat)"
else
  [ -f "$SOURCE" ] || { echo "mcp-token: token file not found: $SOURCE" >&2; exit 1; }
  raw="$(cat "$SOURCE")"
fi

first_line="$(printf '%s\n' "$raw" | awk 'NF{print; exit}')"
case "$first_line" in
  *access_token=*) token="${first_line#*access_token=}"; token="${token%%&*}";;
  *) token="$first_line";;
esac
token="$(printf '%s' "$token" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [ -z "$token" ] || printf '%s' "$token" | grep -q '[[:space:]]'; then
  echo "mcp-token: the token is empty or contains whitespace" >&2; exit 1
fi
if [ "${#token}" -lt 20 ]; then
  echo "mcp-token: the token looks too short (${#token} characters)" >&2; exit 1
fi

if [ -n "$ISSUED_AT" ]; then
  case "$ISSUED_AT" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ISSUED_AT="${ISSUED_AT}T00:00:00";;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *) echo "mcp-token: --issued-at must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS" >&2; exit 2;;
  esac
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
hash="$(printf '%s' "$token" | sha256sum | cut -c1-16)"
prev_hash="$(sed -n 's/^token_sha256=//p' "$STATE_FILE" 2>/dev/null | tail -1)"
prev_issued="$(sed -n 's/^issued_at=//p' "$STATE_FILE" 2>/dev/null | tail -1)"
if [ -n "$ISSUED_AT" ]; then
  issued="$ISSUED_AT"
  [ "$issued" = "$prev_issued" ] && kept="yes" || kept="no"
elif [ -n "$prev_hash" ] && [ "$hash" = "$prev_hash" ] && [ -n "$prev_issued" ]; then
  issued="$prev_issued"; kept="yes"
else
  issued="$(date +%Y-%m-%dT%H:%M:%S)"; kept="no"
fi

# ---- edit the config atomically -------------------------------------------------
command -v node >/dev/null 2>&1 || {
  echo "mcp-token: node is required for atomic JSON editing; edit the file manually:" >&2
  echo "  set mcp.servers[\"baidu-netdisk\"].headers.Authorization to \"Bearer <token>\"" >&2
  exit 1
}

result="$(MCP_TOKEN="$token" node - "$CONFIG" <<'NODE'
const fs = require('fs');
const [configPath] = process.argv.slice(2);
const token = process.env.MCP_TOKEN || '';
const read = () => JSON.parse(fs.readFileSync(configPath, 'utf8'));
const mask = (config) => {
  const copy = JSON.parse(JSON.stringify(config));
  for (const server of Object.values((copy.mcp && copy.mcp.servers) || {})) {
    if (server && server.headers && typeof server.headers === 'object') {
      for (const key of Object.keys(server.headers)) {
        if (/^authorization$/i.test(key)) server.headers[key] = 'Bearer <redacted>';
      }
    }
  }
  return copy;
};
let original, config;
try {
  original = fs.readFileSync(configPath, 'utf8');
  config = JSON.parse(original);
} catch (error) {
  console.log(JSON.stringify({ ok: false, error: 'existing config is not valid JSON; nothing changed: ' + error.message }));
  process.exit(0);
}
const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '').replace('T', '-');
const backupPath = configPath + '.bak-' + stamp;
try {
  fs.writeFileSync(backupPath, JSON.stringify(mask(config), null, 2) + '\n', 'utf8');
} catch (error) {
  console.log(JSON.stringify({ ok: false, error: 'could not write the redacted backup: ' + error.message }));
  process.exit(0);
}
config.mcp = config.mcp || {};
config.mcp.servers = config.mcp.servers || {};
config.mcp.servers['baidu-netdisk'] = {
  type: 'sse',
  url: 'https://mcp-pan.baidu.com/sse',
  headers: { Authorization: 'Bearer ' + token },
};
const next = JSON.stringify(config, null, 2) + '\n';
const tmpPath = configPath + '.tmp-' + process.pid;
try {
  fs.writeFileSync(tmpPath, next, 'utf8');
  fs.renameSync(tmpPath, configPath);
} catch (error) {
  try { fs.unlinkSync(tmpPath); } catch {}
  try { fs.writeFileSync(configPath, original, 'utf8'); } catch {}
  console.log(JSON.stringify({ ok: false, error: 'atomic write failed, original restored: ' + error.message }));
  process.exit(0);
}
let check;
try { check = JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch (error) {
  try { fs.writeFileSync(configPath, original, 'utf8'); } catch {}
  console.log(JSON.stringify({ ok: false, error: 'verification failed, original restored: ' + error.message }));
  process.exit(0);
}
const saved = check.mcp && check.mcp.servers && check.mcp.servers['baidu-netdisk'];
const savedToken = saved && saved.headers && saved.headers.Authorization;
const ok = typeof savedToken === 'string' && savedToken === 'Bearer ' + token;
if (!ok) {
  try { fs.writeFileSync(configPath, original, 'utf8'); } catch {}
  console.log(JSON.stringify({ ok: false, error: 'verification failed: the saved entry does not match; original restored' }));
  process.exit(0);
}
console.log(JSON.stringify({
  ok: true,
  config: configPath,
  backup: backupPath,
  servers: Object.keys(check.mcp.servers),
  token_length: token.length,
}));
NODE
)"

if ! printf '%s' "$result" | grep -q '"ok":true'; then
  echo "mcp-token: failed: $result" >&2
  exit 1
fi

printf 'token_sha256=%s\nissued_at=%s\n' "$hash" "$issued" > "$STATE_FILE"

# ---- report ----------------------------------------------------------------------
age_days=$(( ( $(date +%s) - $(date -d "$issued" +%s 2>/dev/null || date +%s) ) / 86400 ))
echo "$result"
if [ "$kept" = "yes" ]; then
  echo "issued_at: ${issued}（沿用之前的记录，age ${age_days} 天）"
else
  echo "issued_at: ${issued}（本次新记录，age ${age_days} 天）"
fi
if [ "$age_days" -ge 25 ]; then
  echo "WARNING: the MCP token is ${age_days} days old; it expires after 30 days and cannot be refreshed. Re-authorize soon." >&2
fi
if [ "$msys" = 1 ]; then
  echo "note: ${CONFIG} stores the token in plaintext; do not sync or commit that file." >&2
fi
