#!/bin/bash
# When the che-telegram-mcp wrappers download a binary (PsychQuant/che-msg#83).
#
# Each wrapper pins DESIRED_VERSION and reads the installed version from the
# record ~/bin/.<Binary>.version. With no binary installed it downloads. Once a
# binary is installed in ~/bin, it downloads only when the record is missing,
# is not a plain x.y.z, or is older than the pin; it never replaces a binary
# that is newer than its pin, and never touches a binary outside ~/bin. Before
# #83 it downloaded on any difference, so a session still running an older
# plugin put the older binary back over a newer one.
#
# Runs both real wrappers against private HOMEs with a fake `curl` that records
# its calls and fails, and a fake `security`; nothing outside the scratch
# directory is read or written, and nothing reaches the network.
#
# Tests:
#   1. version_at_least, loaded from each wrapper's own source: multi-digit
#      ordering (0.10.0 vs 0.9.0, 0.8.10 vs 0.8.9, 10.0.0 vs 9.9.9) and both
#      regex anchors (1.0.0-rc1, x1.0.0).
#   For each wrapper:
#   2. Record newer than the pin: no download; the installed binary starts.
#   3. Record equal to the pin: no download.
#   4. Record older than the pin: a download attempt.
#   5. Record missing, empty, or not x.y.z ("latest", "0.8", "v<newer>"): a
#      download attempt, and the reason says the record is not x.y.z.
#   6. Record with whitespace inside or on several lines ("1. 0.0", "1." /
#      "0.0", "1.0.0" / "1"): a download attempt — not read as a version.
#   7. Record with CR or surrounding whitespace around a newer version: read as
#      that version, no download.
#   8. A wrapper pinned 0.9.0 with record 0.10.0 (a copy of the real wrapper):
#      no download.
#   9. A binary outside ~/bin with an older record: never downloaded over.
#   And for telegram-all:
#  10. Newer record next to a binary that fails the minimum-version probe: the
#      wrapper refuses it and the message gives the recorded version, not the
#      pin.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-version-decision.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/wrapper_harness.sh"

ALL_WRAPPER="$WRAPPER"
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

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-version-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
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
expect_started() {
    if has_pids "$1" 1; then pass "$2: the installed binary was started"; else fail "$2: the installed binary was not started: $(tail -3 "$1/wrapper.stderr" "$1/err" 2>/dev/null | tr '\n' ' ')"; fi
}
expect_reason_not_xyz() {
    if grep -q 'not x\.y\.z' "$1/wrapper.stderr" "$1/err" 2>/dev/null; then pass "$2: the reason says the record is not x.y.z"
    else fail "$2: the reason does not say the record is not x.y.z: $(grep -h 'downloading' "$1/wrapper.stderr" "$1/err" 2>/dev/null | head -1)"; fi
}

# expect_vat <version> <minimum> <yes|no> <label>: whether version_at_least holds.
expect_vat() {
    local got=no
    if version_at_least "$1" "$2"; then got=yes; fi
    if [ "$got" = "$3" ]; then pass "$4"; else fail "$4 (version_at_least $1 $2 gave $got)"; fi
}

# pinned_copy <wrapper> <pin> <dest>: the real wrapper with DESIRED_VERSION replaced.
pinned_copy() { sed "s/^DESIRED_VERSION=\".*\"$/DESIRED_VERSION=\"$2\"/" "$1" > "$3"; }

