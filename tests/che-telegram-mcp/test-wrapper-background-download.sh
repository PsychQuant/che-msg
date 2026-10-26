#!/bin/bash
# The che-telegram-mcp wrappers download in the background, off the startup
# path (PsychQuant/che-msg#67).
#
# Claude Code waits 30 s for an MCP server to answer initialize; the 238 MB
# telegram-all binary takes minutes on a slow link. Before #67 the wrapper
# downloaded before starting anything, so the start timed out, the wrapper was
# stopped before its mv, and the next start began again. Now:
#   - with a usable binary installed (telegram-all: 0.7.0 or later), the
#     wrapper hands over to it at once and the download goes on; the new
#     version is used from the next start;
#   - with none, it waits a few seconds for the download, then answers
#     initialize with an error that says the download goes on in the
#     background (telegram-bot, which has no such error yet, says it on stderr
#     and exits 1); the download goes on after the wrapper exits;
#   - a complete partial file whose sha256 matches is installed without
#     downloading again.
# Acceptance (the #67 Diagnosis, open question 3): the wrapper answers
# initialize, or hands over to the installed binary, within 5 seconds.
#
# Runs copies of both wrappers, pinned to the fake assets' sha256, with
# /bin/bash against private HOMEs (tests/lib/wrapper_harness.sh). The fake
# curl serves the fake assets after a delay; nothing reaches the network. Each wrapper runs in
# a process group of its own and is stopped by signalling the whole group, as
# a client that ends a server's process group would; the download must not be
# part of it.
#
# Tests, for each wrapper:
#   1. A usable binary installed and a slow download: the installed binary is
#      started within 5 s, before the download finishes; after the wrapper's
#      process group is stopped the download completes and installs the asset
#      with its version record.
#   2. Nothing installed and a slow download: the start ends within 5 s
#      (telegram-all with a JSON-RPC error answering initialize), saying the
#      download continues in the background; after the wrapper's group is
#      stopped the download completes and installs the asset.
#   3. A complete partial file of the pinned version whose sha256 matches:
#      installed without downloading the asset again.
#   4. The download writes what it did to its log,
#      ~/bin/.che-telegram-mcp-download/<Binary>.log.
#   5. With CHE_TELEGRAM_MCP_INSTALL_WAIT longer than the download, a first
#      install finishes within the wait and the new binary is started.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-background-download.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/wrapper_harness.sh"
# The harness lets wrappers wait longer for a first download; this test checks
# the wrappers' own default, except where case 5 sets it.
unset CHE_TELEGRAM_MCP_INSTALL_WAIT

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for these tests. Install via 'brew install jq'." >&2
    exit 1
fi

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-background-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
GROUPS_STARTED=()
finish() {
    for g in "${GROUPS_STARTED[@]+"${GROUPS_STARTED[@]}"}"; do kill -KILL -- "-$g" 2>/dev/null; done
    for pids in "$SCRATCH"/*/started.pids "$SCRATCH"/*/curl.pids; do
        [ -f "$pids" ] && while read -r pid; do kill -KILL "$pid" 2>/dev/null; done < "$pids"
    done
    pkill -KILL -f -- "$SCRATCH" 2>/dev/null
    rm -rf "$SCRATCH"
}
trap finish EXIT

ALL=CheTelegramAllMCP
BOT=CheTelegramBotMCP
MIN_ALL=0.7.0
OLDER=0.0.1
LIMIT=5          # seconds: the acceptance for answering or handing over
SLOW=8           # seconds the fake asset download takes

ASSETS="$SCRATCH/assets"; mkdir -p "$ASSETS"
write_fake_all_binary "$ASSETS/$ALL" "$DESIRED_VERSION"
write_fake_bot_binary "$ASSETS/$BOT"
echo '# the release asset' >> "$ASSETS/$ALL"; echo '# the release asset' >> "$ASSETS/$BOT"

