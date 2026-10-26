#!/bin/bash
# Sign a binary with a Developer ID and hardened runtime, then notarize it
# (PsychQuant/che-msg#40). Adapted from che-mcps' che-ical-mcp
# scripts/sign-and-notarize.sh; the calendar entitlement gate is replaced by
# checks of the signed result (hardened runtime, Developer ID authority, the
# exact entitlements), and --sign-only signs without notarizing.
#
# Stapling is not possible: stapler does not support raw Mach-O binaries.
# Gatekeeper checks the notarization online when the binary first runs.
#
# Usage:
#   scripts/release/sign-and-notarize.sh [--sign-only] <path/to/binary>
#   scripts/release/sign-and-notarize.sh --preflight [--sign-only]
#
#   --sign-only   sign and verify locally; NOTARY_PROFILE is not needed, nothing
#                 is submitted for notarization and the binary is not uploaded.
#                 codesign still asks Apple's timestamp service for a secure
#                 timestamp (only the signature's digest is sent), so it needs
#                 the network, as a release does.
#   --preflight   only check that signing (and, without --sign-only,
#                 notarizing) is set up; build-release.sh runs this before
#                 building anything
#
# Environment (no defaults, so nothing about one maintainer is baked in):
#   DEVELOPER_ID    codesigning identity: its name, e.g. "Developer ID Application:
#                   Name (TEAMID)", or its SHA-1 hash
#   NOTARY_PROFILE  notarytool keychain profile (full mode only)
#   SPCTL_TIMEOUT_SECONDS  how long the final spctl check may take (default 60)
#
# The entitlements are always scripts/release/Entitlements.plist. They are not
# taken from the environment: che-mcps' scripts read ENTITLEMENTS too, and a
# value left over from one of their releases must not end up in these binaries.

set -euo pipefail

SIGN_ONLY=0
PREFLIGHT=0
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --sign-only) SIGN_ONLY=1 ;;
        --preflight) PREFLIGHT=1 ;;
        *) echo "Error: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
if [[ "$PREFLIGHT" == 1 ]]; then
    BINARY=""
else
    BINARY="${1:?Usage: $0 [--sign-only] <path/to/binary> | $0 --preflight [--sign-only]}"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/Entitlements.plist"

# Every check below runs before codesign, so a missing prerequisite fails in
# seconds instead of after a build or halfway through a notarization.
if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi
TOOLS=(codesign security file plutil python3)
[[ "$SIGN_ONLY" == 0 ]] && TOOLS+=(ditto spctl perl)
for tool in "${TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Error: $tool not found." >&2; exit 1; }
done
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    echo "Error: DEVELOPER_ID is not set." >&2
    echo "       export DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)'" >&2
    echo "       Available identities: security find-identity -p codesigning -v" >&2
    exit 1
