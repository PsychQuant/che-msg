#!/bin/bash
# How the che-telegram-mcp wrappers download a binary (PsychQuant/che-msg#56).
#
# Before #56 a download was one `curl -sL --max-time …` into ~/bin/<Binary>.tmp:
# an HTTP error page was installed as the binary and recorded as the pinned
# version, so every later start ran it (or refused it) without downloading
# again; a transfer cut off was thrown away and the next start began from
# zero; and two wrappers started together wrote the same .tmp, the second
# truncating what the first was still writing.
#
# Runs both real wrappers, with /bin/bash as Claude Code does, against private
# HOMEs (tests/lib/wrapper_harness.sh). The fake curl serves the release API
# and a fake release asset; nothing reaches the network.
#
# Tests:
#   1. The fake curl itself: an HTTP error with and without -f, a cut-off
#      call, a resumed call, and a resume of a complete file.
#   For each wrapper:
#   2. An HTTP error for the asset: nothing is installed, no version record
#      is written, no partial file is left, and the start fails saying so.
#   3. A transfer cut off on every attempt: the start fails, keeping a
#      partial file named after the version; the next start resumes it
#      (-C -), installs a file identical to the asset, records the version
#      and starts it.
#   4. A partial file of another version is never resumed: it is removed and
#      the installed file is identical to the asset.
#   5. Retries: a transfer cut off once is retried, resumed, and installed in
#      the same start; an HTTP error is not retried, so it is reported at
#      once; curl gives up only on a stalled transfer (--speed-limit,
#      --speed-time), not after a fixed total time (--max-time).
#   6. Every attempt failing while a usable binary is installed: that binary
#      is kept and started, and its version record is unchanged.
#   7. Every attempt failing with nothing installed: the start fails, and the
#      reason says the transfer was interrupted.
#   And for telegram-all:
#   8. Two wrappers started together with nothing installed: the asset is
#      downloaded once, the other download says it is already running, the
#      installed binary is identical to the asset, and no partial file is left.
#   9. A process holding the download lock (flock, as a running download
#      does): a start downloads nothing, says the download is already
#      running, and leaves the lock alone; once the holder is gone the lock
#      file it leaves is no obstacle and the next start installs.
#  10. The download's files live in a private staging directory,
#      ~/bin/.che-telegram-mcp-download, mode 700, and nothing in it is
#      followed if it is a symbolic link: a partial file that is a link to the
#      installed binary leaves that binary's bytes untouched and the installed
#      file is the verified asset; a log that is a link leaves its target
#      untouched; a staging directory that is a link, or not a directory, is
#      refused and nothing is installed; one with looser permissions is set
#      back to 700. ~/bin holds no temporary file afterwards.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-download.sh
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

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-download-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
STARTED=()
finish() {
    for pid in "${STARTED[@]+"${STARTED[@]}"}"; do kill -KILL "$pid" 2>/dev/null; done
    for pids in "$SCRATCH"/*/started.pids "$SCRATCH"/*/curl.pids; do
        [ -f "$pids" ] && while read -r pid; do kill -KILL "$pid" 2>/dev/null; done < "$pids"
    done
    pkill -KILL -f -- "$SCRATCH" 2>/dev/null
    rm -rf "$SCRATCH"
}
trap finish EXIT

# ------------------------------------------------------------------ helpers
ALL=CheTelegramAllMCP
BOT=CheTelegramBotMCP
MIN_ALL=0.7.0      # the oldest telegram-all binary the wrapper runs
OLDER=0.0.1

# The release assets the fake curl serves: fake binaries, larger than a few
# bytes so that a cut-off transfer leaves a real partial file.
ASSETS="$SCRATCH/assets"; mkdir -p "$ASSETS"
write_fake_all_binary "$ASSETS/$ALL" "$DESIRED_VERSION"
write_fake_bot_binary "$ASSETS/$BOT"
for f in "$ASSETS/$ALL" "$ASSETS/$BOT"; do
    printf '# padding so that a transfer can be cut off part-way: %s\n' "$(printf 'x%.0s' $(seq 1 400))" >> "$f"
done

# empty_home <dir> <all|bot>: a HOME with credentials, the fake curl, and no binary.
empty_home() {
    if [ "$2" = all ]; then
        make_home "$1"
        rm -f "$1/bin/$ALL" "$1/bin/.$ALL.version"
    else
        make_bot_home "$1" -
        rm -f "$1/bin/$BOT"
    fi
}

