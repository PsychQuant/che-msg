#!/bin/bash
# What the che-telegram-mcp wrappers answer when the client's first message
# is not initialize (PsychQuant/che-msg#59).
#
# Claude Code builds from 2026-10 may send a server/discover request before
# initialize. When a wrapper stops before starting its server, its startup
# error (JSON-RPC -32000 with data.docsUrl) answers only initialize; a first
# request for another method gets "method not found" (-32601) for its own id
# from lib/startup-error.sh, and the wrapper exits 1 as it does after the
# startup error. Before #59 the wrapper answered the probe with the startup
# error. A first request the wrapper does not have to answer, because it
# starts the server, reaches the server untouched.
#
# Runs the real wrappers against private HOMEs (tests/lib/wrapper_harness.sh);
# the fake curl serves nothing but a slow asset, and nothing reaches the
# network.
#
# Tests:
#   For telegram-all, with server/discover as the first request:
#   1. Missing credentials, numeric id: the only line on stdout is a JSON-RPC
#      error with that id and code -32601, there is no -32000 answer, the
#      wrapper exits 1, no binary is started, and stderr names the cause.
#   2. The same with a string id.
#   3. A notification for another method first: nothing on stdout, exit 1.
#   4. Nothing installed and the download failing: -32601 as in 1.
#   5. Nothing installed and the download still running when the wait ends
#      (the first-install answer): -32601 as in 1.
#   6. Only a 0.6.0 binary and the download failing: -32601 as in 1.
#   7. A binary it runs and credentials present: the binary is started and
#      receives the request as its first line; the wrapper writes nothing.
#   For telegram-bot, with server/discover as the first request:
#   8. Nothing installed and the download failing: -32601 as in 1.
#   9. Nothing installed and the download still running: -32601 as in 1.
#   lib/startup-error.sh's read_first_request, sourced on its own:
#  10. With jq: an initialize request sets REQUEST_ID and writes nothing; a
#      request for another method is answered with -32601 and exit 1; a
#      method that is not a string, a line that is not JSON and empty stdin
#      leave the startup error to the caller (REQUEST_ID null or the id).
#  11. Without jq on PATH: the same for an initialize request and a request
#      for another method, with a numeric and a string id.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-first-request.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/wrapper_harness.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for these tests. Install via 'brew install jq'." >&2
    exit 1
fi

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

LIB="$HARNESS_ROOT/plugins/che-telegram-mcp/lib/startup-error.sh"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-first-request-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
STARTED=()
finish() {
    for pid in "${STARTED[@]+"${STARTED[@]}"}"; do kill -KILL "$pid" 2>/dev/null; done
    for pids in "$SCRATCH"/*/started.pids "$SCRATCH"/*/curl.pids; do
        [ -f "$pids" ] && while read -r pid; do kill -KILL "$pid" 2>/dev/null; done < "$pids"
    done
    # A first-install case leaves its download running in a session of its own.
    pkill -KILL -f -- "$SCRATCH" 2>/dev/null
    rm -rf "$SCRATCH"
}
trap finish EXIT

probe() { printf '{"jsonrpc":"2.0","id":%s,"method":"server/discover","params":{}}' "$1"; }
SLOW=8   # seconds the fake asset takes, longer than the wait below

# run <home> <wrapper> <first line> [install wait]: runs the wrapper to its
# end with that line on stdin; sets RC.
run() {
    local home=$1 wrapper=$2 line=$3 wait=${4:-}
    printf '%s\n' "$line" > "$home/in"
    if [ -n "$wait" ]; then
        HOME="$home" PATH="$home/fakebin:$PATH" CHE_TELEGRAM_MCP_INSTALL_WAIT=$wait /bin/bash "$wrapper" < "$home/in" > "$home/out" 2> "$home/err"
    else
        HOME="$home" PATH="$home/fakebin:$PATH" /bin/bash "$wrapper" < "$home/in" > "$home/out" 2> "$home/err"
    fi
    RC=$?
}

