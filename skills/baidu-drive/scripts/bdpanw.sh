#!/usr/bin/env bash
# bdpanw.sh — bdpan CLI adapter for the baidu-drive skill (personal fork).
#
# Scope is deliberately narrow:
#   * locate the bdpan binary
#   * hand remote paths to the CLI verbatim under Git Bash, convert local paths
#   * add the public telemetry parameters (policy: minimal by default)
#   * force --json and --no-check-update
#   * turn the CLI's inconsistent output into a reliable exit status
#   * fix `ls` of an empty directory (the CLI prints the directory itself)
#
# Out of scope: MCP sessions, retries, and deciding whether a failed write really
# happened. The skill tells the Agent to confirm with fsid / md5 / task ids and to
# stop and report when the outcome cannot be established.
#
# usage: bash bdpanw.sh <bdpan-subcommand> [args...]
# env:   BDPANW_TELEMETRY=minimal|full|none   (default: minimal)
#        BDPANW_AGENTNAME   BDPANW_SESSION_ID   BDPANW_SESSION_INPUT
#        BDPANW_STATE_DIR   (default: %LOCALAPPDATA%\baidu-drive or ~/.cache/baidu-drive)
set -u

usage() {
  cat >&2 <<'EOF'
usage: bash bdpanw.sh <bdpan-subcommand> [args...]

Runs one bdpan CLI command with the flags and path handling this skill needs.
Adds --json and --no-check-update unless they are already present.

BDPANW_TELEMETRY: minimal (default) | full | none
  minimal  --agentname + --session-id
  full     adds --session-input from BDPANW_SESSION_INPUT
  none     adds no telemetry parameters
EOF
}

if [ $# -eq 0 ]; then usage; exit 2; fi
case "${1:-}" in -h|--help) usage; exit 0;; esac

TELEMETRY="${BDPANW_TELEMETRY:-minimal}"
case "$TELEMETRY" in
  minimal|full|none) ;;
  *) echo "bdpanw: invalid BDPANW_TELEMETRY=$TELEMETRY (minimal|full|none)" >&2; exit 2;;
esac

find_bdpan() {
  local candidate
  if command -v bdpan >/dev/null 2>&1; then command -v bdpan; return 0; fi
  for candidate in \
    "${LOCALAPPDATA:-}/bdpan/bdpan.exe" \
    "${LOCALAPPDATA:-}/bdpan/bdpan" \
    "$HOME/AppData/Local/bdpan/bdpan.exe" \
    "$HOME/.local/bin/bdpan" \
    "$HOME/.local/bin/bdpan.exe"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}
BIN="$(find_bdpan)" || { echo "bdpanw: bdpan not found — run the skill's scripts/install.sh first" >&2; exit 1; }

MSYS=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) MSYS=1;; esac

state_dir() {
  if [ -n "${BDPANW_STATE_DIR:-}" ]; then printf '%s\n' "$BDPANW_STATE_DIR"; return; fi
  if [ "$MSYS" = 1 ]; then
    printf '%s\n' "${LOCALAPPDATA:-$HOME/AppData/Local}/baidu-drive"
  else
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/baidu-drive"
  fi
}

rand6() {
  od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%06x' $(( (RANDOM * 32768 + RANDOM) % 16777216 ))
}

# One session id per host conversation. The upstream skill requires the
# {timestamp}-{6 random} shape and reuse within a conversation.
session_id() {
  if [ -n "${BDPANW_SESSION_ID:-}" ]; then printf '%s\n' "$BDPANW_SESSION_ID"; return; fi
  local host="${ZCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${HERMES_SESSION_ID:-}}}}"
  if [ -z "$host" ]; then printf '%s-%s\n' "$(date +%s)" "$(rand6)"; return; fi
  local dir key
  dir="$(state_dir)/sessions"
  key="$(printf '%s' "$host" | sha256sum | cut -c1-16)"
  if [ -f "$dir/$key" ]; then
    cat "$dir/$key"
    return
  fi
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s-%s\n' "$(date +%s)" "$(rand6)" | tee "$dir/$key" >/dev/null
  cat "$dir/$key"
}

agent_name() {
  if [ -n "${BDPANW_AGENTNAME:-}" ]; then printf '%s\n' "$BDPANW_AGENTNAME"; return; fi
  if [ -n "${ZCODE_APP_VERSION:-}${ZCODE_SESSION_ID:-}" ]; then printf 'zcode\n'
  elif [ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]; then printf 'claude-code\n'
  elif [ -n "${HERMES_SESSION_ID:-}" ]; then printf 'hermes\n'
  else printf 'baidu-drive\n'; fi
}

