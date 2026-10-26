#!/bin/bash
# Fake codesign, xcrun, security, spctl and ditto for the release tests
# (PsychQuant/che-msg#40). Each appends "<tool> <args>" to a log, so a test can
# see what would have been signed or sent to Apple; nothing is signed, nothing
# reaches the network, and the real Keychain is never read.
#
#   make_fake_signing_tools <bindir> <log> [mode]
#     mode: no-identity        the keychain lists no identity
#           apple-development  the keychain's identity is an Apple Development one
#           no-runtime         a signed binary reports no hardened-runtime flag
#           extra-entitlement  a signed binary carries an entitlement
#           not-notarized      spctl does not accept the binary as notarized
#           rejected-notarized spctl says "rejected" but names a notarized source
#           accepted-unnotarized  spctl says "accepted" and exits 0, but names
#                              a source that is not notarized
#           notarize-fails-second  the second notarytool submit fails
#           verify-fails       codesign --verify reports a broken signature and fails
#           split-output       security and file write their listing in two
#                              parts with a pause between them, and codesign
#                              and spctl add 256 KB after the lines that
#                              matter, so a reader that stops at its first
#                              match closes the pipe while the writer is still
#                              writing (the writer then gets SIGPIPE)
#
# "Signing" appends the line FAKE_SIGNED_MARK to the file, so a test can tell a
# signed file from an unsigned copy of it.

FAKE_IDENTITY="Developer ID Application: Test Maintainer (TEAMID1234)"
FAKE_IDENTITY_SHA1="0123456789ABCDEF0123456789ABCDEF01234567"
FAKE_SIGNED_MARK="fake-codesign: signed"

make_fake_signing_tools() {
    local bin=$1 log=$2 mode=${3:-}
    mkdir -p "$bin"
    : >> "$log"
    cat > "$bin/security" <<EOF
#!/bin/bash
echo "security \$*" >> "$log"
[ "$mode" = no-identity ] && { echo "     0 valid identities found"; exit 0; }
if [ "$mode" = apple-development ]; then
    echo '  1) $FAKE_IDENTITY_SHA1 "Apple Development: Test Maintainer (TEAMID1234)"'
else
    echo '  1) $FAKE_IDENTITY_SHA1 "$FAKE_IDENTITY"'
fi
[ "$mode" = split-output ] && sleep 0.3
echo "     1 valid identities found"
EOF
    cat > "$bin/codesign" <<EOF
#!/bin/bash
echo "codesign \$*" >> "$log"
fake_filler() { yes 'a long listing goes on after the line that matters' | head -n 5000; }
case " \$* " in
    *" --force "*)
        for last; do :; done
        printf '\n%s\n' "$FAKE_SIGNED_MARK" >> "\$last" ;;
    *" --entitlements - "*)
        if [ "$mode" = extra-entitlement ]; then
            printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>\n'
        else
            printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n'
        fi ;;
    *" -dv "*|*" -d "*)
        echo "Authority=$FAKE_IDENTITY" >&2
        echo "TeamIdentifier=TEAMID1234" >&2
        if [ "$mode" = no-runtime ]; then echo "CodeDirectory v=20500 flags=0x0(none)" >&2
        else echo "CodeDirectory v=20500 flags=0x10000(runtime)" >&2; fi
        [ "$mode" = split-output ] && fake_filler >&2 ;;
    *" --verify "*)
        if [ "$mode" = verify-fails ]; then
            for last; do :; done
            echo "\$last: a sealed resource is missing or invalid" >&2
            exit 1
        fi
        [ "$mode" = split-output ] && fake_filler >&2 ;;
esac
exit 0
EOF
    cat > "$bin/xcrun" <<EOF
#!/bin/bash
echo "xcrun \$*" >> "$log"
case "\$1 \$2" in
    "notarytool submit")
        echo x >> "$log.submits"
        if [ "$mode" = notarize-fails-second ] && [ "\$(wc -l < "$log.submits")" -ge 2 ]; then
            echo "  id: 22222222-3333-4444-5555-666666666666"; echo "  status: Invalid"; exit 1
        fi
        echo "  id: 11111111-2222-3333-4444-555555555555"; echo "  status: Accepted" ;;
esac
exit 0
EOF
    cat > "$bin/spctl" <<EOF
#!/bin/bash
echo "spctl \$*" >> "$log"
if [ "$mode" = not-notarized ]; then echo "\$4: rejected"; echo "source=Unnotarized Developer ID"; exit 3; fi
if [ "$mode" = rejected-notarized ]; then echo "\$4: rejected"; echo "source=Notarized Developer ID"; exit 3; fi
if [ "$mode" = accepted-unnotarized ]; then echo "\$4: accepted"; echo "source=Developer ID"; exit 0; fi
echo "\$4: accepted"; echo "source=Notarized Developer ID"
[ "$mode" = split-output ] && yes 'a long listing goes on after the line that matters' | head -n 5000
exit 0
EOF
    cat > "$bin/ditto" <<EOF
#!/bin/bash
echo "ditto \$*" >> "$log"
for last; do :; done
: > "\$last"
EOF
    chmod +x "$bin/security" "$bin/codesign" "$bin/xcrun" "$bin/spctl" "$bin/ditto"
    if [ "$mode" = split-output ]; then
        cat > "$bin/file" <<EOF
#!/bin/bash
echo "Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64]"
sleep 0.3
echo "(for architecture x86_64):	Mach-O 64-bit executable x86_64"
echo "(for architecture arm64):	Mach-O 64-bit executable arm64"
EOF
        chmod +x "$bin/file"
    fi
}
