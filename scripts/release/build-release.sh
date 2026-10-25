#!/bin/bash
# Build the release assets for both binaries (PsychQuant/che-msg#40):
# universal CheTelegramAllMCP and CheTelegramBotMCP, signed and notarized,
# their .mcpb bundles, and a .sha256 next to each file. Adapted from che-mcps'
# che-ical-mcp scripts/build-mcpb.sh, for two packages sharing one version.
#
# Usage:
#   scripts/release/build-release.sh [--sign-only]
#
# Modes and where they write (the version X comes from CLIBootstrap.swift):
#   full         signed and notarized             .build/dist/vX/            (what gets released)
#   --sign-only  signed, not notarized            .build/dist/vX-sign-only/
#   unsigned     no DEVELOPER_ID and REQUIRE_CODESIGN unset
#                                                 .build/dist/vX-unsigned/
#
# Environment:
#   DEVELOPER_ID, NOTARY_PROFILE  see sign-and-notarize.sh
#   REQUIRE_CODESIGN=1            refuse to build unless signing is set up
#                                 (make release-signed and make sign-check set it)
#
# Before anything is built: the full mode runs check-versions.sh, including the
# check that tag vX is unused; the other modes check consistency only. Signing
# modes also run sign-and-notarize.sh --preflight.

set -euo pipefail

SIGN_ONLY=0
case "${1:-}" in
    "") ;;
    --sign-only) SIGN_ONLY=1 ;;
    *) echo "Usage: $0 [--sign-only]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGES=(che-telegram-all-mcp:CheTelegramAllMCP che-telegram-bot-mcp:CheTelegramBotMCP)

if [[ -n "${DEVELOPER_ID:-}" || "${REQUIRE_CODESIGN:-}" == 1 ]]; then
    if [[ "$SIGN_ONLY" == 1 ]]; then MODE=sign-only; else MODE=full; fi
elif [[ "$SIGN_ONLY" == 1 ]]; then
    MODE=sign-only   # --sign-only means signing; the preflight reports what is missing
else
    MODE=unsigned
fi

X=$(sed -nE 's/^[[:space:]]*public static let version = "([^"]*)".*/\1/p' \
    "$ROOT/che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift")
[[ -n "$X" ]] || { echo "Error: cannot read the version from CLIBootstrap.swift" >&2; exit 1; }
case "$MODE" in
    full) DIST="$ROOT/.build/dist/v$X" ;;
    *)    DIST="$ROOT/.build/dist/v$X-$MODE" ;;
esac

echo "=== build-release: v$X, mode $MODE ==="
echo ""
echo "[1/4] Checking versions..."
if [[ "$MODE" == full ]]; then
    "$SCRIPT_DIR/check-versions.sh" --root "$ROOT"
else
    "$SCRIPT_DIR/check-versions.sh" --root "$ROOT" --no-tag-check
fi

echo ""
if [[ "$MODE" == unsigned ]]; then
    echo "[2/4] ⚠ Not signed: DEVELOPER_ID is unset and REQUIRE_CODESIGN is not 1."
    echo "      This build is for testing only; never release it."
else
    echo "[2/4] Checking that signing is set up..."
    if [[ "$MODE" == sign-only ]]; then
        "$SCRIPT_DIR/sign-and-notarize.sh" --preflight --sign-only
    else
        "$SCRIPT_DIR/sign-and-notarize.sh" --preflight
    fi
fi

STAGE="$ROOT/.build/release-stage"
rm -rf "$STAGE" "$DIST"
mkdir -p "$STAGE" "$DIST"

