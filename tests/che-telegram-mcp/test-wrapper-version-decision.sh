#!/bin/bash
# When the che-telegram-mcp wrappers download a binary (PsychQuant/che-msg#83).
#
# Each wrapper pins DESIRED_VERSION and reads the installed version from the
# sidecar ~/bin/.<Binary>.version. It downloads only when the sidecar is not a
# plain x.y.z or is older than the pin; it never replaces a binary that is newer
# than its pin. Before #83 it downloaded on any difference, so a session still
# running an older plugin put the older binary back over a newer one.
#
# Runs both real wrappers against private HOMEs with a fake `curl` that records
# its calls and fails, and a fake `security`; nothing outside the scratch
# directory is read or written, and nothing reaches the network.
#
# Tests, for each wrapper:
#   1. Sidecar newer than the pin: no download attempt.
#   2. Sidecar equal to the pin: no download attempt.
#   3. Sidecar older than the pin: a download attempt.
#   4. Sidecar missing: a download attempt.
#   5. Sidecar empty: a download attempt.
#   6. Sidecar not x.y.z ("latest", "0.8", "v<newer>"): a download attempt.
# And for telegram-all:
#   7. Newer sidecar: the installed binary is started.
#   8. Newer sidecar next to a binary that fails the minimum-version probe: the
#      wrapper refuses it and the message gives the recorded version, not the
#      pin.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-version-decision.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/wrapper_harness.sh"

BOT_WRAPPER="${BOT_WRAPPER_UNDER_TEST:-$HARNESS_ROOT/plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh}"
BOT_DESIRED=$(sed -n 's/^DESIRED_VERSION="\(.*\)"$/\1/p' "$BOT_WRAPPER")

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

