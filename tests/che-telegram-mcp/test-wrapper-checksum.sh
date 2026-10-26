#!/bin/bash
# The che-telegram-mcp wrappers install a download only after checking its
# sha256 (PsychQuant/che-msg#50).
#
# Each wrapper pins SHA256_PIN, the sha256 of its v$DESIRED_VERSION release
# asset, next to DESIRED_VERSION, with SHA256_PIN_VERSION naming the version
# the pin was taken from; the pin counts only while that equals
# DESIRED_VERSION. With no pin that counts (0.8.0 was released before pins
# existed), the download is checked against the sha256 digest GitHub's release
# API reports for the asset. A file that does not match is removed, and the
# installed binary and its version record stay as they were. The wrappers
# download v$DESIRED_VERSION from its own release URL and never fall back to
# releases/latest, whose file a pin could never match.
#
# Runs both real wrappers, and copies of them with a pin set, with /bin/bash
# against private HOMEs (tests/lib/wrapper_harness.sh); the fake curl serves
# the release API and a fake asset, and nothing reaches the network.
#
# Tests, for each wrapper:
#   1. The wrapper assigns SHA256_PIN_VERSION and SHA256_PIN, and downloads
#      from releases/download/v$DESIRED_VERSION/<Binary>.
#   2. Pinned, matching sha256: installed, recorded, started; the release API
#      is not called.
#   3. Pinned, sha256 that does not match, nothing installed: nothing is
#      installed or recorded, no partial file is left, and the reason names
#      the mismatch.
#   4. The same with a usable binary installed: it is kept, unchanged, with
#      its version record, and started.
#   5. A pin for another version is not used: the download is checked against
#      GitHub's digest instead, and the download log says so.
#   6. No pin: GitHub's digest matching installs; not matching installs
#      nothing; no digest (null) installs nothing and says no sha256 is known;
#      the API unreachable installs nothing.
#   7. The pinned version's asset missing (HTTP 404): nothing installed, and
#      releases/latest is never asked; the same with no pin and no such
#      release.
#   8. No case above called releases/latest.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-checksum.sh
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

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-checksum-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
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

ALL=CheTelegramAllMCP
BOT=CheTelegramBotMCP
MIN_ALL=0.7.0
OLDER=0.0.1

ASSETS="$SCRATCH/assets"; mkdir -p "$ASSETS"
write_fake_all_binary "$ASSETS/$ALL" "$DESIRED_VERSION"
write_fake_bot_binary "$ASSETS/$BOT"
# A file of the same kind with other bytes: what a replaced asset would be.
for name in $ALL $BOT; do
    cp "$ASSETS/$name" "$ASSETS/$name.other"
    echo '# not the release that was pinned' >> "$ASSETS/$name.other"
done
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

asset_name() { if [ "$1" = all ]; then echo "$ALL"; else echo "$BOT"; fi; }
wrapper_of() { if [ "$1" = all ]; then echo "$WRAPPER"; else echo "$BOT_WRAPPER"; fi; }
pin_of() { if [ "$1" = all ]; then echo "$DESIRED_VERSION"; else echo "$BOT_DESIRED"; fi; }

empty_home() {
    if [ "$2" = all ]; then make_home "$1"; rm -f "$1/bin/$ALL" "$1/bin/.$ALL.version"
    else make_bot_home "$1" -; rm -f "$1/bin/$BOT"; fi
}

# pinned <all|bot> <pin version> <pin> <dir>: sets C to a copy of the wrapper
# with SHA256_PIN_VERSION and SHA256_PIN set. A copy whose lines could not be
# set is reported, and C still set, so the case runs and shows what the
# wrapper does without them.
pinned() {
    C=$(wrapper_copy "$(wrapper_of "$1")" "$4")
    perl -pi -e "s/^SHA256_PIN_VERSION=\".*\"\$/SHA256_PIN_VERSION=\"$2\"/; s/^SHA256_PIN=\".*\"\$/SHA256_PIN=\"$3\"/" "$C"
    if ! grep -qx "SHA256_PIN_VERSION=\"$2\"" "$C" || ! grep -qx "SHA256_PIN=\"$3\"" "$C"; then
        fail "the copy of the $1 wrapper has no SHA256_PIN_VERSION / SHA256_PIN lines to set"
    fi
}