# The real wrappers pin the real release's sha256; these copies pin the fake
# assets' (tests/lib/wrapper_harness.sh, pinned_wrapper_copy).
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
WRAPPER=$(pinned_wrapper_copy "$WRAPPER" "$SCRATCH/all-plugin" "$DESIRED_VERSION" "$(sha "$ASSETS/$ALL")") || exit 1
BOT_WRAPPER=$(pinned_wrapper_copy "$BOT_WRAPPER" "$SCRATCH/bot-plugin" "$BOT_DESIRED" "$(sha "$ASSETS/$BOT")") || exit 1

asset_name() { if [ "$1" = all ]; then echo "$ALL"; else echo "$BOT"; fi; }
wrapper_of() { if [ "$1" = all ]; then echo "$WRAPPER"; else echo "$BOT_WRAPPER"; fi; }
pin_of() { if [ "$1" = all ]; then echo "$DESIRED_VERSION"; else echo "$BOT_DESIRED"; fi; }
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
elapsed_since() { perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$1" "$(now)"; }
within() { perl -e 'exit !($ARGV[0] <= $ARGV[1])' "$1" "$2"; }

empty_home() {
    if [ "$2" = all ]; then make_home "$1"; rm -f "$1/bin/$ALL" "$1/bin/.$ALL.version"
    else make_bot_home "$1" -; rm -f "$1/bin/$BOT"; fi
}
serve() {
    local name; name=$(asset_name "$2")
    serve_release_api "$1" "$name" "$ASSETS/$name"
    serve_asset "$1" "$ASSETS/$name"
}

# launch <home> <all|bot>: starts the wrapper in a process group of its own
# and waits until it has started a binary or exited; sets W (its PID and
# group), T (seconds until then) and RC ("started", the exit status, or
# "timeout").
launch() {
    local home=$1 t0
    rm -f "$home/started.pids" "$home/out" "$home/err"
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"initialize","params":{}}' > "$home/in"
    t0=$(now)
    set -m
    HOME="$home" PATH="$home/fakebin:$PATH" /bin/bash "$(wrapper_of "$2")" < "$home/in" > "$home/out" 2> "$home/err" &
    W=$!
    set +m
    GROUPS_STARTED+=("$W")
    if wait_until 30 bash -c "[ -s '$home/started.pids' ] || ! kill -0 $W 2>/dev/null"; then
        T=$(elapsed_since "$t0")
        if [ -s "$home/started.pids" ]; then RC=started; else wait "$W" 2>/dev/null; RC=$?; fi
    else
        T=$(elapsed_since "$t0"); RC=timeout
    fi
}
# stop_group <pid>: TERM to the wrapper's whole process group, then KILL.
stop_group() {
    kill -TERM -- "-$1" 2>/dev/null
    wait_until 4 bash -c "! kill -0 -- -$1 2>/dev/null" || kill -KILL -- "-$1" 2>/dev/null
    wait "$1" 2>/dev/null
}

expect_installed() {   # <home> <name> <version>
    if cmp -s "$1/bin/$2" "$ASSETS/$2"; then pass "~/bin/$2 is now the release asset"; else fail "~/bin/$2 is not the release asset"; fi
    if [ "$(cat "$1/bin/.$2.version" 2>/dev/null)" = "$3" ]; then pass "version record says $3"; else fail "version record: '$(cat "$1/bin/.$2.version" 2>/dev/null)'"; fi
}
reason() {
    if [ "$2" = all ]; then head -1 "$1/out" | jq -r '.error.message' 2>/dev/null
    else cat "$1/err"; fi
}

