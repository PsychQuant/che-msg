#!/bin/bash
# Startup behaviour of che-telegram-all-mcp-wrapper.sh as Claude Code sees it
# (#31, PsychQuant/che-msg#58).
#
# Runs the real wrapper against a private HOME (tests/lib/wrapper_harness.sh).
# Another session never stops the wrapper. It stops before starting the
# server only for missing Keychain credentials, a missing binary, or a binary
# older than 0.6.0, and then answers the pending initialize request with a
# JSON-RPC 2.0 error, because Claude Code otherwise shows only a generic -32000.
#
# Tests:
#   1. Another session's legacy wrapper lock (~/.cache/che-telegram-all-mcp.lock
#      with owner.pid naming a live process) does not stop the wrapper: the
#      binary starts, the wrapper writes nothing to stdout, and the lock is
#      left as it was.
#   2. Missing credentials: the wrapper exits 1 without starting the binary,
#      and stdout's first line is a JSON-RPC error with the request's numeric
#      id, code -32000, a message, and data.docsUrl pointing at the README
#      section "When telegram-all does not start".
#   3. The same with a string request id.
#   4. Missing binary: with nothing installed and the download failing, the
#      wrapper answers the same way (exit 1, the error with data.docsUrl, no
#      binary started) after trying the download through the fake curl.
#   5. A binary older than 0.6.0 (it opens TDLib without the server-side
#      lock): when the download of the pinned version fails and only a 0.5.0
#      binary is installed, the wrapper refuses to run it and answers with the
#      same error; nothing is started as a server.
#   6. A binary that does not answer --version (as binaries before 0.6.0 do)
#      is refused the same way.
#   7. No other test reached the network: only cases 4 and 5 called the fake curl.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-mcp-error.sh
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