# Local paths must reach the native binary in Windows form when Git Bash is in use.
to_native_local() {
  local path="$1"
  if [ "$MSYS" = 1 ] && command -v cygpath >/dev/null 2>&1; then
    case "$path" in
      /*) cygpath -m "$path"; return;;
    esac
  fi
  printf '%s\n' "$path"
}

# Flags whose next argument is a value (so it must not be treated as positional).
takes_value() {
  case "$1" in
    --agentname|--session-id|--session-input|--uid|--traceid|--config-path|--anonymous-id|\
    -p|--pwd|-d|--dir|-t|--transfer-dir|--period|--category|--page|--page-size|--start|\
    --limit|--order|--dir-fsid|--file-types|--fsid|--page-start|--page-end|--source-dir)
      return 0;;
  esac
  return 1
}

has_arg() {
  local needle="$1" item
  shift
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

args=()
pos_idx=()
positionals=()
skip_next=0
for item in "$@"; do
  if [ "$skip_next" = 1 ]; then
    args+=("$item"); skip_next=0; continue
  fi
  case "$item" in
    -*) args+=("$item"); takes_value "$item" && skip_next=1; continue;;
    *)  pos_idx+=("$((${#args[@]}))"); positionals+=("$item"); args+=("$item");;
  esac
done

command_name="${positionals[0]:-}"
case "$command_name" in
  upload)
    [ "${#pos_idx[@]}" -ge 2 ] && args["${pos_idx[1]}"]="$(to_native_local "${args[${pos_idx[1]}]}")"
    ;;
  download)
    [ "${#pos_idx[@]}" -ge 3 ] && args["${pos_idx[2]}"]="$(to_native_local "${args[${pos_idx[2]}]}")"
    ;;
esac

if [ "$TELEMETRY" != "none" ]; then
  has_arg --agentname "${args[@]}" || args+=(--agentname "$(agent_name)")
  has_arg --session-id "${args[@]}" || args+=(--session-id "$(session_id)")
  if [ "$TELEMETRY" = "full" ] && [ -n "${BDPANW_SESSION_INPUT:-}" ]; then
    has_arg --session-input "${args[@]}" || args+=(--session-input "$BDPANW_SESSION_INPUT")
  fi
fi
has_arg --json "${args[@]}" || args+=(--json)
has_arg --no-check-update "${args[@]}" || args+=(--no-check-update)

out_file="$(mktemp "${TMPDIR:-/tmp}/bdpanw-out-XXXXXX")"
err_file="$(mktemp "${TMPDIR:-/tmp}/bdpanw-err-XXXXXX")"
trap 'rm -f "$out_file" "$err_file"' EXIT

MSYS_NO_PATHCONV=1 "$BIN" "${args[@]}" >"$out_file" 2>"$err_file"
rc=$?

out="$(cat "$out_file")"
if [ -s "$err_file" ]; then cat "$err_file" >&2; fi

# `ls` of an empty directory returns the directory itself as its only entry.
if [ "$command_name" = "ls" ]; then
  dir_arg="${positionals[1]:-}"
  case "$dir_arg" in
    ""|".") abs="/apps/bdpan";;
    /apps/bdpan|/apps/bdpan/) abs="/apps/bdpan";;
    /apps/bdpan/*) abs="${dir_arg%/}";;
    /*) abs="";;                       # out-of-scope: never a valid listing
    *) abs="/apps/bdpan/${dir_arg%/}";;
  esac
  if [ -n "$abs" ]; then
    if command -v jq >/dev/null 2>&1; then
      if printf '%s' "$out" | MSYS_NO_PATHCONV=1 jq -e --arg p "$abs" \
        'type == "array" and length == 1 and (.[0].isdir == true) and (.[0].path == $p)' >/dev/null 2>&1; then
        out='[]'
      fi
    elif [ "$(printf '%s' "$out" | grep -c '"fsid"')" = "1" ] \
         && printf '%s' "$out" | grep -qF "\"$abs\"" \
         && printf '%s' "$out" | grep -Eq '"isdir"[[:space:]]*:[[:space:]]*true'; then
      out='[]'
    fi
  fi
fi

if [ -n "$out" ]; then printf '%s\n' "$out"; fi

# Success is judged from the payload because the CLI exits 0 for server-side errors.
verdict=1
case "$command_name" in
  version|logout|completion|install|update)
    [ "$rc" -eq 0 ] && verdict=0
    ;;
  *)
    if [ "$rc" -eq 0 ]; then
      if command -v jq >/dev/null 2>&1; then
        printf '%s' "$out" | jq -e '
          if type == "array" then true
          elif has("code") then (.code == 0)
          elif has("status") then (.status == "ok" or .status == "submitted" or .status == 0)
          elif has("errno") then (.errno == 0)
          elif has("authenticated") then (.authenticated == true)
          else true end' >/dev/null 2>&1 && verdict=0
      else
        if printf '%s' "$out" | grep -Eq '"code"[[:space:]]*:[[:space:]]*0([^0-9]|$)' \
           || printf '%s' "$out" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"(ok|submitted)"' \
           || printf '%s' "$out" | grep -Eq '"errno"[[:space:]]*:[[:space:]]*0([^0-9]|$)' \
           || printf '%s' "$out" | grep -Eq '^[[:space:]]*\['; then
          verdict=0
        fi
      fi
    fi
    ;;
esac

exit "$verdict"
