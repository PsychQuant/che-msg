#!/bin/bash
# Process handling of che-telegram-all-mcp-wrapper.sh (#8, PsychQuant/che-msg#58).
#
# Runs the real wrapper against a private HOME (tests/lib/wrapper_harness.sh).
# Several Claude Code sessions may each run the server; the server decides
# which of them opens TDLib, so the wrapper takes no lock, keeps no shared PID
# file, and signals only the binary it started itself.
#
# Tests:
#   1. The wrapper passes its stdin to the binary (MCP stdio; POSIX makes a
#      backgrounded command read /dev/null unless told otherwise).
#   2. A second wrapper starts its own binary while the first one's runs, and
#      the first binary is still running afterwards.
#   3. A wrapper that exits terminates its own binary and leaves the other.
#   4. A live process named CheTelegramAllMCP listed in the old shared PID
#      file ~/.cache/che-telegram-all-mcp.pid is left alone, and the wrapper
#      neither rewrites nor removes that file.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-pid.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/wrapper_harness.sh"

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }
gone() { ! alive "$1"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-pid-XXXXXX")
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
test_case "Wrapper passes its stdin to the binary"
H="$SCRATCH/stdin"; make_home "$H"
printf 'hello-mcp\n' > "$H/in"
W=$(start_wrapper "$H" "$H/in" "$H/out"); STARTED+=("$W")
if wait_until 5 test -s "$H/stdin.txt" && [ "$(cat "$H/stdin.txt")" = "hello-mcp" ]; then
    pass "binary read the wrapper's stdin"
else
    fail "binary did not receive the wrapper's stdin"
fi
stop "$W"

# ----------------------------------------------------------------------
test_case "A second wrapper starts its own binary and leaves the first running"
H="$SCRATCH/two"; make_home "$H"; : > "$H/in"
W1=$(start_wrapper "$H" "$H/in" "$H/out1"); STARTED+=("$W1")
wait_until 5 has_pids "$H" 1 || fail "first binary did not start"
B1=$(nth_pid "$H" 1)
W2=$(start_wrapper "$H" "$H/in" "$H/out2"); STARTED+=("$W2")
if wait_until 5 has_pids "$H" 2; then
    pass "second binary started"
else
    fail "second wrapper did not start a binary"
fi
B2=$(nth_pid "$H" 2)
sleep 2.5   # longer than any SIGTERM-then-wait an old wrapper would do
if [ -n "$B1" ] && alive "$B1"; then pass "first binary still running"; else fail "first binary was stopped"; fi
if [ ! -e "$H/.cache/che-telegram-all-mcp.lock" ] && [ ! -e "$H/.cache/che-telegram-all-mcp.lock.flock" ]; then
    pass "no wrapper lock created"
else
    fail "a wrapper lock was created"
fi
if [ ! -e "$H/.cache/che-telegram-all-mcp.pid" ]; then pass "no shared PID file written"; else fail "shared PID file written"; fi

# ----------------------------------------------------------------------
test_case "A wrapper that exits terminates only its own binary"
stop "$W1"
if [ -n "$B1" ] && wait_until 5 gone "$B1"; then pass "first wrapper's binary terminated"; else fail "first wrapper's binary still running"; fi
if [ -n "$B2" ] && alive "$B2"; then pass "second wrapper's binary still running"; else fail "second wrapper's binary was stopped"; fi
stop "$W2"
if [ -n "$B2" ] && wait_until 5 gone "$B2"; then pass "second wrapper's binary terminated"; else fail "second wrapper's binary still running"; fi

# ----------------------------------------------------------------------
test_case "A live CheTelegramAllMCP in the old shared PID file is left alone"
H="$SCRATCH/decoy"; make_home "$H"; : > "$H/in"
mkdir -p "$H/decoy" "$H/.cache"
cp /bin/sleep "$H/decoy/CheTelegramAllMCP"
# A copied system binary is killed at launch unless it is signed again.
codesign --force -s - "$H/decoy/CheTelegramAllMCP" 2>/dev/null
"$H/decoy/CheTelegramAllMCP" 300 &
DECOY=$!; STARTED+=("$DECOY")
wait_until 2 alive "$DECOY" && sleep 0.3
alive "$DECOY" || fail "decoy did not start, so this case cannot tell anything"
echo "$DECOY" > "$H/.cache/che-telegram-all-mcp.pid"
W=$(start_wrapper "$H" "$H/in" "$H/out"); STARTED+=("$W")
wait_until 5 has_pids "$H" 1 || fail "binary did not start"
sleep 2.5
if alive "$DECOY"; then pass "process in the old PID file still running"; else fail "process in the old PID file was killed"; fi
if [ "$(cat "$H/.cache/che-telegram-all-mcp.pid" 2>/dev/null)" = "$DECOY" ]; then
    pass "old PID file unchanged"
else
    fail "old PID file was rewritten or removed"
fi
stop "$W"
if alive "$DECOY"; then pass "still running after the wrapper exited"; else fail "killed when the wrapper exited"; fi
if [ "$(cat "$H/.cache/che-telegram-all-mcp.pid" 2>/dev/null)" = "$DECOY" ]; then
    pass "old PID file unchanged after exit"
else
    fail "old PID file changed on exit"
fi

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