DOCS_URL="https://github.com/PsychQuant/che-msg/blob/main/plugins/che-telegram-mcp/README.md#when-telegram-all-does-not-start"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-error-XXXXXX")
STARTED=()
finish() {
    for pid in "${STARTED[@]}"; do kill -KILL "$pid" 2>/dev/null; done
    for pids in "$SCRATCH"/*/started.pids; do
        [ -f "$pids" ] && while read -r pid; do kill -KILL "$pid" 2>/dev/null; done < "$pids"
    done
    rm -rf "$SCRATCH"
}
trap finish EXIT

# ----------------------------------------------------------------------
test_case "Another session's legacy wrapper lock does not stop the wrapper"
H="$SCRATCH/legacy"; make_home "$H"
mkdir -p "$H/.cache/che-telegram-all-mcp.lock"
/bin/sleep 300 &
OWNER=$!; STARTED+=("$OWNER")
echo "$OWNER" > "$H/.cache/che-telegram-all-mcp.lock/owner.pid"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' > "$H/in"
W=$(start_wrapper "$H" "$H/in" "$H/out"); STARTED+=("$W")
if wait_until 5 has_pids "$H" 1; then pass "binary started"; else fail "binary did not start"; fi
sleep 1
if [ ! -s "$H/out" ]; then pass "wrapper wrote nothing to stdout"; else fail "wrapper wrote to stdout: $(head -c 200 "$H/out")"; fi
stop "$W"
if [ "$(cat "$H/.cache/che-telegram-all-mcp.lock/owner.pid" 2>/dev/null)" = "$OWNER" ]; then
    pass "legacy lock left as it was"
else
    fail "legacy lock was changed or removed"
fi

# check_error <home> <expected id as jq literal>
check_error() {
    local home=$1 id=$2 line
    line=$(head -1 "$home/out")
    if printf '%s' "$line" | jq -e --argjson id "$id" --arg url "$DOCS_URL" '
        .jsonrpc == "2.0" and .id == $id and .error.code == -32000
        and (.error.message | type == "string" and length > 20)
        and .error.data.docsUrl == $url' >/dev/null 2>&1; then
        pass "stdout answers the initialize request with the error"
    else
        fail "stdout is not the expected JSON-RPC error: ${line:0:300}"
    fi
    if [ ! -e "$home/started.pids" ]; then pass "no binary started"; else fail "a binary was started"; fi
}

# ----------------------------------------------------------------------
test_case "Missing credentials answer the initialize request (numeric id)"
H="$SCRATCH/nocreds"; make_home "$H" no
printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}' > "$H/in"
HOME="$H" PATH="$H/fakebin:$PATH" bash "$WRAPPER" < "$H/in" > "$H/out" 2> "$H/err"
RC=$?
if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
check_error "$H" 7

# ----------------------------------------------------------------------
test_case "Missing credentials answer the initialize request (string id)"
H="$SCRATCH/nocreds-string"; make_home "$H" no
printf '%s\n' '{"jsonrpc":"2.0","id":"abc","method":"initialize","params":{}}' > "$H/in"
HOME="$H" PATH="$H/fakebin:$PATH" bash "$WRAPPER" < "$H/in" > "$H/out" 2> "$H/err"
check_error "$H" '"abc"'

# ----------------------------------------------------------------------
test_case "Missing binary answers the initialize request"
H="$SCRATCH/nobinary"; make_home "$H"
rm -f "$H/bin/CheTelegramAllMCP" "$H/bin/.CheTelegramAllMCP.version"
printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"initialize","params":{}}' > "$H/in"
HOME="$H" PATH="$H/fakebin:$PATH" bash "$WRAPPER" < "$H/in" > "$H/out" 2> "$H/err"
RC=$?
if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
check_error "$H" 9
if [ -s "$H/curl.calls" ]; then pass "the download was attempted (fake curl)"; else fail "no download attempt"; fi

# ----------------------------------------------------------------------
test_case "An installed binary older than 0.6.0 is not run when the upgrade fails"
H="$SCRATCH/oldbinary"; make_home "$H" yes 0.5.0
printf '%s\n' '{"jsonrpc":"2.0","id":11,"method":"initialize","params":{}}' > "$H/in"
HOME="$H" PATH="$H/fakebin:$PATH" bash "$WRAPPER" < "$H/in" > "$H/out" 2> "$H/err"
RC=$?
if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
check_error "$H" 11
if [ -s "$H/curl.calls" ]; then pass "the upgrade was attempted (fake curl)"; else fail "no upgrade attempt"; fi

# ----------------------------------------------------------------------
test_case "A binary that does not report its version is not run"
H="$SCRATCH/silent"; make_home "$H" yes silent
printf '%s\n' '{"jsonrpc":"2.0","id":12,"method":"initialize","params":{}}' > "$H/in"
HOME="$H" PATH="$H/fakebin:$PATH" bash "$WRAPPER" < "$H/in" > "$H/out" 2> "$H/err"
RC=$?
if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
# A binary that does not know --version starts as a server when asked for its
# version, as real binaries before 0.6.0 do. That probe gets no stdin and no
# credentials and is stopped; what matters is that the binary never received
# the client's initialize request and is not left running.
mv "$H/started.pids" "$H/probe.pids" 2>/dev/null
check_error "$H" 12
if [ ! -e "$H/stdin.txt" ]; then pass "the binary never received the initialize request"; else fail "the binary received the client's stdin"; fi
probe=$(head -1 "$H/probe.pids" 2>/dev/null)
if [ -z "$probe" ] || ! alive "$probe"; then pass "the version probe is not left running"; else fail "the version probe $probe is still running"; fi

# ----------------------------------------------------------------------
test_case "No other test reached the network"
others=$(ls "$SCRATCH"/*/curl.calls 2>/dev/null | grep -v -e '/nobinary/' -e '/oldbinary/' || true)
if [ -z "$others" ]; then pass "curl called only by the download cases"; else fail "curl was called: $others"; fi

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
