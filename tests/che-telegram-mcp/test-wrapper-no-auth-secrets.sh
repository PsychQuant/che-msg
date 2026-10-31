#!/bin/bash
# The che-telegram-all-mcp wrapper never passes the phone number or the 2FA
# password to the server (PsychQuant/che-msg#49). The binary reads them from
# the Keychain itself, only while TDLib waits for them; exporting them would
# put the 2FA password in a long-running process's environment, readable by
# the user's other processes (the rejected "fix 1" of #49).
#
# Runs the real wrapper against a private HOME (tests/lib/wrapper_harness.sh)
# with a fake `security` that has all four items.
#
# Tests:
#   1. The server's environment has TELEGRAM_API_ID and TELEGRAM_API_HASH and
#      neither TELEGRAM_PHONE nor TELEGRAM_2FA_PASSWORD.
#   2. The wrapper does not even read the phone or 2FA items from the Keychain.
#   3. Neither value appears in anything the wrapper writes.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-no-auth-secrets.sh
#   WRAPPER_UNDER_TEST=<copy> bash tests/che-telegram-mcp/test-wrapper-no-auth-secrets.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/wrapper_harness.sh"

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-secrets-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
STARTED=()
finish() {
    for pid in "${STARTED[@]+"${STARTED[@]}"}"; do kill -KILL "$pid" 2>/dev/null; done
    rm -rf "$SCRATCH"
}
trap finish EXIT

PHONE="+10000000000"
PASSWORD="fake-2fa-password"
H="$SCRATCH/home"; make_home "$H"

# A Keychain with all four items; every lookup is recorded.
{
    echo '#!/bin/bash'
    echo 'echo "$*" >> "$HOME/security.calls"'
    echo 'case "$*" in'
    echo '    *TELEGRAM_API_ID*) echo 12345 ;;'
    echo '    *TELEGRAM_API_HASH*) echo fakehash ;;'
    echo "    *TELEGRAM_PHONE*) echo '$PHONE' ;;"
    echo "    *TELEGRAM_2FA_PASSWORD*) echo '$PASSWORD' ;;"
    echo '    *) exit 44 ;;'
    echo 'esac'
} > "$H/fakebin/security"
chmod +x "$H/fakebin/security"

# A server that records the names of the TELEGRAM_* variables it was given.
{
    echo '#!/bin/bash'
    echo "if [ \"\$1\" = --version ]; then echo 'che-telegram-all-mcp $DESIRED_VERSION'; exit 0; fi"
    echo 'env | sed -n "s/^\(TELEGRAM_[A-Z0-9_]*\)=.*/\1/p" | LC_ALL=C sort > "$HOME/env.names.tmp"'
    echo 'mv "$HOME/env.names.tmp" "$HOME/env.names"'
    echo 'echo $$ >> "$HOME/started.pids"'
    echo 'exec /bin/sleep 300'
} > "$H/bin/CheTelegramAllMCP"
chmod +x "$H/bin/CheTelegramAllMCP"

printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' > "$H/in"
W=$(start_wrapper "$H" "$H/in" "$H/out"); STARTED+=("$W")
wait_until 10 test -f "$H/env.names"
if [ -f "$H/started.pids" ]; then
    while read -r pid; do STARTED+=("$pid"); done < "$H/started.pids"
fi
stop "$W"

# ----------------------------------------------------------------------
test_case "The server gets the API credentials and nothing else"
if [ ! -f "$H/env.names" ]; then
    fail "the server never started (wrapper stderr: $(head -c 300 "$H/wrapper.stderr" 2>/dev/null))"
else
    NAMES=$(tr '\n' ' ' < "$H/env.names")
    if [ "$NAMES" = "TELEGRAM_API_HASH TELEGRAM_API_ID " ]; then
        pass "only TELEGRAM_API_HASH and TELEGRAM_API_ID"
    else
        fail "the server's TELEGRAM_* variables were: $NAMES"
    fi
fi

# ----------------------------------------------------------------------
test_case "The wrapper does not read the phone or 2FA items"
if grep -qE 'TELEGRAM_PHONE|TELEGRAM_2FA_PASSWORD' "$H/security.calls" 2>/dev/null; then
    fail "the wrapper looked them up: $(grep -E 'TELEGRAM_PHONE|TELEGRAM_2FA_PASSWORD' "$H/security.calls" | head -2 | tr '\n' ';')"
else
    pass "no lookup of TELEGRAM_PHONE or TELEGRAM_2FA_PASSWORD"
fi

# ----------------------------------------------------------------------
test_case "Neither value appears in the wrapper's output"
if grep -qF -e "$PHONE" -e "$PASSWORD" "$H/out" "$H/wrapper.stderr" 2>/dev/null; then
    fail "a value was written to stdout or stderr"
else
    pass "stdout and stderr contain neither value"
fi

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