# run <home> <wrapper> [id]: one start, as in test-wrapper-download.sh. RC is
# the wrapper's exit status, or "started" when it ran a binary.
run() {
    local home=$1 wrapper=$2 id=${3:-1} w
    rm -f "$home/started.pids" "$home/out" "$home/err"
    printf '{"jsonrpc":"2.0","id":%s,"method":"initialize","params":{}}\n' "$id" > "$home/in"
    HOME="$home" PATH="$home/fakebin:$PATH" /bin/bash "$wrapper" < "$home/in" > "$home/out" 2> "$home/err" &
    w=$!; STARTED+=("$w")
    wait_until 20 bash -c "[ -s '$home/started.pids' ] || ! kill -0 $w 2>/dev/null" || true
    if [ -s "$home/started.pids" ]; then RC=started; stop "$w"
    else wait "$w"; RC=$?; fi
}

reason() {
    if [ "$2" = all ]; then head -1 "$1/out" | jq -r '.error.message' 2>/dev/null
    else cat "$1/err"; fi
}
partials() { find "$1/bin" -name '*.part' 2>/dev/null | sort; }

expect_reason() {   # <home> <which> <substring> <what>
    case "$(reason "$1" "$2")" in
        *"$3"*) pass "the reason $4" ;;
        *) fail "the reason does not say '$3': $(reason "$1" "$2" | head -4 | tr '\n' ' ')" ;;
    esac
}
expect_installed() {   # <home> <name> <version>
    if cmp -s "$1/bin/$2" "$ASSETS/$2"; then pass "~/bin/$2 is the release asset"; else fail "~/bin/$2 is not the release asset"; fi
    if [ "$(cat "$1/bin/.$2.version" 2>/dev/null)" = "$3" ]; then pass "version record says $3"; else fail "version record: '$(cat "$1/bin/.$2.version" 2>/dev/null)'"; fi
}
expect_nothing_installed() {   # <home> <name>
    if [ ! -e "$1/bin/$2" ]; then pass "nothing installed"; else fail "~/bin/$2 was installed"; fi
    if [ ! -e "$1/bin/.$2.version" ]; then pass "no version record"; else fail "a version record was written: $(cat "$1/bin/.$2.version")"; fi
    if [ -z "$(partials "$1")" ]; then pass "no partial file left"; else fail "left: $(partials "$1")"; fi
}
api_calls() { grep -c 'api.github.com' "$1/curl.calls" 2>/dev/null || true; }

