#!/bin/bash
# The release scripts stop before doing anything when signing is not set up,
# and --sign-only never uploads anything (PsychQuant/che-msg#40).
#
# Runs scripts/release/sign-and-notarize.sh with fake codesign, xcrun,
# security, spctl and ditto on PATH; each records its arguments, so the test can
# see what would have been signed or sent to Apple. Nothing is signed, nothing
# reaches the network, and the real Keychain is never read.
#
# Tests (sign-and-notarize.sh):
#   1. DEVELOPER_ID unset: refused before codesign runs.
#   2. NOTARY_PROFILE unset (full mode): refused before codesign runs.
#   3. The identity is not in the keychain: refused before codesign runs.
#   4. The file is not a Mach-O binary: refused before codesign runs.
#   5. --sign-only without NOTARY_PROFILE: signs with hardened runtime, a
#      secure timestamp and scripts/release/Entitlements.plist, verifies, and
#      never calls notarytool.
#   6. --sign-only on a result without the hardened-runtime flag: fails.
#   6b. DEVELOPER_ID given as the certificate's SHA-1 hash: accepted.
#   6c. DEVELOPER_ID that only partly matches an identity: refused.
#   7. Full mode: signs, submits the zipped binary with --wait, and checks the
#      result with spctl.
#   8. Full mode when spctl does not see a notarized binary: fails.
#   9. --preflight: checks the prerequisites only, with no binary; with
#      --sign-only it does not need NOTARY_PROFILE and never calls notarytool.
#  10. Checks added after the #40 verify: an identity that is not a Developer
#      ID Application, the "valid identities" summary line and a path that
#      merely contains "Mach-O" are refused before codesign; a lowercase SHA-1
#      is accepted; ENTITLEMENTS from the environment is ignored; an invalid
#      entitlements plist and a bad SPCTL_TIMEOUT_SECONDS are refused before
#      codesign; signed entitlements that differ, and an spctl "rejected", fail;
#      the notarization's temp files are removed.
#
# Usage:
#   bash tests/release/test-release-preflight.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
# Expected listings are in C collation; the maintainer's shell is usually UTF-8.
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGN="${SIGN_UNDER_TEST:-$ROOT/scripts/release/sign-and-notarize.sh}"
source "$ROOT/tests/release/lib/fake_signing_tools.sh"
IDENTITY=$FAKE_IDENTITY
IDENTITY_SHA1=$FAKE_IDENTITY_SHA1

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/release-preflight-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
# The scripts under test create temp files; keep them inside the scratch directory.
export TMPDIR="$SCRATCH/tmp"
mkdir -p "$TMPDIR"
trap 'rm -rf "$SCRATCH"' EXIT

# make_env <dir> [no-identity|no-runtime|not-notarized]: fake tools in <dir>/fakebin
# that append "<tool> <args>" to <dir>/calls, and a Mach-O file <dir>/Bin.
make_env() {
    mkdir -p "$1"
    cp /usr/bin/true "$1/Bin"
    : > "$1/calls"
    make_fake_signing_tools "$1/fakebin" "$1/calls" "${2:-}"
}

# run_sign <dir> [env assignments...] -- [script args...]: sets OUT and RC.
run_sign() {
    local dir=$1; shift
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    OUT=$(env -u DEVELOPER_ID -u NOTARY_PROFILE PATH="$dir/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" ${envs[@]+"${envs[@]}"} \
        bash "$SIGN" "$@" 2>&1); RC=$?
}
called() { grep -q "^$2" "$1/calls"; }
calls_matching() { grep "^$2" "$1/calls"; }

expect_refused_before_codesign() {
    if [ "$RC" -ne 0 ]; then pass "refused (exit $RC)"; else fail "exit 0"; fi
    if called "$1" "codesign"; then fail "codesign ran: $(calls_matching "$1" codesign | head -1)"; else pass "codesign never ran"; fi
    if called "$1" "xcrun notarytool submit"; then fail "notarytool submit ran"; else pass "nothing was submitted"; fi
}

test_case "DEVELOPER_ID unset"
D="$SCRATCH/no-id"; make_env "$D"
run_sign "$D" NOTARY_PROFILE=p -- "$D/Bin"
expect_refused_before_codesign "$D"
if printf '%s' "$OUT" | grep -q DEVELOPER_ID; then pass "names DEVELOPER_ID"; else fail "does not name DEVELOPER_ID: $OUT"; fi

test_case "NOTARY_PROFILE unset, full mode"
D="$SCRATCH/no-profile"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=$IDENTITY" -- "$D/Bin"
expect_refused_before_codesign "$D"
if printf '%s' "$OUT" | grep -q NOTARY_PROFILE; then pass "names NOTARY_PROFILE"; else fail "does not name NOTARY_PROFILE: $OUT"; fi

test_case "identity not in the keychain"
D="$SCRATCH/no-identity"; make_env "$D" no-identity
run_sign "$D" "DEVELOPER_ID=$IDENTITY" -- --sign-only "$D/Bin"
expect_refused_before_codesign "$D"

