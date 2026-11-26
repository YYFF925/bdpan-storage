#!/usr/bin/env bash
# staging.sh — per-task staging directories inside /apps/bdpan/_staging/ plus a
# lightweight local task record. No database, no queue, no background service.
#
# Why per task: on the server a same-name conflict is silently renamed (MCP ondup
# defaults to newcopy, the CLI appends "(1)"), so two concurrent tasks sharing one
# staging directory can pick up the wrong file. Each task gets its own directory.
#
# Task lifecycle (recorded locally, cleaned only after a confirmed success):
#   preparing -> remote_ready -> local_done -> done -> cleaned
#                                       \-> failed (keep the staging copy and report)
#
# usage:
#   bash staging.sh new <up|dl|read|del>      create a task, print "<id> <remote-path>"
#   bash staging.sh path <id>                 print the remote staging path
#   bash staging.sh status <id>               print the task record
#   bash staging.sh set <id> <key> <value>    update a record (status/note/local/remote)
#   bash staging.sh list                      one line per task
#   bash staging.sh clean <id>                remove the staging directory, require status=done
#   bash staging.sh stale [days]              tasks older than N days (default 7) and not cleaned
#
# env: BDPANW_STATE_DIR, plus every environment variable bdpanw.sh understands.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BD="${HERE}/bdpanw.sh"
[ -f "$BD" ] || { echo "staging: bdpanw.sh missing next to this script" >&2; exit 1; }

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
TASKS="$(state_dir)/tasks"
mkdir -p "$TASKS" 2>/dev/null || true

rand6() {
  od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%06x' $(( (RANDOM * 32768 + RANDOM) % 16777216 ))
}

record() { printf '%s/%s.env\n' "$TASKS" "$1"; }

field() { # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

write_record() { # <id> <kind> <status> <remote> <created> [note]
  local f; f="$(record "$1")"
  {
    printf 'id=%s\n' "$1"
    printf 'kind=%s\n' "$2"
    printf 'status=%s\n' "$3"
    printf 'remote=%s\n' "$4"
    printf 'created_at=%s\n' "$5"
    [ -n "${6:-}" ] && printf 'note=%s\n' "$6"
  } >"$f"
}

cmd_new() {
  local kind="${1:-}"
  case "$kind" in up|dl|read|del) ;; *) echo "staging: kind must be up, dl, read or del" >&2; exit 2;; esac
  local id remote out
  id="$(date +%Y%m%dT%H%M%S)-$(rand6)"
  remote="_staging/${kind}-${id}/"
  if ! out="$(bash "$BD" mkdir "$remote" 2>&1)"; then
    # A collision is the only expected failure here; do not silently reuse it.
    if bash "$BD" ls "$remote" >/dev/null 2>&1; then
      echo "staging: task directory already exists, retry: $remote" >&2
      exit 1
    fi
    echo "staging: could not create $remote" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  write_record "$id" "$kind" remote_ready "$remote" "$(date +%Y-%m-%dT%H:%M:%S)"
  printf '%s %s\n' "$id" "$remote"
}

cmd_path() {
  local f; f="$(record "${1:-}")"
  [ -f "$f" ] || { echo "staging: unknown task ${1:-}" >&2; exit 1; }
  field "$f" remote
}

cmd_status() {
  local f; f="$(record "${1:-}")"
  [ -f "$f" ] || { echo "staging: unknown task ${1:-}" >&2; exit 1; }
  cat "$f"
}

cmd_set() {
  local id="${1:-}" key="${2:-}" value="${3:-}"
  local f; f="$(record "$id")"
  [ -f "$f" ] || { echo "staging: unknown task $id" >&2; exit 1; }
  case "$key" in
    status|note|local|remote) ;;
    *) echo "staging: key must be status, note, local or remote" >&2; exit 2;;
  esac
  if grep -q "^${key}=" "$f"; then
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/staging-rec-XXXXXX")"
    sed "s|^${key}=.*|${key}=${value}|" "$f" >"$tmp" && mv "$tmp" "$f"
  else
    printf '%s=%s\n' "$key" "$value" >>"$f"
  fi
}

cmd_list() {
  local f
  for f in "$TASKS"/*.env; do
    [ -f "$f" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(field "$f" id)" "$(field "$f" kind)" "$(field "$f" status)" \
      "$(field "$f" remote)" "$(field "$f" created_at)"
  done
}

# Cleaning is allowed only for a task that reached a confirmed success.
cmd_clean() {
  local id="${1:-}" f status remote
  f="$(record "$id")"
  [ -f "$f" ] || { echo "staging: unknown task $id" >&2; exit 1; }
  status="$(field "$f" status)"
  remote="$(field "$f" remote)"
  if [ "$status" != "done" ]; then
    echo "staging: task $id is '$status'; clean only after a confirmed success (status=done)" >&2
    exit 1
  fi
  if bash "$BD" ls "$remote" >/dev/null 2>&1; then
    bash "$BD" rm "$remote" --force >/dev/null || {
      echo "staging: could not remove $remote; the copy is still there" >&2
      exit 1
    }
  fi
  cmd_set "$id" status cleaned
  echo "cleaned $id"
}

# YYYY-MM-DD[THH:MM:SS] -> seconds: GNU date, then BSD/macOS date -j.
to_epoch() {
  date -d "$1" +%s 2>/dev/null && return 0
  date -j -f '%Y-%m-%d %H:%M:%S' "${1/T/ }" +%s 2>/dev/null && return 0
  date -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null
}

cmd_stale() {
  local days="${1:-7}" f created status now cutoff
  now="$(date +%s)"
  for f in "$TASKS"/*.env; do
    [ -f "$f" ] || continue
    status="$(field "$f" status)"
    [ "$status" = "cleaned" ] && continue
    created="$(field "$f" created_at)"
    cutoff="$(to_epoch "$created" || echo "$now")"
    if [ $(( (now - cutoff) / 86400 )) -ge "$days" ]; then
      printf '%s\t%s\t%s\t%s\n' "$(field "$f" id)" "$status" "$(field "$f" remote)" "$created"
    fi
  done
}

case "${1:-}" in
  new)    shift; cmd_new "$@";;
  path)   shift; cmd_path "$@";;
  status) shift; cmd_status "$@";;
  set)    shift; cmd_set "$@";;
  list)   cmd_list;;
  clean)  shift; cmd_clean "$@";;
  stale)  shift; cmd_stale "$@";;
  *)      echo "usage: bash staging.sh new <up|dl|read|del> | path <id> | status <id> | set <id> <key> <value> | list | clean <id> | stale [days]" >&2; exit 2;;
esac