# Swift 6.4 writes both --arch builds to the same path, so each product is
# copied out right after its own build and its architecture checked
# (che-ical-mcp#238).
build_arch() {
    local pkg=$1 bin=$2 arch=$3 bin_dir archs
    (cd "$ROOT/$pkg" && swift build -c release --arch "$arch" --product "$bin")
    bin_dir=$(cd "$ROOT/$pkg" && swift build -c release --arch "$arch" --product "$bin" --show-bin-path)
    [[ -f "$bin_dir/$bin" ]] || { echo "Error: no $arch build of $bin at $bin_dir/$bin" >&2; exit 1; }
    cp "$bin_dir/$bin" "$STAGE/$bin-$arch"
    archs=$(lipo -archs "$STAGE/$bin-$arch")
    [[ "$archs" == "$arch" ]] || { echo "Error: the $arch build of $bin contains '$archs'" >&2; exit 1; }
}

# write_sha256 <file>: <file>.sha256 holds the hash only, as che-mcps' releases do.
write_sha256() { shasum -a 256 "$1" | awk '{print $1}' > "$1.sha256"; }

echo ""
echo "[3/4] Building, signing and packing..."
for entry in "${PACKAGES[@]}"; do
    pkg=${entry%%:*}
    bin=${entry#*:}
    echo ""
    echo "--- $pkg ($bin) ---"
    build_arch "$pkg" "$bin" arm64
    build_arch "$pkg" "$bin" x86_64
    UNIVERSAL="$STAGE/$bin"
    rm -f "$UNIVERSAL"
    lipo -create "$STAGE/$bin-arm64" "$STAGE/$bin-x86_64" -output "$UNIVERSAL"
    chmod +x "$UNIVERSAL"
    archs=$(lipo -archs "$UNIVERSAL" | tr ' ' '\n' | sort | tr '\n' ' ')
    [[ "$archs" == "arm64 x86_64 " ]] || { echo "Error: $bin has architectures '$archs'" >&2; exit 1; }

    case "$MODE" in
        full)      "$SCRIPT_DIR/sign-and-notarize.sh" "$UNIVERSAL" ;;
        sign-only) "$SCRIPT_DIR/sign-and-notarize.sh" --sign-only "$UNIVERSAL" ;;
    esac

    # telegram-all answers --version without starting a server or opening TDLib;
    # the bot binary has no such flag.
    if [[ "$bin" == CheTelegramAllMCP ]]; then
        reported=$("$UNIVERSAL" --version 2>&1 || true)
        [[ "$reported" == "che-telegram-all-mcp $X" ]] || {
            echo "Error: $bin reports \"$reported\", expected \"che-telegram-all-mcp $X\"" >&2; exit 1; }
    fi

    # Pack from a clean copy: the tracked mcpb files plus the binary, so nothing
    # left over in <pkg>/mcpb ends up in the bundle and the tracked directory
    # is never written to.
    BUNDLE="$STAGE/mcpb-$pkg"
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/server"
    while IFS= read -r f; do
        rel=${f#"$pkg/mcpb/"}
        [[ "$rel" == server/.gitkeep ]] && continue
        mkdir -p "$BUNDLE/$(dirname "$rel")"
        cp "$ROOT/$f" "$BUNDLE/$rel"
    done < <(git -C "$ROOT" ls-files "$pkg/mcpb")
    cp "$UNIVERSAL" "$BUNDLE/server/$bin"
    mcpb validate "$BUNDLE/manifest.json"
    mcpb pack "$BUNDLE" "$STAGE/$pkg.mcpb"

    cp "$UNIVERSAL" "$DIST/$bin"
    cp "$STAGE/$pkg.mcpb" "$DIST/$pkg.mcpb"
    write_sha256 "$DIST/$bin"
    write_sha256 "$DIST/$pkg.mcpb"
done

echo ""
echo "[4/4] Release files in ${DIST#"$ROOT/"}:"
(cd "$DIST" && for f in *; do [[ "$f" == *.sha256 ]] || printf '  %-28s %s\n' "$f" "$(cat "$f.sha256")"; done)
echo ""
case "$MODE" in
    full)      echo "=== Done: signed and notarized. Next steps are in RELEASING.md. ===" ;;
    sign-only) echo "=== Done: signed, not notarized. Do not release these files. ===" ;;
    unsigned)  echo "=== Done: not signed. Do not release these files. ===" ;;
esac