test_case "not a Mach-O binary"
D="$SCRATCH/not-macho"; make_env "$D"; echo "#!/bin/sh" > "$D/Bin"
run_sign "$D" "DEVELOPER_ID=$IDENTITY" -- --sign-only "$D/Bin"
expect_refused_before_codesign "$D"

test_case "--sign-only without NOTARY_PROFILE"
D="$SCRATCH/sign-only"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=$IDENTITY" -- --sign-only "$D/Bin"
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC: $OUT"; fi
SIGN_CALL=$(calls_matching "$D" "codesign --force" | head -1)
for want in "--options runtime" "--timestamp" "--entitlements $ROOT/scripts/release/Entitlements.plist" "--sign $IDENTITY"; do
    case "$SIGN_CALL" in *"$want"*) pass "codesign has $want" ;; *) fail "codesign lacks $want: $SIGN_CALL" ;; esac
done
if calls_matching "$D" "codesign --verify" | grep -q -- "--strict"; then pass "verifies with --strict"; else fail "no strict verify"; fi
if called "$D" "xcrun notarytool"; then fail "notarytool ran: $(calls_matching "$D" 'xcrun notarytool' | head -1)"; else pass "notarytool never ran"; fi
if called "$D" "ditto"; then fail "zipped for upload"; else pass "nothing was zipped for upload"; fi

test_case "--sign-only, result lacks the hardened-runtime flag"
D="$SCRATCH/no-runtime"; make_env "$D" no-runtime
run_sign "$D" "DEVELOPER_ID=$IDENTITY" -- --sign-only "$D/Bin"
if [ "$RC" -ne 0 ]; then pass "fails (exit $RC)"; else fail "exit 0"; fi
if printf '%s' "$OUT" | grep -qi runtime; then pass "says the runtime flag is missing"; else fail "no runtime message: $OUT"; fi

test_case "DEVELOPER_ID as the certificate's SHA-1 hash"
D="$SCRATCH/sha1"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=$IDENTITY_SHA1" -- --sign-only "$D/Bin"
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC: $OUT"; fi
case "$(calls_matching "$D" "codesign --force" | head -1)" in *"--sign $IDENTITY_SHA1"*) pass "signs with the hash" ;; *) fail "no signing with the hash" ;; esac

test_case "DEVELOPER_ID that only partly matches an identity"
D="$SCRATCH/partial"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=Developer ID Application" -- --sign-only "$D/Bin"
expect_refused_before_codesign "$D"

test_case "full mode"
D="$SCRATCH/full"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=$IDENTITY" NOTARY_PROFILE=test-profile -- "$D/Bin"
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC: $OUT"; fi
SIGN_CALL=$(calls_matching "$D" "codesign --force" | head -1)
case "$SIGN_CALL" in *"--options runtime"*"--timestamp"*|*"--timestamp"*"--options runtime"*) pass "signs with runtime and timestamp" ;; *) fail "sign call: $SIGN_CALL" ;; esac
SUBMIT=$(calls_matching "$D" "xcrun notarytool submit" | head -1)
case "$SUBMIT" in *".zip --keychain-profile test-profile --wait"*) pass "submits the zip with --wait" ;; *) fail "submit call: ${SUBMIT:-none}" ;; esac
if called "$D" "spctl -a -vvv -t install"; then pass "checks the result with spctl"; else fail "no spctl check"; fi

test_case "full mode, spctl does not see a notarized binary"
D="$SCRATCH/not-notarized"; make_env "$D" not-notarized
run_sign "$D" "DEVELOPER_ID=$IDENTITY" NOTARY_PROFILE=test-profile -- "$D/Bin"
if [ "$RC" -ne 0 ]; then pass "fails (exit $RC)"; else fail "exit 0"; fi

test_case "--preflight"
D="$SCRATCH/preflight"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=$IDENTITY" NOTARY_PROFILE=test-profile -- --preflight
if [ "$RC" -eq 0 ]; then pass "all set: exit 0"; else fail "all set: exit $RC: $OUT"; fi
if called "$D" "codesign"; then fail "codesign ran"; else pass "codesign never ran"; fi
if called "$D" "xcrun notarytool submit"; then fail "something was submitted"; else pass "nothing was submitted"; fi
if called "$D" "xcrun notarytool history"; then pass "checked the notarytool profile"; else fail "did not check the notarytool profile"; fi
D="$SCRATCH/preflight-no-profile"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=$IDENTITY" -- --preflight
if [ "$RC" -ne 0 ]; then pass "NOTARY_PROFILE unset: refused (exit $RC)"; else fail "NOTARY_PROFILE unset: exit 0"; fi
D="$SCRATCH/preflight-sign-only"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=$IDENTITY" -- --preflight --sign-only
if [ "$RC" -eq 0 ]; then pass "--sign-only without NOTARY_PROFILE: exit 0"; else fail "--sign-only: exit $RC: $OUT"; fi
if called "$D" "xcrun notarytool"; then fail "notarytool ran"; else pass "notarytool never ran"; fi