# serve <home> <all|bot>: the release API and that wrapper's asset.
serve() {
    local name; name=$(asset_name "$2")
    serve_release_api "$1" "$name" "$ASSETS/$name"
    serve_asset "$1" "$ASSETS/$name"
}
asset_name() { if [ "$1" = all ]; then echo "$ALL"; else echo "$BOT"; fi; }
wrapper_of() { if [ "$1" = all ]; then echo "$WRAPPER"; else echo "$BOT_WRAPPER"; fi; }
pin_of() { if [ "$1" = all ]; then echo "$DESIRED_VERSION"; else echo "$BOT_DESIRED"; fi; }

# run <home> <all|bot> [id]: one start of the wrapper. It stops as soon as the
# installed binary has started (telegram-all's then keeps running and is
# stopped here) or the wrapper has exited. RC is the wrapper's exit status
# when it exited by itself, and "started" when it ran a binary.
run() {
    local home=$1 which=$2 id=${3:-1} w
    rm -f "$home/started.pids" "$home/out" "$home/err"
    printf '{"jsonrpc":"2.0","id":%s,"method":"initialize","params":{}}\n' "$id" > "$home/in"
    HOME="$home" PATH="$home/fakebin:$PATH" /bin/bash "$(wrapper_of "$which")" < "$home/in" > "$home/out" 2> "$home/err" &
    w=$!; STARTED+=("$w")
    wait_until 20 bash -c "[ -s '$home/started.pids' ] || ! kill -0 $w 2>/dev/null" || true
    if [ -s "$home/started.pids" ]; then
        RC=started
        stop "$w"
    else
        wait "$w"; RC=$?
    fi
}

# uses <call> <flag>: the recorded call passes <flag>; a one-letter flag may be
# part of a cluster such as -fsSL.
uses() {
    local tok
    for tok in $1; do
        case "$2" in
            -[!-]) case "$tok" in -[!-]*) case "${tok#-}" in *"${2#-}"*) return 0 ;; esac ;; esac ;;
            *) [ "$tok" = "$2" ] && return 0 ;;
        esac
    done
    return 1
}

asset_calls() { if [ -f "$1/curl.calls" ]; then grep -c '/releases/download/' "$1/curl.calls" || true; else echo 0; fi; }
nth_asset_call() { grep '/releases/download/' "$1/curl.calls" 2>/dev/null | sed -n "${2}p"; }
partials() { find "$1/bin" -name '*.part' 2>/dev/null | sort; }

# reason <home> <all|bot>: what the wrapper said when it stopped: telegram-all's
# JSON-RPC error message, the bot wrapper's stderr.
reason() {
    if [ "$2" = all ]; then head -1 "$1/out" | jq -r '.error.message' 2>/dev/null
    else cat "$1/err"; fi
}

expect_not_installed() {
    local home=$1 name=$2
    if [ ! -e "$home/bin/$name" ]; then pass "nothing installed at ~/bin/$name"; else fail "~/bin/$name was installed: $(head -c 80 "$home/bin/$name" | tr '\n' ' ')"; fi
    if [ ! -e "$home/bin/.$name.version" ]; then pass "no version record written"; else fail "version record written: $(cat "$home/bin/.$name.version")"; fi
}
expect_installed() {
    local home=$1 name=$2 version=$3
    if cmp -s "$home/bin/$name" "$ASSETS/$name"; then pass "~/bin/$name is identical to the asset"; else fail "~/bin/$name differs from the asset ($(wc -c < "$home/bin/$name" 2>/dev/null) vs $(wc -c < "$ASSETS/$name") bytes)"; fi
    if [ -x "$home/bin/$name" ]; then pass "it is executable"; else fail "it is not executable"; fi
    local rec; rec=$(cat "$home/bin/.$name.version" 2>/dev/null)
    if [ "$rec" = "$version" ]; then pass "version record says $version"; else fail "version record says '${rec}'"; fi
}

