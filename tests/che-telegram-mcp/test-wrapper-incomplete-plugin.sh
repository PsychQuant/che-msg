#!/bin/bash
# What the che-telegram-mcp wrappers do when the plugin's lib/ files cannot be
# read (PsychQuant/che-msg#59).
#
# Both wrappers source lib/startup-error.sh and lib/download.sh before
# anything else. When either cannot be read, the wrapper stops before starting
# its server: it writes the reason to stderr and answers with its startup
# error (-32000), whose message says the plugin is incomplete. How it answers
# depends on which file is missing:
#   - lib/download.sh: the first request is answered as in the other refusals
#     (initialize with -32000 for its id, any other request with -32601);
#   - lib/startup-error.sh, the reader itself: the wrapper does not read stdin,
#     so the -32000 error carries id null whatever the first message is.
#
# Runs copies of the real wrappers next to a copy of the plugin's lib/
# (tests/lib/wrapper_harness.sh, wrapper_copy), from which a file is removed
# or made unreadable; the originals are never touched. Each HOME has a binary
# to run and credentials, so the lib/ files are the only reason to stop.
#
# Tests, for each wrapper:
#   1. lib/download.sh missing, initialize first: exit 1, one -32000 error for
#      the request's id with the wrapper's data.docsUrl and a message saying the
#      plugin is incomplete, the reason on stderr, no binary started.
#   2. lib/download.sh missing, server/discover first: one -32601 answer for
#      its id and no -32000 error.
#   3. lib/startup-error.sh missing, initialize first: the -32000 error as in
#      1, but with id null.
#   4. lib/startup-error.sh missing, server/discover first: the same -32000
#      error with id null; no -32601 answer.
#   And for telegram-all:
#   5. lib/startup-error.sh present but unreadable: as in 3.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-incomplete-plugin.sh
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

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-incomplete-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
finish() {
    for pids in "$SCRATCH"/*/started.pids; do
        [ -f "$pids" ] && while read -r pid; do kill -KILL "$pid" 2>/dev/null; done < "$pids"
    done
    chmod -R u+rwX "$SCRATCH" 2>/dev/null
    rm -rf "$SCRATCH"
}
trap finish EXIT

README_URL="https://github.com/PsychQuant/che-msg/blob/main/plugins/che-telegram-mcp/README.md"
INITIALIZE='{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}'
PROBE='{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}'

# setup <name> <all|bot> <lib file> <missing|unreadable>: a HOME with a binary
# to run and credentials, and a copy of the wrapper whose lib/<file> is gone or
# unreadable; sets H and COPY.
setup() {
    local name=$1 which=$2 file=$3 how=$4
    H="$SCRATCH/$name"
    if [ "$which" = all ]; then
        make_home "$H"
        COPY=$(wrapper_copy "$WRAPPER" "$SCRATCH/$name-plugin")
    else
        make_bot_home "$H" "$BOT_DESIRED"
        COPY=$(wrapper_copy "$BOT_WRAPPER" "$SCRATCH/$name-plugin")
    fi
    if [ "$how" = missing ]; then rm -f "$SCRATCH/$name-plugin/lib/$file"
    else chmod 000 "$SCRATCH/$name-plugin/lib/$file"; fi
}

# run <first line>: runs COPY in H with that line on stdin; sets RC.
run() {
    printf '%s\n' "$1" > "$H/in"
    HOME="$H" PATH="$H/fakebin:$PATH" /bin/bash "$COPY" < "$H/in" > "$H/out" 2> "$H/err"
    RC=$?
}

# check_incomplete <all|bot> <id as jq literal>: the -32000 startup error for
# an incomplete plugin, and nothing else, on stdout.
check_incomplete() {
    local which=$1 id=$2 url lines
    if [ "$which" = all ]; then url="$README_URL#when-telegram-all-does-not-start"
    else url="$README_URL#when-telegram-bot-does-not-start"; fi
    if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
    lines=$(wc -l < "$H/out" | tr -d ' ')
    if [ "$lines" -eq 1 ] && head -1 "$H/out" | jq -e --argjson id "$id" --arg url "$url" '
        .jsonrpc == "2.0" and .id == $id and .error.code == -32000
        and .error.data.docsUrl == $url
        and (.error.message | contains("plugin is incomplete"))' >/dev/null 2>&1; then
        pass "the only answer is the incomplete-plugin error (-32000) with id $id"
    else
        fail "stdout is not one incomplete-plugin error with id $id: $(head -c 300 "$H/out")"
    fi
    check_stopped
}
check_stopped() {
    if [ ! -e "$H/started.pids" ]; then pass "no binary started"; else fail "a binary was started"; fi
    if grep -q "lib/ files cannot be read" "$H/err"; then pass "stderr says the lib/ files cannot be read"; else fail "stderr: $(tail -3 "$H/err" | tr '\n' ' ')"; fi
}

for which in all bot; do
    # ------------------------------------------------------------------
    test_case "$which: lib/download.sh missing, initialize first"
    setup "$which-nodownload-init" "$which" download.sh missing
    run "$INITIALIZE"
    check_incomplete "$which" 7

    # ------------------------------------------------------------------
    test_case "$which: lib/download.sh missing, server/discover first"
    setup "$which-nodownload-probe" "$which" download.sh missing
    run "$PROBE"
    if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
    if [ "$(wc -l < "$H/out" | tr -d ' ')" -eq 1 ] && head -1 "$H/out" | jq -e '.id == 1 and .error.code == -32601' >/dev/null 2>&1; then
        pass "the only answer is -32601 for id 1"
    else
        fail "stdout is not one -32601 answer for id 1: $(head -c 300 "$H/out")"
    fi
    check_stopped

    # ------------------------------------------------------------------
    test_case "$which: lib/startup-error.sh missing, initialize first (id null)"
    setup "$which-noreader-init" "$which" startup-error.sh missing
    run "$INITIALIZE"
    check_incomplete "$which" null

    # ------------------------------------------------------------------
    test_case "$which: lib/startup-error.sh missing, server/discover first (id null, no -32601)"
    setup "$which-noreader-probe" "$which" startup-error.sh missing
    run "$PROBE"
    check_incomplete "$which" null
done

# ----------------------------------------------------------------------
test_case "all: lib/startup-error.sh unreadable, initialize first (id null)"
setup "all-unreadable" all startup-error.sh unreadable
if [ -r "$SCRATCH/all-unreadable-plugin/lib/startup-error.sh" ]; then
    pass "skipped: this user can read a mode-000 file"
else
    run "$INITIALIZE"
    check_incomplete all null
fi

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