# check_method_not_found <home> <id as jq literal> <stderr substring>
check_method_not_found() {
    local home=$1 id=$2 cause=$3 lines
    if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
    lines=$(wc -l < "$home/out" | tr -d ' ')
    if [ "$lines" -eq 1 ] && head -1 "$home/out" | jq -e --argjson id "$id" '
        .jsonrpc == "2.0" and .id == $id and .error.code == -32601
        and (.error.message | type == "string")' >/dev/null 2>&1; then
        pass "the only answer is -32601 for the request's id $id"
    else
        fail "stdout is not one -32601 answer for id $id: $(head -c 300 "$home/out")"
    fi
    if ! grep -q -- '-32000' "$home/out"; then pass "the request is not answered with the startup error"; else fail "the startup error (-32000) answered the request"; fi
    if [ ! -e "$home/started.pids" ]; then pass "no binary started"; else fail "a binary was started"; fi
    if grep -q -- "$cause" "$home/err"; then pass "stderr says: $cause"; else fail "stderr lacks '$cause': $(tail -3 "$home/err" | tr '\n' ' ')"; fi
}

# ----------------------------------------------------------------------
test_case "telegram-all, missing credentials: server/discover with a numeric id"
H="$SCRATCH/all-nocreds"; make_home "$H" no
run "$H" "$WRAPPER" "$(probe 1)"
check_method_not_found "$H" 1 "credentials not found in Keychain"

# ----------------------------------------------------------------------
test_case "telegram-all, missing credentials: server/discover with a string id"
H="$SCRATCH/all-nocreds-string"; make_home "$H" no
run "$H" "$WRAPPER" "$(probe '"probe-1"')"
check_method_not_found "$H" '"probe-1"' "credentials not found in Keychain"

# ----------------------------------------------------------------------
test_case "telegram-all, missing credentials: a notification first gets no answer"
H="$SCRATCH/all-notification"; make_home "$H" no
run "$H" "$WRAPPER" '{"jsonrpc":"2.0","method":"notifications/initialized"}'
if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
if [ ! -s "$H/out" ]; then pass "nothing on stdout"; else fail "stdout: $(head -c 300 "$H/out")"; fi

# ----------------------------------------------------------------------
test_case "telegram-all, nothing installed and the download failing"
H="$SCRATCH/all-nobinary"; make_home "$H"
rm -f "$H/bin/CheTelegramAllMCP" "$H/bin/.CheTelegramAllMCP.version"
run "$H" "$WRAPPER" "$(probe 2)"
check_method_not_found "$H" 2 "not installed"
if [ -s "$H/curl.calls" ]; then pass "the download was attempted (fake curl)"; else fail "no download attempt"; fi

# ----------------------------------------------------------------------
test_case "telegram-all, nothing installed and the download still running"
H="$SCRATCH/all-downloading"; make_home "$H"
rm -f "$H/bin/CheTelegramAllMCP" "$H/bin/.CheTelegramAllMCP.version"
echo "a slow asset" > "$H/asset"; serve_asset "$H" "$H/asset"; echo "$SLOW" > "$H/fake-curl/asset.delay"
run "$H" "$WRAPPER" "$(probe 3)" 1
check_method_not_found "$H" 3 "not installed yet"

# ----------------------------------------------------------------------
test_case "telegram-all, only a 0.6.0 binary and the download failing"
H="$SCRATCH/all-binary060"; make_home "$H" yes 0.6.0
run "$H" "$WRAPPER" "$(probe 4)"
# The version probe starts nothing as a server: a 0.6.0 fake answers --version.
check_method_not_found "$H" 4 "needs 0.7.0 or later"