# -------------------------------------------------------------- 1. fake curl
test_case "the fake curl serves errors, cuts and resumes as curl does"
H="$SCRATCH/fake"; mkdir -p "$H/fake-curl"; printf '0123456789' > "$H/fake-curl/asset"
U="https://github.com/PsychQuant/che-msg/releases/download/v9.9.9/X"
fc() { HOME="$H" bash "$HARNESS_ROOT/tests/lib/fake_curl.sh" "$@"; }
fc -sL https://example.invalid/; r=$?
if [ "$r" -eq 1 ]; then pass "an URL with nothing to serve exits 1"; else fail "exit $r"; fi
echo 404 > "$H/fake-curl/asset.status"
fc -fsSL -o "$H/o1" "$U"; r=$?
if [ "$r" -eq 22 ] && [ ! -e "$H/o1" ]; then pass "HTTP error with -f: exit 22, nothing written"; else fail "HTTP error with -f: exit $r"; fi
fc -sL -o "$H/o2" "$U"; r=$?
if [ "$r" -eq 0 ] && [ "$(cat "$H/o2")" = "Not Found" ]; then pass "HTTP error without -f: exit 0 and the error page"; else fail "HTTP error without -f: exit $r"; fi
rm -f "$H/fake-curl/asset.status" "$H/fake-curl/asset.count"; printf '4\nfull\n' > "$H/fake-curl/asset.cuts"
fc -fsSL -C - -o "$H/o3" "$U"; r=$?
if [ "$r" -eq 56 ] && [ "$(cat "$H/o3")" = "0123" ]; then pass "a cut-off call: exit 56 after 4 bytes"; else fail "cut-off call: exit $r, '$(cat "$H/o3")'"; fi
fc -fsSL -C - -o "$H/o3" "$U"; r=$?
if [ "$r" -eq 0 ] && [ "$(cat "$H/o3")" = "0123456789" ]; then pass "-C - resumes from the file's size"; else fail "resume: exit $r, '$(cat "$H/o3")'"; fi
fc -fsSL -C - -o "$H/o3" "$U"; r=$?
if [ "$r" -eq 0 ] && [ "$(cat "$H/o3")" = "0123456789" ]; then pass "-C - on a complete file: exit 0, unchanged"; else fail "complete resume: exit $r"; fi