fi
if [[ "$SIGN_ONLY" == 0 && -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Error: NOTARY_PROFILE is not set." >&2
    echo "       export NOTARY_PROFILE='your-profile-name'" >&2
    echo "       One-time setup: xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team-id>" >&2
    echo "       (notarytool prompts for the app-specific password; never pass it on the command line)" >&2
    exit 1
fi
SPCTL_TIMEOUT_SECONDS="${SPCTL_TIMEOUT_SECONDS:-60}"
if [[ "$SIGN_ONLY" == 0 ]] && ! [[ "$SPCTL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: SPCTL_TIMEOUT_SECONDS must be a positive integer (got '$SPCTL_TIMEOUT_SECONDS')." >&2
    exit 1
fi
if [[ "$PREFLIGHT" == 0 && ! -f "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY" >&2
    exit 1
fi
# -b: without it the output starts with the path, which may itself contain "Mach-O".
if [[ "$PREFLIGHT" == 0 ]] && ! file -b "$BINARY" 2>/dev/null | grep -q "^Mach-O"; then
    echo "Error: $BINARY is not a Mach-O binary ($(file -b "$BINARY" 2>&1))." >&2
    exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]] || ! plutil -lint -s "$ENTITLEMENTS" >/dev/null 2>&1; then
    echo "Error: $ENTITLEMENTS is missing or not a valid plist." >&2
    exit 1
fi
# DEVELOPER_ID is the identity's name or its SHA-1 hash (any case), matched
# against the identity lines ("  1) <hash> "<name>"") only, so a fragment of a
# name or a word from the summary line is refused. The identity must be a
# Developer ID Application one: notarization rejects anything else, and finding
# out after a build or a signature wastes the run.
IDENTITY_TYPE=$(security find-identity -p codesigning -v 2>/dev/null | awk -v id="$DEVELOPER_ID" '
    $1 ~ /^[0-9]+\)$/ && length($2) == 40 && $2 ~ /^[0-9A-F]+$/ {
        name = $0; sub(/^[^"]*"/, "", name); sub(/"[^"]*$/, "", name)
        if (toupper(id) == $2 || id == name) {
            result = (index(name, "Developer ID Application: ") == 1) ? "developer-id" : "other"
            if (result == "developer-id") { print result; exit }
        }
    }
    END { if (result == "other") print result }')
case "$IDENTITY_TYPE" in
    developer-id) ;;
    other)
        echo "Error: $DEVELOPER_ID is not a Developer ID Application identity; notarization would reject it." >&2
        exit 1 ;;
    *)
        echo "Error: codesigning identity not found in the keychain: $DEVELOPER_ID" >&2
        echo "       Available identities:" >&2
        security find-identity -p codesigning -v 2>&1 | grep -E '"[^"]*"' | sed 's/^/         /' >&2 || true
        exit 1 ;;
esac
if [[ "$SIGN_ONLY" == 0 ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Error: notarytool keychain profile '$NOTARY_PROFILE' is not configured or cannot be used." >&2
    echo "       Set up with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team-id>" >&2
    exit 1
fi
if [[ "$PREFLIGHT" == 1 ]]; then
    [[ "$SIGN_ONLY" == 1 ]] && echo "Signing is set up (Developer ID identity found)." || echo "Signing and notarizing are set up (Developer ID identity and notarytool profile found)."
    exit 0
fi

# The notarization's zip and log live in a private directory under TMPDIR
# (mktemp -t would ignore TMPDIR on macOS and leave a file behind each run).
WORK_DIR=""
cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

STEPS=5; [[ "$SIGN_ONLY" == 1 ]] && STEPS=3
echo "=== sign-and-notarize: $BINARY ==="
echo "  Identity:      $DEVELOPER_ID"
if [[ "$SIGN_ONLY" == 1 ]]; then
    echo "  Mode:          sign only (no notarization; codesign still fetches a timestamp from Apple)"
else
    echo "  Profile:       $NOTARY_PROFILE"
fi
echo "  Entitlements:  $ENTITLEMENTS"
echo ""

# A secure timestamp is required for notarization; asking for it explicitly
# does not depend on codesign's default for the identity.
echo "[1/$STEPS] Signing with Developer ID, hardened runtime and a secure timestamp..."
codesign --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID" \
    "$BINARY"

echo ""
echo "[2/$STEPS] Verifying the signature..."
VERIFY_OUTPUT="$(codesign --verify --strict --verbose=2 "$BINARY" 2>&1)"
printf '%s\n' "$VERIFY_OUTPUT" | head -5

# Check the signed result itself, so a wrong signing call fails here and not
# at Apple: notarization needs hardened runtime and a Developer ID authority,
# and the binary must carry exactly the repository's entitlements.
echo ""
echo "[3/$STEPS] Checking the signed binary..."
SIGNATURE="$(codesign -dv --verbose=2 "$BINARY" 2>&1 || true)"
if ! printf '%s\n' "$SIGNATURE" | grep -qE '^CodeDirectory .*flags=0x[0-9a-f]*\([^)]*runtime'; then
    echo "Error: the signed binary does not have the hardened-runtime flag." >&2
    printf '%s\n' "$SIGNATURE" | grep -E '^(CodeDirectory|Authority|TeamIdentifier)' | sed 's/^/         /' >&2 || true
    exit 1
fi
if ! printf '%s\n' "$SIGNATURE" | grep -q '^Authority=Developer ID Application: '; then
    echo "Error: the signed binary is not signed by a Developer ID Application certificate." >&2
    exit 1
fi
# A SHA-1 hash cannot be compared with the authority's name; a name can.
if ! [[ "$DEVELOPER_ID" =~ ^[0-9A-Fa-f]{40}$ ]] && ! printf '%s\n' "$SIGNATURE" | grep -qxF "Authority=$DEVELOPER_ID"; then
    echo "Error: the signed binary's authority is not $DEVELOPER_ID." >&2
    exit 1
fi
if ! codesign -d --entitlements - --xml "$BINARY" 2>/dev/null | python3 -I -c '
import plistlib, sys
signed = sys.stdin.buffer.read()
got = plistlib.loads(signed) if signed.strip() else {}
want = plistlib.load(open(sys.argv[1], "rb"))
sys.exit(0 if got == want else 1)' "$ENTITLEMENTS"; then
    echo "Error: the signed binary's entitlements are not those in $ENTITLEMENTS." >&2
    exit 1
fi
printf '%s\n' "$SIGNATURE" | grep -E '^(Authority=Developer ID|TeamIdentifier|CodeDirectory)' | sed 's/^/  /' || true
echo "  entitlements: as in $(basename "$ENTITLEMENTS")"

if [[ "$SIGN_ONLY" == 1 ]]; then
    echo ""
    echo "=== sign-and-notarize: signed (not notarized) ==="
    exit 0
fi

echo ""
echo "[4/$STEPS] Submitting for notarization (usually 1-15 minutes)..."
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notarize.XXXXXX")"
ZIP_PATH="$WORK_DIR/$(basename "$BINARY").zip"
SUBMIT_LOG="$WORK_DIR/submit.log"
ditto -c -k --keepParent "$BINARY" "$ZIP_PATH"

# The submission ID is the only handle on Apple's rejection log.
extract_submission_id() {
    grep -m1 -E '^[[:space:]]*id:' "$1" 2>/dev/null | awk '{print $2}' || true
}
if ! xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$SUBMIT_LOG"; then
    SUBMISSION_ID="$(extract_submission_id "$SUBMIT_LOG")"
    echo "" >&2
    echo "Error: notarization failed." >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
        echo "       Apple's reason: xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE" >&2
    else
        echo "       No submission ID captured; see: xcrun notarytool history --keychain-profile $NOTARY_PROFILE" >&2
    fi
    exit 1
fi
SUBMISSION_ID="$(extract_submission_id "$SUBMIT_LOG")"
echo "Submission ID: ${SUBMISSION_ID:-(not captured)}"

# notarytool's exit 0 does not prove Gatekeeper will accept the binary;
# spctl is the check users' machines effectively make. -t install, because raw
# Mach-O binaries fall through the .app check under -t execute. perl's alarm
# keeps a stalled OCSP lookup from hanging the release. Success needs both the
# "accepted" verdict and the notarized source; spctl's exit status for a raw
# Mach-O has not been observed on a real release yet, so it is printed, not
# relied on.
echo ""
echo "[5/$STEPS] Checking the notarization with spctl..."
SPCTL_EXIT=0
SPCTL_OUTPUT="$(perl -e 'my $t=shift; alarm $t; exec @ARGV or die "exec failed: $!"' \
    -- "$SPCTL_TIMEOUT_SECONDS" spctl -a -vvv -t install "$BINARY" 2>&1)" || SPCTL_EXIT=$?
if [[ "$SPCTL_EXIT" -eq 142 ]]; then
    echo "Error: spctl timed out after ${SPCTL_TIMEOUT_SECONDS}s; Apple's OCSP servers are unreachable or slow." >&2
    echo "       Retry when the network is back, or set SPCTL_TIMEOUT_SECONDS higher." >&2
    exit 1
fi
if ! printf '%s\n' "$SPCTL_OUTPUT" | grep -qE ': accepted$' ||
   ! printf '%s\n' "$SPCTL_OUTPUT" | grep -qx "source=Notarized Developer ID"; then
    echo "Error: spctl does not accept $BINARY as notarized (exit $SPCTL_EXIT)." >&2
    printf '%s\n' "$SPCTL_OUTPUT" | sed 's/^/         /' >&2
    echo "       Apple's log: xcrun notarytool log ${SUBMISSION_ID:-<id>} --keychain-profile $NOTARY_PROFILE" >&2
    echo "       Right after a notarization this can be Apple's records not having propagated yet (RELEASING.md)." >&2
    exit 1
fi
echo "  ✓ spctl accepts it as Notarized Developer ID (spctl exit $SPCTL_EXIT)"

echo ""
echo "=== sign-and-notarize: signed and notarized ==="
echo "Stapling skipped (raw Mach-O); Gatekeeper checks online on first launch."