# ---------------------------------------------------------- version_at_least
for pair in "telegram-all:$ALL_WRAPPER" "bot:$BOT_WRAPPER"; do
    label=${pair%%:*}; path=${pair#*:}
    test_case "$label: version_at_least orders multi-digit components and anchors the pattern"
    unset -f version_at_least 2>/dev/null
    eval "$(sed -n '/^version_at_least() {/,/^}/p' "$path")"
    if ! declare -f version_at_least >/dev/null; then fail "version_at_least not found in $label wrapper"; continue; fi
    expect_vat 0.10.0 0.9.0 yes "0.10.0 is not older than 0.9.0"
    expect_vat 0.9.0 0.10.0 no  "0.9.0 is older than 0.10.0"
    expect_vat 0.8.10 0.8.9 yes "0.8.10 is not older than 0.8.9"
    expect_vat 0.8.9 0.8.10 no  "0.8.9 is older than 0.8.10"
    expect_vat 10.0.0 9.9.9 yes "10.0.0 is not older than 9.9.9"
    expect_vat 1.0.0-rc1 0.8.0 no "1.0.0-rc1 is not x.y.z"
    expect_vat x1.0.0 0.8.0 no  "x1.0.0 is not x.y.z"
    unset -f version_at_least
done

# ---------------------------------------------------------------- telegram-all
ALL_NEWER=$(newer_than "$DESIRED_VERSION")
ALL_MAJOR=${ALL_NEWER%%.*}

# run_all <home> <record content | "-" to remove it>: runs the wrapper and
# stops it once it has either started the binary or exited.
run_all() {
    local home=$1 record=$2 w
    if [ "$record" = - ]; then rm -f "$home/bin/.CheTelegramAllMCP.version"
    else printf '%s' "$record" > "$home/bin/.CheTelegramAllMCP.version"; fi
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' > "$home/in"
    w=$(start_wrapper "$home" "$home/in" "$home/out"); STARTED+=("$w")
    wait_until 10 bash -c "[ -s '$home/started.pids' ] || ! kill -0 $w 2>/dev/null" || true
    stop "$w"
}

test_case "telegram-all: record newer than the pin ($ALL_NEWER > $DESIRED_VERSION)"
H="$SCRATCH/all-newer"; make_home "$H" yes "$ALL_NEWER"; run_all "$H" "$ALL_NEWER"
expect_no_download "$H" "newer"; expect_started "$H" "newer"

test_case "telegram-all: record equal to the pin"
H="$SCRATCH/all-equal"; make_home "$H" yes "$DESIRED_VERSION"; run_all "$H" "$DESIRED_VERSION"
expect_no_download "$H" "equal"

test_case "telegram-all: record older than the pin"
H="$SCRATCH/all-older"; make_home "$H" yes "$OLDER"; run_all "$H" "$OLDER"
expect_download "$H" "older"

test_case "telegram-all: record missing"
H="$SCRATCH/all-missing"; make_home "$H" yes "$DESIRED_VERSION"; run_all "$H" -
expect_download "$H" "missing"; expect_reason_not_xyz "$H" "missing"

test_case "telegram-all: record empty"
H="$SCRATCH/all-empty"; make_home "$H" yes "$DESIRED_VERSION"; run_all "$H" ""
expect_download "$H" "empty"

i=0
for bad in latest 0.8 "v$ALL_NEWER"; do
    i=$((i + 1))
    test_case "telegram-all: record not x.y.z ('$bad')"
    H="$SCRATCH/all-bad-$i"; make_home "$H" yes "$DESIRED_VERSION"; run_all "$H" "$bad"
    expect_download "$H" "'$bad'"; expect_reason_not_xyz "$H" "'$bad'"
done

i=0
for bad in "$ALL_MAJOR. 0.0" "$ALL_MAJOR."$'\n'"0.0" "$ALL_NEWER"$'\n'"1"; do
    i=$((i + 1))
    test_case "telegram-all: record with inner whitespace or several lines (case $i)"
    H="$SCRATCH/all-inner-$i"; make_home "$H" yes "$DESIRED_VERSION"; run_all "$H" "$bad"
    expect_download "$H" "inner whitespace $i"
done

i=0
for padded in "$ALL_NEWER"$'\r\n' "  $ALL_NEWER "$'\n' $'\n'"$ALL_NEWER"$'\n\n'; do
    i=$((i + 1))
    test_case "telegram-all: newer record with CR or surrounding whitespace (case $i)"
    H="$SCRATCH/all-padded-$i"; make_home "$H" yes "$ALL_NEWER"; run_all "$H" "$padded"
    expect_no_download "$H" "padded $i"; expect_started "$H" "padded $i"
done

test_case "telegram-all: pinned 0.9.0 with record 0.10.0"
H="$SCRATCH/all-pin090"; make_home "$H" yes 0.10.0
pinned_copy "$ALL_WRAPPER" 0.9.0 "$SCRATCH/all-pin090.sh"
WRAPPER="$SCRATCH/all-pin090.sh"; run_all "$H" 0.10.0; WRAPPER="$ALL_WRAPPER"
expect_no_download "$H" "0.10.0 vs pin 0.9.0"; expect_started "$H" "0.10.0 vs pin 0.9.0"

test_case "telegram-all: a binary outside ~/bin with an older record is not downloaded over"
H="$SCRATCH/all-outside"; make_home "$H" yes "$ALL_NEWER"
mkdir -p "$H/.local/bin"; mv "$H/bin/CheTelegramAllMCP" "$H/.local/bin/CheTelegramAllMCP"
run_all "$H" "$OLDER"
expect_no_download "$H" "outside ~/bin"; expect_started "$H" "outside ~/bin"

test_case "telegram-all: newer record, binary fails the minimum-version probe"
H="$SCRATCH/all-newer-silent"; make_home "$H" yes silent
echo "$ALL_NEWER" > "$H/bin/.CheTelegramAllMCP.version"
printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"initialize","params":{}}' > "$H/in"
HOME="$H" PATH="$H/fakebin:$PATH" bash "$ALL_WRAPPER" < "$H/in" > "$H/out" 2> "$H/err"
RC=$?
if [ "$RC" -eq 1 ]; then pass "exit status 1 (refused)"; else fail "exit status $RC"; fi
expect_no_download "$H" "newer record"
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
BOT_MAJOR=${BOT_NEWER%%.*}