for which in all bot; do
    NAME=$(asset_name "$which"); PIN=$(pin_of "$which"); REAL=$(wrapper_of "$which")
    GOOD=$(sha "$ASSETS/$NAME"); BAD=$(sha "$ASSETS/$NAME.other")

    # ------------------------------------------------------- 1. the pin lines
    test_case "$which: the wrapper pins a sha256 and downloads the pinned release directly"
    n=$(grep -c '^SHA256_PIN_VERSION="[^"]*"$' "$REAL"); m=$(grep -c '^SHA256_PIN="[^"]*"$' "$REAL")
    if [ "$n" = 1 ] && [ "$m" = 1 ]; then pass "SHA256_PIN_VERSION and SHA256_PIN are assigned once each"; else fail "SHA256_PIN_VERSION assigned $n times, SHA256_PIN $m times"; fi
    if grep -q '^DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME"$' "$REAL"; then
        pass "DOWNLOAD_URL is releases/download/v\$DESIRED_VERSION/\$BINARY_NAME"
    else
        fail "no DOWNLOAD_URL of the pinned release"
    fi

    # ------------------------------------------------------ 2. pinned, match
    test_case "$which: a download matching the pin is installed"
    H="$SCRATCH/$which-match"; empty_home "$H" "$which"; serve_asset "$H" "$ASSETS/$NAME"
    serve_release_api "$H" "$NAME" "$ASSETS/$NAME.other"   # must not be consulted
    pinned "$which" "$PIN" "$GOOD" "$SCRATCH/$which-match-plugin"
    run "$H" "$C"
    expect_installed "$H" "$NAME" "$PIN"
    if [ "$RC" = started ]; then pass "the installed binary was started"; else fail "not started (exit $RC): $(reason "$H" "$which" | tr '\n' ' ')"; fi
    if [ "$(api_calls "$H")" = 0 ]; then pass "the release API was not called"; else fail "the release API was called: $(grep api.github.com "$H/curl.calls" | head -1)"; fi

    # -------------------------------------------- 3. pinned, mismatch, empty
    test_case "$which: a download that does not match the pin is not installed"
    H="$SCRATCH/$which-mismatch"; empty_home "$H" "$which"; serve_asset "$H" "$ASSETS/$NAME.other"
    pinned "$which" "$PIN" "$GOOD" "$SCRATCH/$which-mismatch-plugin"
    run "$H" "$C" 31
    if [ "$RC" = 1 ]; then pass "the start fails (exit 1)"; else fail "exit $RC"; fi
    expect_nothing_installed "$H" "$NAME"
    expect_reason "$H" "$which" "does not match its sha256" "names the sha256 mismatch"

    # ------------------------------------------- 4. pinned, mismatch, kept
    test_case "$which: a mismatching download leaves a usable installed binary alone"
    H="$SCRATCH/$which-mismatch-keep"
    if [ "$which" = all ]; then make_home "$H" yes "$MIN_ALL"; KEPT=$MIN_ALL; else make_bot_home "$H" "$OLDER"; KEPT=$OLDER; fi
    cp "$H/bin/$NAME" "$SCRATCH/kept-$which"
    serve_asset "$H" "$ASSETS/$NAME.other"
    pinned "$which" "$PIN" "$GOOD" "$SCRATCH/$which-mismatch-keep-plugin"
    run "$H" "$C"
    if [ "$RC" = started ]; then pass "the installed binary was started"; else fail "not started (exit $RC): $(reason "$H" "$which" | tr '\n' ' ')"; fi
    wait_no_fetch "$H" || fail "the background download did not end"
    if cmp -s "$H/bin/$NAME" "$SCRATCH/kept-$which"; then pass "the installed binary is unchanged"; else fail "the installed binary was replaced"; fi
    if [ "$(cat "$H/bin/.$NAME.version")" = "$KEPT" ]; then pass "its version record still says $KEPT"; else fail "record now $(cat "$H/bin/.$NAME.version")"; fi
    if [ -z "$(partials "$H")" ]; then pass "no partial file left"; else fail "left: $(partials "$H")"; fi

    # ------------------------------------------- 5. pin of another version
    test_case "$which: a pin taken from another version is not used"
    H="$SCRATCH/$which-stale"; empty_home "$H" "$which"; serve_asset "$H" "$ASSETS/$NAME"
    serve_release_api "$H" "$NAME" "$ASSETS/$NAME"
    pinned "$which" "$OLDER" "$BAD" "$SCRATCH/$which-stale-plugin"
    run "$H" "$C"
    expect_installed "$H" "$NAME" "$PIN"
    LOG=$(log_of "$H" "$NAME")
    if grep -q "is for v$OLDER" "$LOG" 2>/dev/null; then pass "the download log says the pin is for v$OLDER"; else fail "the download log does not say the pin is for v$OLDER: $(head -3 "$LOG" 2>/dev/null | tr '\n' ' ')"; fi

    # ------------------------------------------------------ 6. no pin
    test_case "$which: with no pin, GitHub's digest decides"
    H="$SCRATCH/$which-digest-good"; empty_home "$H" "$which"; serve_asset "$H" "$ASSETS/$NAME"
    serve_release_api "$H" "$NAME" "$ASSETS/$NAME"
    pinned "$which" "" "" "$SCRATCH/$which-digest-good-plugin"
    run "$H" "$C"
    expect_installed "$H" "$NAME" "$PIN"

    H="$SCRATCH/$which-digest-bad"; empty_home "$H" "$which"; serve_asset "$H" "$ASSETS/$NAME.other"
    serve_release_api "$H" "$NAME" "$ASSETS/$NAME"
    run "$H" "$C"
    if [ "$RC" = 1 ]; then pass "a mismatch: the start fails"; else fail "a mismatch: exit $RC"; fi
    expect_nothing_installed "$H" "$NAME"
    expect_reason "$H" "$which" "does not match its sha256" "names the mismatch"

    H="$SCRATCH/$which-digest-null"; empty_home "$H" "$which"; serve_asset "$H" "$ASSETS/$NAME"
    serve_release_api "$H" "$NAME" "$ASSETS/$NAME"
    perl -0pi -e 's/"digest": "sha256:[0-9a-f]{64}",(\s*"browser_download_url": "[^"]*\/'"$NAME"'")/"digest": null,$1/' "$H/fake-curl/api"
    grep -q '"digest": null' "$H/fake-curl/api" || fail "the test could not set the digest to null"
    run "$H" "$C"
    if [ "$RC" = 1 ]; then pass "no digest: the start fails"; else fail "no digest: exit $RC"; fi
    expect_nothing_installed "$H" "$NAME"
    expect_reason "$H" "$which" "no sha256 is known" "says no sha256 is known"
    if ! grep -q '/releases/download/' "$H/curl.calls" 2>/dev/null; then pass "nothing was downloaded without a sha256 to check"; else fail "the asset was downloaded with nothing to check it against"; fi

    H="$SCRATCH/$which-digest-offline"; empty_home "$H" "$which"; serve_asset "$H" "$ASSETS/$NAME"
    run "$H" "$C"
    if [ "$RC" = 1 ]; then pass "the API unreachable: the start fails"; else fail "the API unreachable: exit $RC"; fi
    expect_nothing_installed "$H" "$NAME"

    # ----------------------------------------------------- 7. missing asset
    test_case "$which: a missing pinned asset does not fall back to releases/latest"
    H="$SCRATCH/$which-missing"; empty_home "$H" "$which"; serve_asset "$H" "$ASSETS/$NAME"
    echo 404 > "$H/fake-curl/asset.status"
    pinned "$which" "$PIN" "$GOOD" "$SCRATCH/$which-missing-plugin"
    run "$H" "$C"
    if [ "$RC" = 1 ]; then pass "the start fails"; else fail "exit $RC"; fi
    expect_nothing_installed "$H" "$NAME"
    expect_reason "$H" "$which" "HTTP error" "names the HTTP error"

    H="$SCRATCH/$which-missing-release"; empty_home "$H" "$which"
    serve_release_api "$H" "$NAME" "$ASSETS/$NAME"; echo 404 > "$H/fake-curl/api.status"
    pinned "$which" "" "" "$SCRATCH/$which-missing-release-plugin"
    run "$H" "$C"
    if [ "$RC" = 1 ]; then pass "no pin, no such release: the start fails"; else fail "no pin, no such release: exit $RC"; fi
    expect_nothing_installed "$H" "$NAME"
done

# ------------------------------------------------------- 8. never latest
test_case "no case asked for releases/latest"
hits=$(grep -l 'releases/latest' "$SCRATCH"/*/curl.calls 2>/dev/null || true)
if [ -z "$hits" ]; then pass "releases/latest was never requested"; else fail "requested in: $hits"; fi

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