for which in all bot; do
    NAME=$(asset_name "$which"); PIN=$(pin_of "$which")
    SIZE=$(wc -c < "$ASSETS/$NAME" | tr -d ' ')

    # ---------------------------------------------------------- 2. HTTP error
    test_case "$which: an HTTP error for the asset is not installed"
    H="$SCRATCH/$which-http"; empty_home "$H" "$which"; serve "$H" "$which"
    echo 404 > "$H/fake-curl/asset.status"
    run "$H" "$which"
    if [ "$RC" = 1 ]; then pass "the start fails (exit 1)"; else fail "exit $RC"; fi
    expect_not_installed "$H" "$NAME"
    if [ -z "$(partials "$H")" ]; then pass "no partial file left"; else fail "left: $(partials "$H")"; fi
    case "$(reason "$H" "$which")" in
        *"HTTP error"*) pass "the reason names the HTTP error" ;;
        *) fail "the reason does not name the HTTP error: $(reason "$H" "$which" | head -3 | tr '\n' ' ')" ;;
    esac

    # --------------------------------------------------------- 3. resume
    test_case "$which: a transfer cut off is resumed by the next start"
    H="$SCRATCH/$which-resume"; empty_home "$H" "$which"; serve "$H" "$which"
    HALF=$((SIZE / 2)); printf '%s\n%s\n%s\n%s\nfull\n' "$HALF" "$HALF" "$HALF" "$HALF" > "$H/fake-curl/asset.cuts"
    run "$H" "$which"
    if [ "$RC" = 1 ]; then pass "the first start fails (exit 1)"; else fail "first start: $RC"; fi
    PART=$(part_of "$H" "$NAME" "$PIN")
    if [ -f "$PART" ] && [ "$(wc -c < "$PART" | tr -d ' ')" = "$HALF" ]; then
        pass "a partial file named after the version keeps the $HALF bytes received"
    else
        fail "no partial file $PART with $HALF bytes (found: $(partials "$H" | tr '\n' ' '))"
    fi
    expect_not_installed "$H" "$NAME"
    run "$H" "$which"
    N=$(asset_calls "$H")
    case "$(nth_asset_call "$H" "$N")" in
        *"-C -"*) pass "the second start's download resumes (-C -)" ;;
        *) fail "the second start's download does not resume: $(nth_asset_call "$H" "$N")" ;;
    esac
    expect_installed "$H" "$NAME" "$PIN"
    if [ -z "$(partials "$H")" ]; then pass "no partial file left"; else fail "left: $(partials "$H")"; fi
    if [ "$RC" = started ]; then pass "the installed binary was started"; else fail "not started (exit $RC): $(tail -2 "$H/err" | tr '\n' ' ')"; fi

    # ------------------------------------------- 4. another version's partial
    test_case "$which: a partial file of another version is never resumed"
    H="$SCRATCH/$which-otherpart"; empty_home "$H" "$which"; serve "$H" "$which"
    make_stage "$H"; printf 'GARBAGE FROM AN OLDER RELEASE' > "$(part_of "$H" "$NAME" "$OLDER")"
    run "$H" "$which"
    expect_installed "$H" "$NAME" "$PIN"
    if [ ! -e "$(part_of "$H" "$NAME" "$OLDER")" ]; then pass "the other version's partial file is removed"; else fail "the other version's partial file is still there"; fi

    # ------------------------------------------------------------- 5. retries
    test_case "$which: a cut-off transfer is retried in the same start, an HTTP error is not"
    CALL=$(nth_asset_call "$H" 1)
    for flag in -f --speed-limit --speed-time; do
        if uses "$CALL" "$flag"; then pass "uses $flag"; else fail "does not use $flag: $CALL"; fi
    done
    case " $CALL " in *" -C - "*) pass "uses -C -" ;; *) fail "does not use -C -: $CALL" ;; esac
    if uses "$CALL" --max-time; then fail "caps the whole transfer with --max-time: $CALL"; else pass "no --max-time cap"; fi
    H="$SCRATCH/$which-retry"; empty_home "$H" "$which"; serve "$H" "$which"
    printf '%s\nfull\n' "$((SIZE / 3))" > "$H/fake-curl/asset.cuts"
    run "$H" "$which"
    if [ "$RC" = started ]; then pass "one start installs and starts it"; else fail "not started ($RC): $(reason "$H" "$which" | head -3 | tr '\n' ' ')"; fi
    expect_installed "$H" "$NAME" "$PIN"
    if [ "$(asset_calls "$H")" = 2 ]; then pass "two transfers, the second one resumed"; else fail "$(asset_calls "$H") transfers"; fi
    case "$(nth_asset_call "$H" 2)" in *"-C -"*) pass "the retry resumes (-C -)" ;; *) fail "the retry does not resume: $(nth_asset_call "$H" 2)" ;; esac
    H="$SCRATCH/$which-http-once"; empty_home "$H" "$which"; serve "$H" "$which"
    echo 404 > "$H/fake-curl/asset.status"
    run "$H" "$which"
    if [ "$(asset_calls "$H")" = 1 ]; then pass "an HTTP error is tried once"; else fail "an HTTP error was tried $(asset_calls "$H") times"; fi
    if [ "$(grep -c 'api.github.com' "$H/curl.calls")" = 1 ]; then pass "the release API is asked once"; else fail "the release API was asked $(grep -c 'api.github.com' "$H/curl.calls") times"; fi
    for f in "$H/curl.calls"; do
        if grep -q -- '--retry-all-errors' "$f"; then fail "a call retries every error, HTTP errors included: $(grep -- '--retry-all-errors' "$f" | head -1)"; else pass "no call retries HTTP errors (--retry-all-errors)"; fi
    done

    # -------------------------------------- 6. failing, usable binary kept
    test_case "$which: every attempt failing keeps a usable installed binary"
    H="$SCRATCH/$which-keep"
    if [ "$which" = all ]; then make_home "$H" yes "$MIN_ALL"; KEPT_RECORD=$MIN_ALL
    else make_bot_home "$H" "$OLDER"; KEPT_RECORD=$OLDER; fi
    cp "$H/bin/$NAME" "$SCRATCH/kept-$which"
    serve "$H" "$which"; printf '0\n0\n0\n0\n' > "$H/fake-curl/asset.cuts"
    run "$H" "$which"
    if [ "$RC" = started ]; then pass "the installed binary was started"; else fail "not started (exit $RC): $(reason "$H" "$which" | tr '\n' ' ')"; fi
    wait_no_fetch "$H" || fail "the background download did not end"   # it runs on after the hand-over (#67)
    if cmp -s "$H/bin/$NAME" "$SCRATCH/kept-$which"; then pass "the installed binary is unchanged"; else fail "the installed binary was replaced"; fi
    if [ "$(cat "$H/bin/.$NAME.version")" = "$KEPT_RECORD" ]; then pass "its version record still says $KEPT_RECORD"; else fail "record now says $(cat "$H/bin/.$NAME.version")"; fi
    if [ "$(asset_calls "$H")" -ge 1 ]; then pass "a download was attempted"; else fail "no download attempt"; fi

    # ------------------------------------- 7. failing, nothing installed
    test_case "$which: every attempt failing with nothing installed names the interruption"
    H="$SCRATCH/$which-nothing"; empty_home "$H" "$which"; serve "$H" "$which"
    printf '0\n0\n0\n0\n' > "$H/fake-curl/asset.cuts"
    run "$H" "$which" 21
    if [ "$RC" = 1 ]; then pass "the start fails (exit 1)"; else fail "exit $RC"; fi
    expect_not_installed "$H" "$NAME"
    case "$(reason "$H" "$which")" in
        *interrupted*) pass "the reason says the transfer was interrupted" ;;
        *) fail "the reason does not say interrupted: $(reason "$H" "$which" | head -3 | tr '\n' ' ')" ;;
    esac
    if [ "$which" = all ]; then
        if head -1 "$H/out" | jq -e '.id == 21 and .error.code == -32000' >/dev/null 2>&1; then
            pass "telegram-all answers the initialize request"
        else
            fail "no JSON-RPC error for id 21: $(head -c 200 "$H/out")"
        fi
    fi