# newer_than <x.y.z>: the next major version, so it stays newer when the pin moves.
newer_than() { echo "$(( ${1%%.*} + 1 )).0.0"; }
OLDER="0.0.1"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-version-XXXXXX")
STARTED=()
finish() {
    for pid in "${STARTED[@]}"; do kill -KILL "$pid" 2>/dev/null; done
    for pids in "$SCRATCH"/*/started.pids; do
        [ -f "$pids" ] && while read -r pid; do kill -KILL "$pid" 2>/dev/null; done < "$pids"
    done
    rm -rf "$SCRATCH"
}
trap finish EXIT

downloaded() { [ -s "$1/curl.calls" ]; }

expect_download() {
    if downloaded "$1"; then pass "$2: a download was attempted"; else fail "$2: no download attempt"; fi
}
expect_no_download() {
    if downloaded "$1"; then fail "$2: a download was attempted ($(head -1 "$1/curl.calls"))"; else pass "$2: no download attempt"; fi
}

# ---------------------------------------------------------------- telegram-all
ALL_NEWER=$(newer_than "$DESIRED_VERSION")

# run_all <home> <sidecar content | "-" to remove it>: runs the wrapper and
# stops it once it has either started the binary or exited.
run_all() {
    local home=$1 sidecar=$2 w
    if [ "$sidecar" = - ]; then rm -f "$home/bin/.CheTelegramAllMCP.version"
    else printf '%s' "$sidecar" > "$home/bin/.CheTelegramAllMCP.version"; fi
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' > "$home/in"
    w=$(start_wrapper "$home" "$home/in" "$home/out"); STARTED+=("$w")
    wait_until 10 bash -c "[ -s '$home/started.pids' ] || ! kill -0 $w 2>/dev/null" || true
    stop "$w"
}

test_case "telegram-all: sidecar newer than the pin ($ALL_NEWER > $DESIRED_VERSION)"
H="$SCRATCH/all-newer"; make_home "$H" yes "$ALL_NEWER"; run_all "$H" "$ALL_NEWER"
expect_no_download "$H" "newer"
if has_pids "$H" 1; then pass "the installed binary was started"; else fail "the installed binary was not started: $(tail -3 "$H/wrapper.stderr" 2>/dev/null)"; fi

test_case "telegram-all: sidecar equal to the pin"
H="$SCRATCH/all-equal"; make_home "$H" yes "$DESIRED_VERSION"; run_all "$H" "$DESIRED_VERSION"
expect_no_download "$H" "equal"

test_case "telegram-all: sidecar older than the pin"
H="$SCRATCH/all-older"; make_home "$H" yes "$OLDER"; run_all "$H" "$OLDER"
expect_download "$H" "older"

test_case "telegram-all: sidecar missing"
H="$SCRATCH/all-missing"; make_home "$H" yes "$DESIRED_VERSION"; run_all "$H" -
expect_download "$H" "missing"

test_case "telegram-all: sidecar empty"
H="$SCRATCH/all-empty"; make_home "$H" yes "$DESIRED_VERSION"; run_all "$H" ""
expect_download "$H" "empty"

for bad in latest 0.8 "v$ALL_NEWER"; do
    test_case "telegram-all: sidecar not x.y.z ('$bad')"
    H="$SCRATCH/all-bad-$bad"; make_home "$H" yes "$DESIRED_VERSION"; run_all "$H" "$bad"
    expect_download "$H" "'$bad'"
done

test_case "telegram-all: newer sidecar, binary fails the minimum-version probe"
H="$SCRATCH/all-newer-silent"; make_home "$H" yes silent
echo "$ALL_NEWER" > "$H/bin/.CheTelegramAllMCP.version"
printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"initialize","params":{}}' > "$H/in"
HOME="$H" PATH="$H/fakebin:$PATH" bash "$WRAPPER" < "$H/in" > "$H/out" 2> "$H/err"
RC=$?
if [ "$RC" -eq 1 ]; then pass "exit status 1 (refused)"; else fail "exit status $RC"; fi
expect_no_download "$H" "newer sidecar"
MSG=$(head -1 "$H/out" | jq -r '.error.message' 2>/dev/null)
case "$MSG" in
    *"says v$ALL_NEWER"*) pass "the message gives the recorded version v$ALL_NEWER" ;;
    *) fail "the message does not give the recorded version: $MSG" ;;
esac
case "$MSG" in
    *"already says v$DESIRED_VERSION"*) fail "the message claims the record says the pin: $MSG" ;;
    *) pass "the message does not claim the record says v$DESIRED_VERSION" ;;
esac

# --------------------------------------------------------------------- bot
BOT_NEWER=$(newer_than "$BOT_DESIRED")

# make_bot_home <dir> <sidecar content | "-">: an installed fake bot binary, a
# `security` that finds no token (so the wrapper stops after its download
# decision), and the recording, failing `curl`.
make_bot_home() {
    local home=$1 sidecar=$2
    mkdir -p "$home/bin" "$home/fakebin"
    printf '#!/bin/bash\necho $$ >> "$HOME/started.pids"\n' > "$home/bin/CheTelegramBotMCP"
    chmod +x "$home/bin/CheTelegramBotMCP"
    if [ "$sidecar" != - ]; then printf '%s' "$sidecar" > "$home/bin/.CheTelegramBotMCP.version"; fi
    printf '#!/bin/bash\nexit 44\n' > "$home/fakebin/security"
    printf '#!/bin/bash\necho "$*" >> "$HOME/curl.calls"\nexit 1\n' > "$home/fakebin/curl"
    chmod +x "$home/fakebin/security" "$home/fakebin/curl"
}
run_bot() { HOME="$1" PATH="$1/fakebin:$PATH" bash "$BOT_WRAPPER" </dev/null >/dev/null 2>"$1/err"; }

test_case "bot: sidecar newer than the pin ($BOT_NEWER > $BOT_DESIRED)"
H="$SCRATCH/bot-newer"; make_bot_home "$H" "$BOT_NEWER"; run_bot "$H"
expect_no_download "$H" "newer"

test_case "bot: sidecar equal to the pin"
H="$SCRATCH/bot-equal"; make_bot_home "$H" "$BOT_DESIRED"; run_bot "$H"
expect_no_download "$H" "equal"

test_case "bot: sidecar older than the pin"
H="$SCRATCH/bot-older"; make_bot_home "$H" "$OLDER"; run_bot "$H"
expect_download "$H" "older"

test_case "bot: sidecar missing"
H="$SCRATCH/bot-missing"; make_bot_home "$H" -; run_bot "$H"
expect_download "$H" "missing"

test_case "bot: sidecar empty"
H="$SCRATCH/bot-empty"; make_bot_home "$H" ""; run_bot "$H"
expect_download "$H" "empty"

for bad in latest 0.8 "v$BOT_NEWER"; do
    test_case "bot: sidecar not x.y.z ('$bad')"
    H="$SCRATCH/bot-bad-$bad"; make_bot_home "$H" "$bad"; run_bot "$H"
    expect_download "$H" "'$bad'"
done

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