test_case "an identity that is not a Developer ID Application"
D="$SCRATCH/apple-dev"; make_env "$D" apple-development
run_sign "$D" "DEVELOPER_ID=Apple Development: Test Maintainer (TEAMID1234)" -- --sign-only "$D/Bin"
expect_refused_before_codesign "$D"
run_sign "$D" "DEVELOPER_ID=$IDENTITY_SHA1" -- --sign-only "$D/Bin"
expect_refused_before_codesign "$D"

test_case "DEVELOPER_ID that matches the summary line"
D="$SCRATCH/summary"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=valid" -- --sign-only "$D/Bin"
expect_refused_before_codesign "$D"

test_case "a lowercase SHA-1"
D="$SCRATCH/lower"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=$(printf '%s' "$IDENTITY_SHA1" | tr 'A-F' 'a-f')" -- --sign-only "$D/Bin"
if [ "$RC" -eq 0 ]; then pass "accepted (exit 0)"; else fail "exit $RC: $OUT"; fi

test_case "a script whose path contains Mach-O"
D="$SCRATCH/macho-path"; make_env "$D"; mkdir -p "$D/Mach-O-dir"; printf '#!/bin/sh\n' > "$D/Mach-O-dir/script"
run_sign "$D" "DEVELOPER_ID=$IDENTITY" -- --sign-only "$D/Mach-O-dir/script"
expect_refused_before_codesign "$D"

test_case "ENTITLEMENTS in the environment"
D="$SCRATCH/ent-env"; make_env "$D"; printf 'not a plist\n' > "$D/evil.plist"
run_sign "$D" "DEVELOPER_ID=$IDENTITY" "ENTITLEMENTS=$D/evil.plist" -- --sign-only "$D/Bin"
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC: $OUT"; fi
case "$(calls_matching "$D" "codesign --force" | head -1)" in *"--entitlements $ROOT/scripts/release/Entitlements.plist"*) pass "signs with the repository's entitlements" ;; *) fail "signed with other entitlements" ;; esac

test_case "an entitlements file that is not a valid plist"
D="$SCRATCH/bad-plist"; make_env "$D"; mkdir -p "$D/copy"
cp "$SIGN" "$D/copy/sign-and-notarize.sh"; printf '<plist><dict>\n' > "$D/copy/Entitlements.plist"
OUT=$(env -u DEVELOPER_ID -u NOTARY_PROFILE PATH="$D/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" "DEVELOPER_ID=$IDENTITY" bash "$D/copy/sign-and-notarize.sh" --sign-only "$D/Bin" 2>&1); RC=$?
expect_refused_before_codesign "$D"

test_case "SPCTL_TIMEOUT_SECONDS that is not a positive integer"
D="$SCRATCH/spctl-timeout"; make_env "$D"
run_sign "$D" "DEVELOPER_ID=$IDENTITY" NOTARY_PROFILE=test-profile SPCTL_TIMEOUT_SECONDS=0 -- "$D/Bin"
expect_refused_before_codesign "$D"

test_case "signed entitlements that differ from the repository's"
D="$SCRATCH/extra-ent"; make_env "$D" extra-entitlement
run_sign "$D" "DEVELOPER_ID=$IDENTITY" -- --sign-only "$D/Bin"
if [ "$RC" -ne 0 ]; then pass "fails (exit $RC)"; else fail "exit 0"; fi
if printf '%s' "$OUT" | grep -qi entitlement; then pass "says the entitlements differ"; else fail "no entitlements message: $OUT"; fi

test_case "spctl says rejected but names a notarized source"
D="$SCRATCH/rejected-notarized"; make_env "$D" rejected-notarized
run_sign "$D" "DEVELOPER_ID=$IDENTITY" NOTARY_PROFILE=test-profile -- "$D/Bin"
if [ "$RC" -ne 0 ]; then pass "fails (exit $RC)"; else fail "exit 0"; fi

test_case "the notarization's temp files are removed"
D="$SCRATCH/temp-files"; make_env "$D"
before=$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')
run_sign "$D" "DEVELOPER_ID=$IDENTITY" NOTARY_PROFILE=test-profile -- "$D/Bin"
after=$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')
if [ "$RC" -eq 0 ] && [ "$after" = "$before" ]; then pass "nothing left in TMPDIR"; else fail "exit $RC, TMPDIR entries $before -> $after"; fi
# mktemp -t ignores TMPDIR on macOS, so "nothing left in TMPDIR" alone would pass
# while the files land in the system temp directory: the zip must be under TMPDIR.
case "$(calls_matching "$D" ditto | head -1)" in *" $TMPDIR/"*) pass "the zip is made under TMPDIR" ;; *) fail "zip made elsewhere: $(calls_matching "$D" ditto | head -1)" ;; esac

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
