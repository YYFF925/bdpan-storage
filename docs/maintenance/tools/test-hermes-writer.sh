#!/usr/bin/env bash
# Offline tests for skills/baidu-drive/scripts/mcp-token-hermes.sh: no network, no drive.
#
# They drive the helper against fixture Hermes homes and a stub `hermes` CLI, and check what the
# token writer promises: the value is replaced in place, the file keeps its own line endings and
# permissions, every other line is untouched, re-running changes nothing, a wrong digest is
# reported instead of swallowed.
#
# usage: bash docs/maintenance/tools/test-hermes-writer.sh [<helper>]
# exits: 0 all passed, 1 a check failed, 2 the helper is missing
set -u

here="$(cd "$(dirname "$0")" && pwd)"
S="${1:-$(cd "$here/../../.." && pwd)/skills/baidu-drive/scripts/mcp-token-hermes.sh}"
[ -f "$S" ] || { echo "test-hermes-writer: $S not found" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/hermes-writer-XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
TOKEN="$(printf 'tok%.0s' $(seq 1 27))abc"   # 84 chars, no quotes or whitespace
SHA="$(printf '%s' "$TOKEN" | sha256sum 2>/dev/null | cut -d' ' -f1)"
[ -n "$SHA" ] || SHA="$(printf '%s' "$TOKEN" | shasum -a 256 | cut -d' ' -f1)"
mkdir -p "$T/bin"
cat > "$T/bin/hermes" <<'STUB'
#!/usr/bin/env bash
# stub: the server entry looks missing, every config set succeeds
case "$1 $2" in "config get") exit 1;; "config set") exit 0;; esac
exit 1
STUB
chmod +x "$T/bin/hermes"
run() { PATH="$T/bin:$PATH" MCP_TOKEN="$TOKEN" BDPANW_TOKEN_SHA256="$SHA" bash "$S" "$1"; }
fail=0
ck() { if [ "$2" = 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1  [${3:-}]"; fail=$((fail + 1)); fi; }
is_ok() { case "$1" in *'"ok":true'*) return 0;; *) return 1;; esac; }
cr_bytes() { tr -cd '\r' < "$1" | wc -c | tr -d ' '; }
nonkey_digest() { grep -v '^MCP_' "$1" | md5sum; }

echo "1. CRLF file: the replaced line keeps CRLF, other lines untouched, JSON says ok"
H="$T/crlf"; mkdir -p "$H"; printf 'model: {}\n' > "$H/config.yaml"
printf 'A=1\r\nMCP_BAIDU_NETDISK_API_KEY=old\r\nB=2\r\n' > "$H/.env"
cp "$H/.env" "$T/before.env"
OUT="$(run "$H/.env" 2>&1)"; rc=$?
is_ok "$OUT"; ck "ok:true (rc=$rc)" $? "$OUT"
[ "$(cr_bytes "$H/.env")" = 3 ]; ck "all three lines still CRLF" $? "$(cr_bytes "$H/.env")"
[ "$(nonkey_digest "$H/.env")" = "$(nonkey_digest "$T/before.env")" ]; ck "A=1 and B=2 untouched" $?
cp "$H/.env" "$T/once.env"
OUT="$(run "$H/.env" 2>&1)"
cmp -s "$H/.env" "$T/once.env"; ck "second run is byte-identical" $?
is_ok "$OUT"; ck "second run still ok:true" $? "$OUT"

echo "2. LF file, key appended, no stray blank line, no CR"
H2="$T/lf"; mkdir -p "$H2"; printf 'model: {}\n' > "$H2/config.yaml"; printf 'A=1\nB=2\n' > "$H2/.env"
OUT="$(run "$H2/.env" 2>&1)"; rc=$?
is_ok "$OUT"; ck "ok:true (rc=$rc)" $? "$OUT"
[ "$(cr_bytes "$H2/.env")" = 0 ]; ck "no CR in an LF file" $?
[ "$(grep -c '^$' "$H2/.env")" = 0 ]; ck "no blank line introduced" $? "$(grep -c '^$' "$H2/.env")"
[ "$(awk -F= '{print $1}' "$H2/.env" | tr '\n' ' ')" = "A B MCP_BAIDU_NETDISK_API_KEY " ]; ck "keys in order A,B,KEY" $?

echo "3. last line without a trailing newline"
H3="$T/nonl"; mkdir -p "$H3"; printf 'model: {}\n' > "$H3/config.yaml"; printf 'A=1' > "$H3/.env"
OUT="$(run "$H3/.env" 2>&1)"
is_ok "$OUT"; ck "ok:true" $? "$OUT"
[ "$(awk 'END{print NR}' "$H3/.env")" = 2 ]; ck "file has two lines" $? "$(awk 'END{print NR}' "$H3/.env")"

echo "4. duplicate key lines collapse to one"
H4="$T/dup"; mkdir -p "$H4"; printf 'model: {}\n' > "$H4/config.yaml"
printf 'MCP_BAIDU_NETDISK_API_KEY=one\nX=1\nMCP_BAIDU_NETDISK_API_KEY=two\n' > "$H4/.env"
OUT="$(run "$H4/.env" 2>&1)"
is_ok "$OUT"; ck "ok:true" $? "$OUT"
[ "$(grep -c '^MCP_BAIDU_NETDISK_API_KEY=' "$H4/.env")" = 1 ]; ck "one key line left" $?
[ "$(grep -c '^X=1$' "$H4/.env")" = 1 ]; ck "X=1 kept" $?

echo "5. a wrong expected digest is reported, not swallowed"
OUT="$(PATH="$T/bin:$PATH" MCP_TOKEN="$TOKEN" BDPANW_TOKEN_SHA256="deadbeef" bash "$S" "$H2/.env" 2>&1)"
case "$OUT" in *'"ok":false'*) c=0;; *) c=1;; esac
ck "ok:false with a message" $c "$OUT"

echo "6. a directory with no config.yaml is refused"
OUT="$(MCP_TOKEN="$TOKEN" BDPANW_TOKEN_SHA256="$SHA" bash "$S" "$T/nope/.env" 2>&1)"; rc=$?
[ "$rc" = 1 ]; ck "exit 1 with ok:false" $? "rc=$rc $OUT"

echo; echo "passed=$((16 - fail)) failed=$fail"; [ "$fail" = 0 ]