# make_bot_home <dir> <record content | "-">: an installed fake bot binary that
# records its start, a `security` that returns a bot token, and the recording,
# failing `curl`.
make_bot_home() {
    local home=$1 record=$2
    mkdir -p "$home/bin" "$home/fakebin"
    printf '#!/bin/bash\necho $$ >> "$HOME/started.pids"\n' > "$home/bin/CheTelegramBotMCP"
    chmod +x "$home/bin/CheTelegramBotMCP"
    if [ "$record" != - ]; then printf '%s' "$record" > "$home/bin/.CheTelegramBotMCP.version"; fi
    printf '#!/bin/bash\ncase "$*" in *TELEGRAM_BOT_TOKEN*) echo 123:faketoken ;; *) exit 44 ;; esac\n' > "$home/fakebin/security"
    printf '#!/bin/bash\necho "$*" >> "$HOME/curl.calls"\nexit 1\n' > "$home/fakebin/curl"
    chmod +x "$home/fakebin/security" "$home/fakebin/curl"
}
run_bot() { HOME="$1" PATH="$1/fakebin:$PATH" bash "${2:-$BOT_WRAPPER}" </dev/null >/dev/null 2>"$1/err"; }

test_case "bot: record newer than the pin ($BOT_NEWER > $BOT_DESIRED)"
H="$SCRATCH/bot-newer"; make_bot_home "$H" "$BOT_NEWER"; run_bot "$H"
expect_no_download "$H" "newer"; expect_started "$H" "newer"

test_case "bot: record equal to the pin"
H="$SCRATCH/bot-equal"; make_bot_home "$H" "$BOT_DESIRED"; run_bot "$H"
expect_no_download "$H" "equal"; expect_started "$H" "equal"

test_case "bot: record older than the pin"
H="$SCRATCH/bot-older"; make_bot_home "$H" "$OLDER"; run_bot "$H"
expect_download "$H" "older"

test_case "bot: record missing"
H="$SCRATCH/bot-missing"; make_bot_home "$H" -; run_bot "$H"
expect_download "$H" "missing"; expect_reason_not_xyz "$H" "missing"

test_case "bot: record empty"
H="$SCRATCH/bot-empty"; make_bot_home "$H" ""; run_bot "$H"
expect_download "$H" "empty"

i=0
for bad in latest 0.8 "v$BOT_NEWER"; do
    i=$((i + 1))
    test_case "bot: record not x.y.z ('$bad')"
    H="$SCRATCH/bot-bad-$i"; make_bot_home "$H" "$bad"; run_bot "$H"
    expect_download "$H" "'$bad'"; expect_reason_not_xyz "$H" "'$bad'"
done

i=0
for bad in "$BOT_MAJOR. 0.0" "$BOT_MAJOR."$'\n'"0.0" "$BOT_NEWER"$'\n'"1"; do
    i=$((i + 1))
    test_case "bot: record with inner whitespace or several lines (case $i)"
    H="$SCRATCH/bot-inner-$i"; make_bot_home "$H" "$bad"; run_bot "$H"
    expect_download "$H" "inner whitespace $i"
done

i=0
for padded in "$BOT_NEWER"$'\r\n' "  $BOT_NEWER "$'\n' $'\n'"$BOT_NEWER"$'\n\n'; do
    i=$((i + 1))
    test_case "bot: newer record with CR or surrounding whitespace (case $i)"
    H="$SCRATCH/bot-padded-$i"; make_bot_home "$H" "$padded"; run_bot "$H"
    expect_no_download "$H" "padded $i"; expect_started "$H" "padded $i"
done

test_case "bot: pinned 0.9.0 with record 0.10.0"
H="$SCRATCH/bot-pin090"; make_bot_home "$H" 0.10.0
pinned_copy "$BOT_WRAPPER" 0.9.0 "$SCRATCH/bot-pin090.sh"; run_bot "$H" "$SCRATCH/bot-pin090.sh"
expect_no_download "$H" "0.10.0 vs pin 0.9.0"; expect_started "$H" "0.10.0 vs pin 0.9.0"

test_case "bot: a binary outside ~/bin with an older record is not downloaded over"
H="$SCRATCH/bot-outside"; make_bot_home "$H" "$OLDER"
mkdir -p "$H/.local/bin"; mv "$H/bin/CheTelegramBotMCP" "$H/.local/bin/CheTelegramBotMCP"; run_bot "$H"
expect_no_download "$H" "outside ~/bin"; expect_started "$H" "outside ~/bin"

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
