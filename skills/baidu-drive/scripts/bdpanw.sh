#!/usr/bin/env bash
# bdpanw.sh — bdpan CLI adapter for the baidu-drive skill (personal fork).
#
# Scope is deliberately narrow:
#   * locate the bdpan binary
#   * hand remote paths to the CLI verbatim under Git Bash, convert local paths
#   * add the public telemetry parameters (policy: minimal by default)
#   * add the unified-auth parameters the CLI requires from 3.9.0 (skill name and version)
#   * force --json and --no-check-update
#   * turn the CLI's inconsistent output into a reliable exit status; an interrupted
#     authorization exits non-zero instead of looking like an empty result
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
On CLI >= 3.9.0 also adds --auth-flow cli --skill-name baidu-drive --skill-version <VERSION>
(read from the skill's VERSION file); --auth-confirmed is yours to pass when the user
has confirmed the safety notice in this session.

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

# Short stable digest of stdin for cache keys: sha256 where available, else the POSIX CRC.
hash16() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-16
  else
    cksum | cut -d' ' -f1
  fi
}

# One session id per host conversation. The upstream skill requires the
# {timestamp}-{6 random} shape and reuse within a conversation.
session_id() {
  if [ -n "${BDPANW_SESSION_ID:-}" ]; then printf '%s\n' "$BDPANW_SESSION_ID"; return; fi
  local host="${ZCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${HERMES_SESSION_ID:-}}}}"
  if [ -z "$host" ]; then printf '%s-%s\n' "$(date +%s)" "$(rand6)"; return; fi
  local dir key
  dir="$(state_dir)/sessions"
  key="$(printf '%s' "$host" | hash16)"
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

# CLI 3.9.0+ takes every call through the unified auth entry and needs the skill's name and
# version for it; older CLIs reject those flags. The binary is probed once and the answer is
# kept under the state directory, keyed by the binary's size and mtime so an upgrade re-probes.
supports_auth_flow() {
  local cache identity recorded
  identity="$(stat -c '%s:%Y' "$BIN" 2>/dev/null || stat -f '%z:%m' "$BIN" 2>/dev/null || printf '?')"
  cache="$(state_dir)/cli-auth-flow"
  if [ "$identity" != '?' ]; then
    recorded="$(head -n 1 "$cache" 2>/dev/null || true)"
    case "$recorded" in
      "$identity yes") return 0;;
      "$identity no") return 1;;
    esac
  fi
  if "$BIN" login --help --no-check-update 2>/dev/null | grep -q -- '--auth-flow'; then
    answer=yes
  else
    answer=no
  fi
  # A state directory that cannot be created only costs a probe on every call.
  { mkdir -p "$(state_dir)" && printf '%s %s\n' "$identity" "$answer" >"$cache"; } 2>/dev/null || true
  [ "$answer" = yes ]
}

skill_version() {
  tr -d '[:space:]' <"$(cd "$(dirname "$0")/.." && pwd)/VERSION" 2>/dev/null || true
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
    --auth-flow|--skill-name|--skill-version|\
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

# Local management commands and --help say nothing about authorization; everything else goes
# through the unified auth entry on CLIs that have one (the caller may add --auth-confirmed).
needs_auth=1
case "$command_name" in version|logout|completion|install|update) needs_auth=0;; esac
wants_help=0
if has_arg -h "${args[@]}" || has_arg --help "${args[@]}"; then wants_help=1; needs_auth=0; fi
if [ "$needs_auth" = 1 ] && ! has_arg --auth-flow "${args[@]}" && supports_auth_flow; then
  SKILL_VERSION="$(skill_version)"
  [ -n "$SKILL_VERSION" ] || { echo "bdpanw: the skill's VERSION file is empty, but the CLI needs it for --skill-version" >&2; exit 2; }
  args+=(--auth-flow cli --skill-name baidu-drive --skill-version "$SKILL_VERSION")
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

# An authorization the CLI could not complete means the command did not run at all.
auth_interrupted() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -e '
      ((.data | objects | .status) // (.status | strings) // "") as $s
      | type == "object"
      and ($s == "confirmation_required" or $s == "authorization_required" or $s == "upgrade_required")' >/dev/null 2>&1
  else
    printf '%s' "$out" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"(confirmation_required|authorization_required|upgrade_required)"'
  fi
}

# Success is judged from the payload because the CLI exits 0 for server-side errors. Help text
# and local management commands print no payload, so there the CLI's own exit status is taken.
verdict=1
judged_by_exit="$wants_help"
case "$command_name" in version|logout|completion|install|update) judged_by_exit=1;; esac
if [ "$judged_by_exit" = 1 ]; then
  [ "$rc" -eq 0 ] && verdict=0
else
  if [ "$rc" -eq 0 ]; then
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$out" | jq -e '
        if type == "array" then true
        elif ((.data | objects | .status) // (.status | strings) // "") as $s
             | ($s == "confirmation_required" or $s == "authorization_required" or $s == "upgrade_required") then false
        elif has("code") then (.code == 0)
        elif has("status") then (.status == "ok" or .status == "submitted" or .status == 0)
        elif has("errno") then (.errno == 0)
        elif has("authenticated") then (.authenticated == true)
        else true end' >/dev/null 2>&1 && verdict=0
    else
      auth_interrupted || {
        if printf '%s' "$out" | grep -Eq '"code"[[:space:]]*:[[:space:]]*0([^0-9]|$)' \
         || printf '%s' "$out" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"(ok|submitted)"' \
         || printf '%s' "$out" | grep -Eq '"errno"[[:space:]]*:[[:space:]]*0([^0-9]|$)' \
           || printf '%s' "$out" | grep -Eq '^[[:space:]]*\['; then
          verdict=0
        fi
      }
    fi
  fi
fi

if [ "$verdict" -ne 0 ] && auth_interrupted; then
  echo "bdpanw: authorization is not complete, so this command did not run — handle the JSON above per the skill's login-confirmation steps" >&2
fi

exit "$verdict"