for which in all bot; do
    NAME=$(asset_name "$which"); PIN=$(pin_of "$which")

    # ------------------------------------------- 1. hand over, download on
    test_case "$which: a usable binary is started at once while the download goes on"
    H="$SCRATCH/$which-handover"
    if [ "$which" = all ]; then make_home "$H" yes "$MIN_ALL"; else make_bot_home "$H" "$OLDER"; fi
    cp "$H/bin/$NAME" "$SCRATCH/old-$which"
    serve "$H" "$which"; echo "$SLOW" > "$H/fake-curl/asset.delay"
    launch "$H" "$which"
    if [ "$RC" = started ] && within "$T" "$LIMIT"; then pass "the installed binary started after ${T}s (limit ${LIMIT}s)"
    else fail "after ${T}s: $RC (limit ${LIMIT}s): $(tail -3 "$H/err" | tr '\n' ' ')"; fi
    if cmp -s "$H/bin/$NAME" "$SCRATCH/old-$which"; then pass "it is the installed binary, not the download"; else fail "the binary was replaced before the start"; fi
    stop_group "$W"
    if wait_no_fetch "$H" $((SLOW + 15)); then pass "the download ended after the wrapper's group was stopped"; else fail "the download is still running"; fi
    expect_installed "$H" "$NAME" "$PIN"

    # ------------------------------------------- 2. nothing installed
    test_case "$which: with nothing installed the start ends at once and the download goes on"
    H="$SCRATCH/$which-first"; empty_home "$H" "$which"; serve "$H" "$which"
    echo "$SLOW" > "$H/fake-curl/asset.delay"
    launch "$H" "$which"
    if [ "$RC" = 1 ] && within "$T" "$LIMIT"; then pass "the start ended after ${T}s with exit 1 (limit ${LIMIT}s)"
    else fail "after ${T}s: $RC (limit ${LIMIT}s)"; fi
    case "$(reason "$H" "$which")" in
        *"in the background"*) pass "the reason says the download goes on in the background" ;;
        *) fail "the reason does not say so: $(reason "$H" "$which" | head -4 | tr '\n' ' ')" ;;
    esac
    if [ "$which" = all ]; then
        if head -1 "$H/out" | jq -e '.id == 4 and .error.code == -32000' >/dev/null 2>&1; then pass "the error answers initialize"; else fail "no JSON-RPC error for id 4: $(head -c 200 "$H/out")"; fi
    fi
    if [ ! -e "$H/bin/$NAME" ]; then pass "nothing installed yet"; else fail "already installed (the download should still be running)"; fi
    stop_group "$W"
    if wait_no_fetch "$H" $((SLOW + 15)); then pass "the download ended after the wrapper's group was stopped"; else fail "the download is still running"; fi
    expect_installed "$H" "$NAME" "$PIN"

    # ------------------------------------------- 3. complete partial file
    test_case "$which: a complete partial file whose sha256 matches is installed without downloading"
    H="$SCRATCH/$which-complete"; empty_home "$H" "$which"; serve "$H" "$which"
    echo 404 > "$H/fake-curl/asset.status"       # a download would fail
    make_stage "$H"; cp "$ASSETS/$NAME" "$(part_of "$H" "$NAME" "$PIN")"
    launch "$H" "$which"
    expect_installed "$H" "$NAME" "$PIN"
    if ! grep -q '/releases/download/' "$H/curl.calls" 2>/dev/null; then pass "the asset was not downloaded again"; else fail "the asset was downloaded again"; fi
    if [ "$RC" = started ]; then pass "the installed binary was started"; else fail "not started ($RC): $(reason "$H" "$which" | head -3 | tr '\n' ' ')"; fi
    stop_group "$W"

    # ------------------------------------------- 4. the log
    test_case "$which: the download writes what it did to its log"
    LOG=$(log_of "$SCRATCH/$which-first" "$NAME")
    if grep -q "installed v$PIN" "$LOG" 2>/dev/null; then pass "the download log says v$PIN was installed"; else fail "no install line in $LOG: $(tail -3 "$LOG" 2>/dev/null | tr '\n' ' ')"; fi

    # ------------------------------------------- 5. a longer wait
    test_case "$which: a longer CHE_TELEGRAM_MCP_INSTALL_WAIT lets a first download finish"
    H="$SCRATCH/$which-longwait"; empty_home "$H" "$which"; serve "$H" "$which"
    echo 5 > "$H/fake-curl/asset.delay"          # longer than the default wait
    CHE_TELEGRAM_MCP_INSTALL_WAIT=20 launch "$H" "$which"
    if [ "$RC" = started ]; then pass "the downloaded binary was started after ${T}s"; else fail "not started ($RC after ${T}s): $(reason "$H" "$which" | head -3 | tr '\n' ' ')"; fi
    expect_installed "$H" "$NAME" "$PIN"
    stop_group "$W"
done

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