# ----------------------------------------------------------------------
test_case "telegram-all, a binary it runs: the request reaches the server untouched"
H="$SCRATCH/all-starts"; make_home "$H"
printf '%s\n' "$(probe 5)" > "$H/in"
W=$(start_wrapper "$H" "$H/in" "$H/out"); STARTED+=("$W")
if wait_until 5 has_pids "$H" 1 && wait_until 5 test -s "$H/stdin.txt"; then pass "binary started"; else fail "binary did not start or read nothing"; fi
if [ "$(cat "$H/stdin.txt" 2>/dev/null)" = "$(probe 5)" ]; then pass "the binary's first line is the request"; else fail "the binary read: $(head -c 200 "$H/stdin.txt" 2>/dev/null)"; fi
if [ ! -s "$H/out" ]; then pass "the wrapper wrote nothing to stdout"; else fail "the wrapper wrote: $(head -c 200 "$H/out")"; fi
stop "$W"

# ----------------------------------------------------------------------
test_case "telegram-bot, nothing installed and the download failing"
H="$SCRATCH/bot-nobinary"; make_bot_home "$H" -; rm -f "$H/bin/CheTelegramBotMCP"
run "$H" "$BOT_WRAPPER" "$(probe 6)"
check_method_not_found "$H" 6 "not installed"

# ----------------------------------------------------------------------
test_case "telegram-bot, nothing installed and the download still running"
H="$SCRATCH/bot-downloading"; make_bot_home "$H" -; rm -f "$H/bin/CheTelegramBotMCP"
echo "a slow asset" > "$H/asset"; serve_asset "$H" "$H/asset"; echo "$SLOW" > "$H/fake-curl/asset.delay"
run "$H" "$BOT_WRAPPER" "$(probe '"bot-7"')" 1
check_method_not_found "$H" '"bot-7"' "not installed yet"

# ----------------------------------------------------------------------
# reader <PATH> <first line>: runs read_first_request from the lib on its own
# with that line (none if empty) on stdin and that PATH; prints
# "<exit status>|<stdout>", where stdout ends with <id=REQUEST_ID> unless the
# reader exited.
reader() {
    local path=$1 line=$2 out rc
    out=$( { [ -n "$line" ] && printf '%s\n' "$line"; } | env PATH="$path" /bin/bash -c '
        source "$1" || exit 99
        read_first_request
        printf "<id=%s>" "$REQUEST_ID"' _ "$LIB")
    rc=$?
    printf '%s|%s' "$rc" "$out"
}
expect_reader() {   # <label> <path> <first line> <expected>
    local got; got=$(reader "$2" "$3")
    if [ "$got" = "$4" ]; then pass "$1"; else fail "$1: got '$got', expected '$4'"; fi
}
M601='{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}'

test_case "read_first_request with jq"
expect_reader "initialize, numeric id: REQUEST_ID set, nothing written" "$PATH" \
    '{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}' '0|<id=7>'
expect_reader "initialize, string id" "$PATH" \
    '{"jsonrpc":"2.0","id":"abc","method":"initialize"}' '0|<id="abc">'
expect_reader "server/discover is answered with -32601 and exit 1" "$PATH" \
    "$(probe 8)" "1|$(printf "$M601" 8)"
expect_reader "a method that is not a string is left to the startup error" "$PATH" \
    '{"jsonrpc":"2.0","id":9,"method":5}' '0|<id=9>'
expect_reader "a line that is not JSON: id null" "$PATH" 'not json' '0|<id=null>'
expect_reader "empty stdin: id null" "$PATH" '' '0|<id=null>'

test_case "read_first_request without jq"
NOJQ="$SCRATCH/no-jq-path"; mkdir -p "$NOJQ"
if env PATH="$NOJQ" /bin/bash -c 'command -v jq' >/dev/null 2>&1; then fail "jq is still on the test PATH"; else pass "jq is not on the test PATH"; fi
expect_reader "initialize, numeric id" "$NOJQ" \
    '{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}' '0|<id=7>'
expect_reader "initialize, string id" "$NOJQ" \
    '{"jsonrpc":"2.0","id":"abc","method":"initialize"}' '0|<id="abc">'
expect_reader "server/discover, numeric id: -32601 and exit 1" "$NOJQ" \
    "$(probe 10)" "1|$(printf "$M601" 10)"
expect_reader "server/discover, string id: -32601 and exit 1" "$NOJQ" \
    "$(probe '"p"')" "1|$(printf "$M601" '"p"')"

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
