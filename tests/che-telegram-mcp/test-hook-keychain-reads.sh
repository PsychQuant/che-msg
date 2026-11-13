#!/bin/bash
# The SessionStart hook checks the Keychain items without reading their
# values, and its fix-it hint says where to run it (PsychQuant/che-msg#49,
# verify round 1).
#
# The hook only needs to know whether TELEGRAM_API_ID, TELEGRAM_API_HASH,
# TELEGRAM_PHONE, TELEGRAM_2FA_PASSWORD and TELEGRAM_BOT_TOKEN exist. Reading
# them with -w fetched the 2FA password at every Claude Code start, and could
# show a Keychain unlock dialog; without -w, security reads the attributes only.
# The hook's output enters the conversation, so a hint that is a bare command
# could be run by the agent's own shell, which has no terminal to prompt in.
#
# Runs the hook against a private HOME with a fake `security` (records its
# arguments; has the API ID, hash and phone, not the 2FA password or the bot
# token) and a fake `curl` that fails, so nothing leaves the machine.
#
# Tests:
#   1. No security call passes -w (or -g).
#   2. The items that exist are reported, the missing required one gets a hint
#      that says to run it in your own terminal, and the hint ends with -w.
#
# Usage:
#   bash tests/che-telegram-mcp/test-hook-keychain-reads.sh
#   HOOK_UNDER_TEST=<copy> bash tests/che-telegram-mcp/test-hook-keychain-reads.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$ROOT/plugins/che-telegram-mcp/hooks/check-mcp.sh}"

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/hook-keychain-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

H="$SCRATCH/home"
mkdir -p "$H/fakebin"
{
    echo '#!/bin/bash'
    echo 'printf "%s\n" "$*" >> "$HOME/security.calls"'
    echo 'case "$*" in'
    echo '    *TELEGRAM_API_ID*|*TELEGRAM_API_HASH*|*TELEGRAM_PHONE*) echo "keychain: \"/fake\""; exit 0 ;;'
    echo '    *) exit 44 ;;'
    echo 'esac'
} > "$H/fakebin/security"
printf '#!/bin/bash\nexit 1\n' > "$H/fakebin/curl"
chmod +x "$H/fakebin/security" "$H/fakebin/curl"

OUT=$(HOME="$H" PATH="$H/fakebin:/usr/bin:/bin" bash "$HOOK" 2>&1)

test_case "no security call reads a value"
if [ ! -s "$H/security.calls" ]; then
    fail "the hook never called security"
elif grep -qE '(^| )-(w|g)( |$)' "$H/security.calls"; then
    fail "a call reads the value: $(grep -E '(^| )-(w|g)( |$)' "$H/security.calls" | head -2 | tr '\n' ';')"
else
    pass "$(wc -l < "$H/security.calls" | tr -d ' ') calls, none with -w or -g"
fi

test_case "items are reported, and the hint says where to run it"
case "$OUT" in *"API ID in Keychain"*) pass "an item that exists is reported" ;; *) fail "API ID not reported as present" ;; esac
HINT=$(printf '%s\n' "$OUT" | grep -A1 'Bot Token not in Keychain')
case "$HINT" in *"your own terminal"*) pass "the hint says to run it in your own terminal" ;; *) fail "no 'your own terminal' in: $HINT" ;; esac
case "$HINT" in *"TELEGRAM_BOT_TOKEN -U -w") pass "the hint ends with a bare -w" ;; *) fail "hint command: $HINT" ;; esac

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
