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

# case <name> <record (printf %b)> <tag> <expected: older|none|newer|malformed>
check() {
    local name="$1" record="$2" tag="$3" want="$4" out line
    TOTAL=$((TOTAL + 1))
    printf '%b' "$record" > "$H/bin/.CheTelegramAllMCP.version"
    out=$(HOME="$H" FAKE_TAG="$tag" PATH="$H/fakebin:/usr/bin:/bin" bash "$HOOK" 2>&1)
    # The version notices are the lines naming "telegram-all v<version>" or "telegram-all:".
    line=$(printf '%s\n' "$out" | grep -E 'telegram-all( v[0-9]|:)' || true)
    case "$want" in
        older)     [[ "$line" == "⬆️  telegram-all v"*" → ${tag} available"* ]] ;;
        none)      [[ -z "$line" ]] ;;
        newer)     [[ "$line" == *"newer than the latest release ${tag}"* && "$line" != *"⬆"* ]] ;;
        malformed) [[ "$line" == *"version record"*"not a plain"* && "$line" != *"⬆"* ]] ;;
    esac && pass "$name" || fail "$name (got: ${line:-nothing})"
}

check "an older record gets the upgrade arrow"          '0.7.0\n'      v0.8.0 older
check "the same version prints nothing"                  '0.8.0\n'      v0.8.0 none
check "a newer record is reported as newer, no arrow"    '0.9.0\n'      v0.8.0 newer
check "a two-digit minor compares as a number"           '0.10.0\n'     v0.9.0 newer
check "surrounding whitespace and CRLF are ignored"      '  0.8.0\r\n'  v0.8.0 none
check "a pre-release suffix is not compared"             '0.8.0-beta\n' v0.8.0 malformed
check "whitespace inside the record is not removed"      '0. 9.0\n'     v0.8.0 malformed
check "a release tag that is not x.y.z keeps it quiet"   '0.7.0\n'      vnext  none

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