done

# ------------------------------------------------- 8. two wrappers at once
test_case "telegram-all: two wrappers started together download once"
H="$SCRATCH/all-two"; empty_home "$H" all; serve "$H" all
echo 1 > "$H/fake-curl/asset.delay"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' > "$H/in"
W1=$(HOME="$H" PATH="$H/fakebin:$PATH" /bin/bash "$WRAPPER" < "$H/in" > "$H/out1" 2> "$H/err1" & echo $!); STARTED+=("$W1")
W2=$(HOME="$H" PATH="$H/fakebin:$PATH" /bin/bash "$WRAPPER" < "$H/in" > "$H/out2" 2> "$H/err2" & echo $!); STARTED+=("$W2")
wait_until 20 bash -c "! kill -0 $W1 2>/dev/null && ! kill -0 $W2 2>/dev/null || [ -s '$H/started.pids' ]" || true
sleep 3
n=$(asset_calls "$H")
if [ "$n" = 1 ]; then pass "the asset was downloaded once"; else fail "the asset was downloaded $n times"; fi
expect_installed "$H" "$ALL" "$DESIRED_VERSION"
if [ -z "$(partials "$H")" ]; then pass "no partial file left"; else fail "left: $(partials "$H")"; fi
if grep -q 'download already running' "$(log_of "$H" "$ALL")" 2>/dev/null; then pass "the second download says the download is already running"; else fail "log: $(cat "$(log_of "$H" "$ALL")" 2>/dev/null | tr '\n' ' ')"; fi
if has_pids "$H" 1; then pass "a binary was started"; else fail "no binary started: $(cat "$H/err1" "$H/err2" | tr '\n' ' ')"; fi
stop "$W1"; stop "$W2"

# ---------------------------------------- 9. a lock held by a running download
test_case "telegram-all: a download another process is running is left to it"
H="$SCRATCH/all-held"; empty_home "$H" all; serve "$H" all
LOCK=$(lock_of "$H" "$ALL"); mkdir -p "$(dirname "$LOCK")"
HOLDER=$(hold_lock "$LOCK"); STARTED+=("$HOLDER")
wait_until 5 test -e "$LOCK" || fail "the holder did not take the lock"
CHE_TELEGRAM_MCP_INSTALL_WAIT=1 run "$H" all
wait_no_fetch "$H"
if [ "$(asset_calls "$H")" = 0 ]; then pass "nothing was downloaded"; else fail "downloaded $(asset_calls "$H") time(s) while another process held the lock"; fi
if grep -q 'download already running' "$(log_of "$H" "$ALL")" 2>/dev/null; then pass "the log says the download is already running"; else fail "log: $(tail -2 "$(log_of "$H" "$ALL")" 2>/dev/null | tr '\n' ' ')"; fi
if [ ! -e "$H/bin/$ALL" ]; then pass "nothing installed"; else fail "installed while another process held the lock"; fi
if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then pass "the held lock file is left alone"; else fail "the held lock file was removed or replaced"; fi
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
run "$H" all
expect_installed "$H" "$ALL" "$DESIRED_VERSION"
if [ "$RC" = started ]; then pass "with the holder gone, the next start installs and starts it"; else fail "next start: $RC"; fi

