#!/bin/bash
# Sign a binary with a Developer ID and hardened runtime, then notarize it
# (PsychQuant/che-msg#40). Adapted from che-mcps' che-ical-mcp
# scripts/sign-and-notarize.sh; the calendar entitlement gate is replaced by a
# hardened-runtime check, and --sign-only signs without uploading anything.
#
# Stapling is not possible: stapler does not support raw Mach-O binaries.
# Gatekeeper checks the notarization online when the binary first runs.
#
# Usage:
#   scripts/release/sign-and-notarize.sh [--sign-only] <path/to/binary>
#   scripts/release/sign-and-notarize.sh --preflight [--sign-only]
#
#   --sign-only   sign and verify locally; NOTARY_PROFILE is not needed and
#                 nothing is sent to Apple
#   --preflight   only check that signing (and, without --sign-only,
#                 notarizing) is set up; build-release.sh runs this before
#                 building anything
#
# Environment (no defaults, so nothing about one maintainer is baked in):
#   DEVELOPER_ID    codesigning identity: its name, e.g. "Developer ID Application:
#                   Name (TEAMID)", or its SHA-1 hash
#   NOTARY_PROFILE  notarytool keychain profile (full mode only)
#   ENTITLEMENTS    entitlements plist (default: scripts/release/Entitlements.plist)

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
ENTITLEMENTS="${ENTITLEMENTS:-$SCRIPT_DIR/Entitlements.plist}"

# Every check below runs before codesign, so a missing prerequisite fails in
# seconds instead of after a build or halfway through a notarization.
if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi
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
if [[ "$PREFLIGHT" == 0 && ! -f "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY" >&2
    exit 1
fi
if [[ "$PREFLIGHT" == 0 ]] && ! file "$BINARY" 2>/dev/null | grep -q "Mach-O"; then
    echo "Error: $BINARY is not a Mach-O binary ($(file -b "$BINARY" 2>&1))." >&2
    exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Error: entitlements file not found at $ENTITLEMENTS" >&2
    exit 1
fi
# DEVELOPER_ID may be the identity's name or its SHA-1 hash; either must match
# a whole field, so a fragment such as "Developer ID Application" is refused.
if ! security find-identity -p codesigning -v 2>/dev/null |
        awk -v id="$DEVELOPER_ID" '$2 == id || index($0, "\"" id "\"") { found = 1 } END { exit !found }'; then
    echo "Error: codesigning identity not found in the keychain: $DEVELOPER_ID" >&2
    echo "       Available identities:" >&2
    security find-identity -p codesigning -v 2>&1 | grep -E '"[^"]*"' | sed 's/^/         /' >&2 || true
    exit 1
fi
if [[ "$SIGN_ONLY" == 0 ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Error: notarytool keychain profile '$NOTARY_PROFILE' is not configured or cannot be used." >&2
    echo "       Set up with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team-id>" >&2
    exit 1
fi
if [[ "$PREFLIGHT" == 1 ]]; then
    [[ "$SIGN_ONLY" == 1 ]] && echo "Signing is set up (identity found)." || echo "Signing and notarizing are set up (identity and notarytool profile found)."
    exit 0
fi

ZIP_PATH=""
SUBMIT_LOG=""
cleanup() {
    [[ -n "$ZIP_PATH" && -f "$ZIP_PATH" ]] && rm -f "$ZIP_PATH"
    [[ -n "$SUBMIT_LOG" && -f "$SUBMIT_LOG" ]] && rm -f "$SUBMIT_LOG"
    return 0
}
trap cleanup EXIT INT TERM

STEPS=5; [[ "$SIGN_ONLY" == 1 ]] && STEPS=3
echo "=== sign-and-notarize: $BINARY ==="
echo "  Identity:      $DEVELOPER_ID"
[[ "$SIGN_ONLY" == 1 ]] && echo "  Mode:          sign only (nothing is sent to Apple)" || echo "  Profile:       $NOTARY_PROFILE"
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
codesign --verify --strict --verbose=2 "$BINARY" 2>&1 | head -5

# Notarization rejects a binary without hardened runtime; check the signed
# result itself so a wrong signing call fails here, not at Apple.
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
printf '%s\n' "$SIGNATURE" | grep -E '^(Authority=Developer ID|TeamIdentifier|CodeDirectory)' | sed 's/^/  /' || true

if [[ "$SIGN_ONLY" == 1 ]]; then
    echo ""
    echo "=== sign-and-notarize: signed (not notarized) ==="
    exit 0
fi

echo ""
echo "[4/$STEPS] Submitting for notarization (usually 1-15 minutes)..."
ZIP_PATH="$(mktemp -t notarize-XXXXXXXX).zip"
ditto -c -k --keepParent "$BINARY" "$ZIP_PATH"
SUBMIT_LOG="$(mktemp -t notarize-log-XXXXXXXX)"

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
# keeps a stalled OCSP lookup from hanging the release.
echo ""
echo "[5/$STEPS] Checking the notarization with spctl..."
SPCTL_TIMEOUT_SECONDS="${SPCTL_TIMEOUT_SECONDS:-60}"
if ! [[ "$SPCTL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: SPCTL_TIMEOUT_SECONDS must be a positive integer (got '$SPCTL_TIMEOUT_SECONDS')." >&2
    exit 1
fi
SPCTL_EXIT=0
SPCTL_OUTPUT="$(perl -e 'my $t=shift; alarm $t; exec @ARGV or die "exec failed: $!"' \
    -- "$SPCTL_TIMEOUT_SECONDS" spctl -a -vvv -t install "$BINARY" 2>&1)" || SPCTL_EXIT=$?
if [[ "$SPCTL_EXIT" -eq 142 ]]; then
    echo "Error: spctl timed out after ${SPCTL_TIMEOUT_SECONDS}s; Apple's OCSP servers are unreachable or slow." >&2
    echo "       Retry when the network is back, or set SPCTL_TIMEOUT_SECONDS higher." >&2
    exit 1
fi
if ! printf '%s\n' "$SPCTL_OUTPUT" | grep -q "source=Notarized Developer ID"; then
    echo "Error: spctl does not accept $BINARY as notarized." >&2
    printf '%s\n' "$SPCTL_OUTPUT" | sed 's/^/         /' >&2
    echo "       Apple's log: xcrun notarytool log ${SUBMISSION_ID:-<id>} --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
fi
echo "  ✓ spctl accepts it as Notarized Developer ID"

echo ""
echo "=== sign-and-notarize: signed and notarized ==="
echo "Stapling skipped (raw Mach-O); Gatekeeper checks online on first launch."
