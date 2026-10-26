#!/bin/bash
# The SessionStart hook's upgrade notice compares versions the way the
# wrappers do (PsychQuant/che-msg#89).
#
# notify_if_outdated compared the version record with releases/latest using
# `!=` after removing every whitespace character, so a record newer than the
# latest release (kept by the wrappers since #83) printed an "upgrade" arrow
# pointing at an older version, and so did `0.8.0-beta` and `0. 9.0`.
#
# Runs the hook against a private HOME with a fake `curl` (returns a fixed
# tag_name) and a fake `security`, so nothing leaves the machine.
#
# Usage:
#   bash tests/che-telegram-mcp/test-hook-version-notice.sh
#   HOOK_UNDER_TEST=<copy> bash tests/che-telegram-mcp/test-hook-version-notice.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$ROOT/plugins/che-telegram-mcp/hooks/check-mcp.sh}"

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/hook-version-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

H="$SCRATCH/home"
mkdir -p "$H/bin" "$H/fakebin"
printf '#!/bin/bash\nprintf "  \\"tag_name\\": \\"%%s\\",\\n" "${FAKE_TAG:-v0.8.0}"\n' > "$H/fakebin/curl"
printf '#!/bin/bash\nexit 44\n' > "$H/fakebin/security"
chmod +x "$H/fakebin/curl" "$H/fakebin/security"

# check <name> <record (printf %b)> <tag> <expected: older|none|newer|malformed> [server]
# server: telegram-all (default) or telegram-bot; only that server's record is written.
check() {
    local name="$1" record="$2" tag="$3" want="$4" label="${5:-telegram-all}" out line ok
    local bin=CheTelegramAllMCP; [ "$label" = telegram-bot ] && bin=CheTelegramBotMCP
    TOTAL=$((TOTAL + 1))
    rm -f "$H/bin/".*.version
    printf '%b' "$record" > "$H/bin/.$bin.version"
    out=$(HOME="$H" FAKE_TAG="$tag" PATH="$H/fakebin:/usr/bin:/bin" bash "$HOOK" 2>&1)
    if [[ "$out" != *"── Telegram MCP Status ──"* ]]; then fail "$name (the hook did not run: ${out:0:80})"; return; fi
    # The version notices are the lines naming "<server> v<version>" or "<server>:".
    line=$(printf '%s\n' "$out" | grep -E "$label( v[0-9]|:)" | grep -v '^✓' || true)
    if [ "$want" != none ] && [ "$(printf '%s\n' "$line" | grep -c .)" -ne 1 ]; then
        fail "$name (expected one notice line, got: ${line:-nothing})"; return
    fi
    case "$want" in
        older)     [[ "$line" == "⬆️  $label v"*" → ${tag} available"* ]] ;;
        none)      [[ -z "$line" ]] ;;
        newer)     [[ "$line" == *"newer than the latest release ${tag}"* && "$line" != *"⬆"* ]] ;;
        malformed) [[ "$line" == *"version record"*"not a plain"* && "$line" != *"⬆"* ]] ;;
        *)         false ;;
    esac && ok=1 || ok=0
    # The ✓ line shows a version only when the record is one.
    if [ "$want" = malformed ] && printf '%s\n' "$out" | grep -qE "^✓ $label( \([A-Za-z]+\))? v"; then ok=0; line="$line / ✓ line shows a version"; fi
    if [ "$ok" = 1 ]; then pass "$name"; else fail "$name (got: ${line:-nothing})"; fi
}
# A stub binary in ~/bin, so check_binary prints its ✓ line with the record.
printf '#!/bin/bash\n' > "$H/bin/CheTelegramAllMCP"; cp "$H/bin/CheTelegramAllMCP" "$H/bin/CheTelegramBotMCP"
chmod +x "$H/bin/CheTelegramAllMCP" "$H/bin/CheTelegramBotMCP"

check "an older record gets the upgrade arrow"          '0.7.0\n'      v0.8.0 older
check "the same version prints nothing"                  '0.8.0\n'      v0.8.0 none
check "a newer record is reported as newer, no arrow"    '0.9.0\n'      v0.8.0 newer
check "a two-digit minor compares as a number"           '0.10.0\n'     v0.9.0 newer
check "surrounding whitespace and CRLF are ignored"      '  0.8.0\r\n'  v0.8.0 none
check "a pre-release suffix is not compared"             '0.8.0-beta\n' v0.8.0 malformed
check "whitespace inside the record is not removed"      '0. 9.0\n'     v0.8.0 malformed
check "a release tag that is not x.y.z keeps it quiet"   '0.7.0\n'      vnext  none
check "1.0.0 is newer than 0.99.99"                      '1.0.0\n'      v0.99.99 newer
check "0.99.99 is older than 1.0.0"                      '0.99.99\n'    v1.0.0 older
check "an empty record is reported"                      ''             v0.8.0 malformed
check "a whitespace-only record is reported"             '  \n\n'       v0.8.0 malformed
check "a two-line record is reported"                    '0.8.0\n0.9.0\n' v0.8.0 malformed
check "a malformed record is reported even offline"      '0.8.0-beta\n' vnext  malformed
check "the bot's newer record is reported as newer"      '0.9.0\n'      v0.8.0 newer telegram-bot

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
