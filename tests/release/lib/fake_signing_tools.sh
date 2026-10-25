#!/bin/bash
# Fake codesign, xcrun, security, spctl and ditto for the release tests
# (PsychQuant/che-msg#40). Each appends "<tool> <args>" to a log, so a test can
# see what would have been signed or sent to Apple; nothing is signed, nothing
# reaches the network, and the real Keychain is never read.
#
#   make_fake_signing_tools <bindir> <log> [mode]
#     mode: no-identity    the keychain lists no identity
#           no-runtime     a signed binary reports no hardened-runtime flag
#           not-notarized  spctl does not accept the binary as notarized

FAKE_IDENTITY="Developer ID Application: Test Maintainer (TEAMID1234)"
FAKE_IDENTITY_SHA1="0123456789ABCDEF0123456789ABCDEF01234567"

make_fake_signing_tools() {
    local bin=$1 log=$2 mode=${3:-}
    mkdir -p "$bin"
    : >> "$log"
    cat > "$bin/security" <<EOF
#!/bin/bash
echo "security \$*" >> "$log"
[ "$mode" = no-identity ] && { echo "     0 valid identities found"; exit 0; }
echo '  1) $FAKE_IDENTITY_SHA1 "$FAKE_IDENTITY"'
echo "     1 valid identities found"
EOF
    cat > "$bin/codesign" <<EOF
#!/bin/bash
echo "codesign \$*" >> "$log"
case " \$* " in
    *" -dv "*|*" -d "*)
        echo "Authority=$FAKE_IDENTITY" >&2
        echo "TeamIdentifier=TEAMID1234" >&2
        if [ "$mode" = no-runtime ]; then echo "CodeDirectory v=20500 flags=0x0(none)" >&2
        else echo "CodeDirectory v=20500 flags=0x10000(runtime)" >&2; fi ;;
esac
exit 0
EOF
    cat > "$bin/xcrun" <<EOF
#!/bin/bash
echo "xcrun \$*" >> "$log"
case "\$1 \$2" in
    "notarytool submit") echo "  id: 11111111-2222-3333-4444-555555555555"; echo "  status: Accepted" ;;
esac
exit 0
EOF
    cat > "$bin/spctl" <<EOF
#!/bin/bash
echo "spctl \$*" >> "$log"
if [ "$mode" = not-notarized ]; then echo "\$4: rejected"; echo "source=Unnotarized Developer ID"; exit 3; fi
echo "\$4: accepted"; echo "source=Notarized Developer ID"
EOF
    cat > "$bin/ditto" <<EOF
#!/bin/bash
echo "ditto \$*" >> "$log"
for last; do :; done
: > "\$last"
EOF
    chmod +x "$bin/security" "$bin/codesign" "$bin/xcrun" "$bin/spctl" "$bin/ditto"
}