# ---------------------------------------------- 10. the staging directory
test_case "telegram-all: a partial file that is a symbolic link is not followed"
H="$SCRATCH/all-partlink"; make_home "$H" yes "$MIN_ALL"; serve "$H" all
ln "$H/bin/$ALL" "$SCRATCH/installed-inode"          # a second name for the installed file's bytes
cp "$H/bin/$ALL" "$SCRATCH/installed-copy"
make_stage "$H"; ln -s "$H/bin/$ALL" "$(part_of "$H" "$ALL" "$DESIRED_VERSION")"
run "$H" all
wait_no_fetch "$H" || fail "the background download did not end"
if cmp -s "$SCRATCH/installed-inode" "$SCRATCH/installed-copy"; then pass "the installed binary's bytes were not written to"; else fail "the installed binary's bytes were changed through the link"; fi
expect_installed "$H" "$ALL" "$DESIRED_VERSION"
if [ ! -L "$(part_of "$H" "$ALL" "$DESIRED_VERSION")" ]; then pass "the link is gone"; else fail "the link is still there"; fi

test_case "telegram-all: a log that is a symbolic link is not followed"
H="$SCRATCH/all-loglink"; empty_home "$H" all; serve "$H" all
printf 'keep\n' > "$SCRATCH/outside-log"
make_stage "$H"; ln -s "$SCRATCH/outside-log" "$(log_of "$H" "$ALL")"
run "$H" all
if [ "$(cat "$SCRATCH/outside-log")" = keep ]; then pass "the link's target is untouched"; else fail "the link's target was written: $(head -c 120 "$SCRATCH/outside-log")"; fi
expect_installed "$H" "$ALL" "$DESIRED_VERSION"
LOG=$(log_of "$H" "$ALL")
if [ -f "$LOG" ] && [ ! -L "$LOG" ] && grep -q "installed v$DESIRED_VERSION" "$LOG"; then pass "the log is a file of its own"; else fail "the log is not a regular file with the install line"; fi

i=0
for kind in link file; do
    i=$((i + 1))
    test_case "telegram-all: a staging directory that is a $kind is refused"
    H="$SCRATCH/all-stage-$kind"; empty_home "$H" all; serve "$H" all
    mkdir -p "$SCRATCH/elsewhere-$i"
    if [ "$kind" = link ]; then ln -s "$SCRATCH/elsewhere-$i" "$(stage_of "$H")"; else printf 'x' > "$(stage_of "$H")"; fi
    run "$H" all 30
    if [ "$RC" = 1 ]; then pass "the start fails (exit 1)"; else fail "exit $RC"; fi
    if [ ! -e "$H/bin/$ALL" ]; then pass "nothing installed"; else fail "installed anyway"; fi
    if [ -z "$(ls -A "$SCRATCH/elsewhere-$i")" ]; then pass "nothing was written where the link points"; else fail "written there: $(ls -A "$SCRATCH/elsewhere-$i" | tr '\n' ' ')"; fi
    if [ "$(asset_calls "$H")" = 0 ]; then pass "nothing was downloaded"; else fail "downloaded $(asset_calls "$H") time(s)"; fi
    case "$(reason "$H" all)" in
        *".che-telegram-mcp-download"*) pass "the reason names the staging directory" ;;
        *) fail "the reason does not name it: $(reason "$H" all)" ;;
    esac
done

test_case "telegram-all: the staging directory is private"
H="$SCRATCH/all-stage-mode"; empty_home "$H" all; serve "$H" all
mkdir -m 777 "$(stage_of "$H")"; chmod 777 "$(stage_of "$H")"
run "$H" all
if [ "$(stat -f %Lp "$(stage_of "$H")")" = 700 ]; then pass "set back to 700"; else fail "mode $(stat -f %Lp "$(stage_of "$H")")"; fi
expect_installed "$H" "$ALL" "$DESIRED_VERSION"
H="$SCRATCH/all-resume"
extra=$(cd "$H/bin" && ls -A | grep -v -x -e "$ALL" -e ".$ALL.version" -e "$(basename "$(stage_of "$H")")" || true)
if [ -z "$extra" ]; then pass "~/bin holds only the binary, its version record and the staging directory"; else fail "~/bin also holds: $(echo "$extra" | tr '\n' ' ')"; fi

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
