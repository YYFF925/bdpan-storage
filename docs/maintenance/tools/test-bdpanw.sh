#!/usr/bin/env bash
# Offline tests for skills/baidu-drive/scripts/bdpanw.sh: no network, no drive.
#
# They run the wrapper against mock CLIs from bdpanw-mock/ and check the two things the wrapper
# is responsible for beyond path handling: which flags it puts on the command line, and how it
# turns the CLI's output into an exit status. The 3.9.0 branch (unified auth entry) is modelled
# from upstream's reference/authentication.md, so these tests prove the wrapper's logic, not the
# real CLI — run reference/regression.md against a real CLI as well.
#
# usage: bash docs/maintenance/tools/test-bdpanw.sh [<skill dir>]
# exits: 0 all passed, 1 a check failed, 2 the wrapper, its VERSION file or a mock is missing
set -u

here="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="${1:-$(cd "$here/../../.." && pwd)/skills/baidu-drive}"
W="$SKILL_DIR/scripts/bdpanw.sh"
[ -f "$W" ] && [ -f "$SKILL_DIR/VERSION" ] || { echo "test-bdpanw: $W or $SKILL_DIR/VERSION not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bdpanw-test-XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/new" "$WORK/canned" "$WORK/old" || exit 2
for pair in bdpan:new bdpan-canned:canned bdpan-old:old; do
  cp "$here/bdpanw-mock/${pair%%:*}" "$WORK/${pair##*:}/bdpan" || exit 2
  chmod +x "$WORK/${pair##*:}/bdpan"
done

export MOCK_LOG="$WORK/log" BDPANW_STATE_DIR="$WORK/state"
export MOCK_SKILL_VERSION="$(tr -d '[:space:]' < "$SKILL_DIR/VERSION")"
export BDPANW_AGENTNAME=test BDPANW_SESSION_ID=1-abcdef    # deterministic command lines
JQ_DIR="$(dirname "$(command -v jq 2>/dev/null)" 2>/dev/null || true)"
CORE="/usr/bin:/bin"
TELEMETRY='--agentname test --session-id 1-abcdef'
AUTH="--auth-flow cli --skill-name baidu-drive --skill-version $MOCK_SKILL_VERSION"
TAIL='--json --no-check-update'
MOCK_DIR=""

pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1  [$3]"; fi; }
use_mock() {                  # use_mock <mock dir> [with-jq]: PATH holds only that mock, coreutils and optionally jq
  PATH="$1:$CORE"
  if [ "${2:-}" = with-jq ] && [ -n "$JQ_DIR" ]; then PATH="$1:$JQ_DIR:$CORE"; fi
  export PATH
  [ "$(command -v bdpan 2>/dev/null)" = "$1/bdpan" ] || { echo "ABORT: bdpan does not resolve to the mock $1/bdpan (got $(command -v bdpan 2>/dev/null))"; exit 99; }
}
run() {                       # run <want-exit> [ENV=v ...] -- <wrapper args...>
  local want="$1" pre=(); shift
  while [ "${1:-}" != -- ]; do pre+=("$1"); shift; done; shift
  case "$(command -v bdpan 2>/dev/null)" in "$WORK"/*/bdpan) ;; *) echo "ABORT: not a mock on PATH"; exit 99;; esac
  OUT="$(env "${pre[@]}" bash "$W" "$@" 2>"$WORK/err")"; RC=$?
  HINT="$(grep -c 'authorization is not complete' "$WORK/err")"
  LAST="$(tail -n 1 "$MOCK_LOG" 2>/dev/null)"
  FLAGS="$(printf '%s\n' "$LAST" | tr ' ' '\n' | grep -c -- '^--auth-flow$')"
  [ "$RC" = "$want" ]
}
sent() {                      # sent <label> <expected command line>
  [ "$LAST" = "$2" ]; check "$1" $? "sent: $LAST"
}
probes() { grep -c '^login --help' "$MOCK_LOG" 2>/dev/null; }
section() { echo; echo "$1"; : > "$MOCK_LOG"; rm -f "$BDPANW_STATE_DIR/cli-auth-flow"; MOCK_DIR="$2"; use_mock "$2" "${3:-}"; }

section "A. command line sent to a CLI with the unified auth entry" "$WORK/new" with-jq
run 0 -- quota; check "business call: exit 0 and the auth flags exactly once" $(( RC != 0 || FLAGS != 1 )) "rc=$RC flags=$FLAGS"
sent "auth flags carry the skill name and the VERSION value" "quota $TELEMETRY $AUTH $TAIL"
run 0 -- version; sent "version: no auth flags" "version $TELEMETRY $TAIL"
run 0 -- ls --help; sent "--help: no auth flags" "ls --help $TELEMETRY $TAIL"
check "--help: the exit status is the CLI's own (0)" $RC "rc=$RC"
run 0 -- ls some/dir --auth-confirmed
sent "--auth-confirmed is passed through, positional arguments stay in place" "ls some/dir --auth-confirmed $TELEMETRY $AUTH $TAIL"
run 0 -- ls some/dir $AUTH
check "flags given by the caller are not repeated" $(( RC != 0 || FLAGS != 1 )) "rc=$RC flags=$FLAGS sent: $LAST"
run 0 -- upload 'C:/local dir/a.txt' 'remote/dir/a.txt' $AUTH
sent "upload: both positional arguments are recognised next to value-taking flags" "upload C:/local dir/a.txt remote/dir/a.txt $AUTH $TELEMETRY $TAIL"
run 0 -- download remote/dir/a.txt 'C:/out dir/a.txt'
sent "download: the auth flags follow the arguments" "download remote/dir/a.txt C:/out dir/a.txt $TELEMETRY $AUTH $TAIL"
check "the CLI was probed once for all of the above" $(( $(probes) != 1 )) "probes=$(probes)"
case "$(head -n 1 "$BDPANW_STATE_DIR/cli-auth-flow" 2>/dev/null)" in *" yes") c=0;; *) c=1;; esac
check "the probe answer is cached under the state directory" $c "$(cat "$BDPANW_STATE_DIR/cli-auth-flow" 2>/dev/null)"

section "B. success shapes with the unified auth entry" "$WORK/new" with-jq
for c in whoami "ls d" "mkdir x" "upload a b" "get-content 1" "quota"; do
  run 0 -- $c; check "$c -> exit 0" $(( RC != 0 )) "rc=$RC out=$OUT"
done
run 0 MOCK_EMPTY_DIR=1 -- ls x
[ "$RC" = 0 ] && [ "$OUT" = "[]" ]; check "the empty-directory fix is still applied" $? "rc=$RC out=$OUT"

section "C. an interrupted authorization never looks like success" "$WORK/new" with-jq
for shape in data flat; do for status in confirmation_required authorization_required upgrade_required; do for rc in 0 1; do
  run 1 MOCK_AUTH=$status MOCK_SHAPE=$shape MOCK_RC=$rc MOCK_CODE=1 -- ls d
  check "status=$status shape=$shape cli_exit=$rc -> exit 1 and a hint on stderr" $(( RC != 1 || HINT != 1 )) "rc=$RC hint=$HINT"
done; done; done
run 1 MOCK_AUTH=authorization_required MOCK_SHAPE=data MOCK_RC=0 MOCK_CODE=0 -- quota
check "code 0 inside the envelope does not hide the interruption" $(( RC != 1 || HINT != 1 )) "rc=$RC hint=$HINT"
run 1 MOCK_AUTH=authorization_required MOCK_SHAPE=flat MOCK_RC=0 -- rm x --force
case "$OUT" in *'"auth_url":"https://example.invalid/a"'*) c=0;; *) c=1;; esac
check "the interruption payload reaches the caller unchanged" $c "out=$OUT"

section "D. ordinary results are not mistaken for an interruption" "$WORK/canned" with-jq
canned() {                    # canned <want-exit> <payload> <wrapper args...>
  printf '%s\n' "$2" > "$WORK/payload"; local want="$1" pre=(MOCK_PAYLOAD="$WORK/payload"); shift 2
  OUT="$(env "${pre[@]}" bash "$W" "$@" 2>"$WORK/err")"; RC=$?
  HINT="$(grep -c 'authorization is not complete' "$WORK/err")"; [ "$RC" = "$want" ]
}
canned 1 '{"code":1,"data":null,"error":"server said no"}' quota; check "code 1 -> exit 1, no hint" $(( RC != 1 || HINT != 0 )) "rc=$RC hint=$HINT"
canned 0 '{"status":"ok"}' mkdir q; check "status ok -> exit 0" $(( RC != 0 )) "rc=$RC"
canned 0 '{"status":"submitted"}' transfer x; check "status submitted -> exit 0" $(( RC != 0 )) "rc=$RC"
canned 0 '[]' ls q; check "empty array -> exit 0" $(( RC != 0 )) "rc=$RC"
canned 0 '{"status":"ok","data":"text"}' cp a b; check "data is a string -> exit 0, no parser error" $(( RC != 0 )) "rc=$RC"
canned 0 '{"code":0,"data":{"status":"authenticated"},"error":""}' whoami; check "authenticated -> exit 0" $(( RC != 0 )) "rc=$RC"
canned 1 '{"authenticated": false,"has_valid_token": false}' whoami; check "whoami false -> exit 1, no hint" $(( RC != 1 || HINT != 0 )) "rc=$RC hint=$HINT"
canned 0 '{"errno":0,"data":{"list":[]}}' search q; check "errno 0 -> exit 0" $(( RC != 0 )) "rc=$RC"

if [ -n "$JQ_DIR" ]; then
  section "E. the same without jq on PATH" "$WORK/new"
  run 0 -- quota; check "auth flags still added" $(( RC != 0 || FLAGS != 1 )) "rc=$RC flags=$FLAGS"
  run 0 -- mkdir x; check "status ok -> exit 0" $(( RC != 0 )) "rc=$RC"
  run 0 -- ls q; check "empty array -> exit 0" $(( RC != 0 )) "rc=$RC"
  for shape in data flat; do
    run 1 MOCK_AUTH=authorization_required MOCK_SHAPE=$shape MOCK_RC=0 MOCK_CODE=0 -- ls d
    check "interruption shape=$shape -> exit 1 and a hint" $(( RC != 1 || HINT != 1 )) "rc=$RC hint=$HINT"
  done
  run 1 MOCK_AUTH=confirmation_required MOCK_SHAPE=data MOCK_RC=1 -- rm x
  check "interruption with cli exit 1 -> exit 1" $(( RC != 1 )) "rc=$RC"
else
  echo; echo "E. the same without jq on PATH: skipped (jq is not installed, so A-D already ran without it)"
fi

section "F. an empty VERSION file is refused before anything is sent" "$WORK/new" with-jq
mkdir -p "$WORK/skill/scripts"; cp "$SKILL_DIR/scripts/"*.sh "$WORK/skill/scripts/"; : > "$WORK/skill/VERSION"
OUT="$(bash "$WORK/skill/scripts/bdpanw.sh" quota 2>"$WORK/err")"; RC=$?
check "exit 2" $(( RC != 2 )) "rc=$RC"
grep -q 'VERSION' "$WORK/err"; check "the message names the VERSION file" $? "$(head -n 1 "$WORK/err")"
check "only the local capability probe reached the CLI, no business call" $(( "$(grep -v -c '^login --help --no-check-update$' "$MOCK_LOG")" != 0 )) "calls=$(wc -l < "$MOCK_LOG")"

section "G. a CLI without the unified auth entry gets no auth flags" "$WORK/old"
run 0 -- quota
sent "business call goes through without the auth flags" "quota $TELEMETRY $TAIL"
check "exit 0" $(( RC != 0 )) "rc=$RC out=$OUT"
check "the other binary was probed again" $(( $(probes) != 1 )) "probes=$(probes)"
case "$(head -n 1 "$BDPANW_STATE_DIR/cli-auth-flow" 2>/dev/null)" in *" no") c=0;; *) c=1;; esac
check "the cache says no for this binary" $c "$(cat "$BDPANW_STATE_DIR/cli-auth-flow" 2>/dev/null)"

echo; echo "H. portability lint (macOS ships bash 3.2)"
lint="$(for f in "$SKILL_DIR"/scripts/*.sh; do
  awk '/<<</ { next } /<</ && !/^[[:space:]]*(cat[[:space:]]|#)/ { printf "%s:%d ", FILENAME, FNR }' "$f"
done)"
[ -z "$lint" ]; check "every here-document is a plain 'cat' command (a heredoc inside \$( ) does not parse on bash 3.2)" $? "$lint"

echo; echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
