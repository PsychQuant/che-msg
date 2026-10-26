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
#   VERSION_CHECK_TIMEOUT         seconds the telegram-all --version check may
#                                 take (default 20)
#
# Before anything is built: the full mode runs check-versions.sh, including the
# check that tag vX is unused, and requires every tracked file to be committed
# (and no untracked file in a package's Sources), because the release must be
# reproducible from the commit its tag will point at; the other modes check
# consistency only and warn about uncommitted changes. Signing modes also run
# sign-and-notarize.sh --preflight. The output directory appears only when
# every file in it is done.

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

for tool in swift lipo mcpb shasum git perl unzip cmp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Error: $tool not found; it is needed to build the release." >&2; exit 1; }
done
VERSION_CHECK_TIMEOUT="${VERSION_CHECK_TIMEOUT:-20}"
[[ "$VERSION_CHECK_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || {
    echo "Error: VERSION_CHECK_TIMEOUT must be a positive integer (got '$VERSION_CHECK_TIMEOUT')." >&2; exit 1; }

X=$(sed -nE 's/^[[:space:]]*public static let version = "([^"]*)".*/\1/p' \
    "$ROOT/che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift" | sort -u)
[[ "$X" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Error: CLIBootstrap.swift's version is not a single x.y.z (got '$X')" >&2; exit 1; }
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
echo "[2/4] Checking the commit and the signing setup..."
COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || { echo "Error: $ROOT has no commit to build from." >&2; exit 1; }
SOURCE_PATHS=()
for entry in "${PACKAGES[@]}"; do SOURCE_PATHS+=("${entry%%:*}/Sources" "${entry%%:*}/Package.swift"); done
CHANGES=$(git -C "$ROOT" status --porcelain --untracked-files=no)
UNTRACKED_SOURCES=$(git -C "$ROOT" ls-files --others --exclude-standard -- "${SOURCE_PATHS[@]}")
if [[ -n "$CHANGES" || -n "$UNTRACKED_SOURCES" ]]; then
    if [[ "$MODE" == full ]]; then
        echo "Error: the working tree has uncommitted changes. A release is built from commit ${COMMIT:0:12}," >&2
        echo "       and its tag will point at that commit, so commit or stash these first:" >&2
        printf '%s\n%s\n' "$CHANGES" "$UNTRACKED_SOURCES" | sed '/^$/d; s/^/         /' >&2
        exit 1
    fi
    echo "  ⚠ uncommitted changes: this build is not what commit ${COMMIT:0:12} would produce."
fi
# Every build uses exactly the dependency versions recorded in the package's
# tracked Package.resolved (PsychQuant/che-msg#92); swift-sdk and
# swift-argument-parser are ranges, so without it the build would use whatever
# this checkout last resolved, and nothing would record it.
for entry in "${PACKAGES[@]}"; do
    pkg=${entry%%:*}
    if ! git -C "$ROOT" ls-files --error-unmatch -- "$pkg/Package.resolved" >/dev/null 2>&1; then
        echo "Error: $pkg/Package.resolved is not tracked. The release builds only the dependency versions it records;" >&2
        echo "       resolve the package (swift package resolve), run the tests, and commit the file." >&2
        exit 1
    fi
done
# The bundles are packed from HEAD's files; a symlink there would pull in
# whatever it points at, possibly from outside the repository.
for entry in "${PACKAGES[@]}"; do
    pkg=${entry%%:*}
    if git -C "$ROOT" ls-tree -r HEAD -- "$pkg/mcpb" | awk '$1 == "120000" { found = 1; print "         " $4 } END { exit !found }' >&2; then
        echo "Error: $pkg/mcpb contains a symlink (listed above); the bundle takes regular files only." >&2
        exit 1
    fi
done
echo "  building from commit $COMMIT"
if [[ "$MODE" == unsigned ]]; then
    echo "  ⚠ Not signed: DEVELOPER_ID is unset and REQUIRE_CODESIGN is not 1."
    echo "    This build is for testing only; never release it."
elif [[ "$MODE" == sign-only ]]; then
    "$SCRIPT_DIR/sign-and-notarize.sh" --preflight --sign-only
else
    "$SCRIPT_DIR/sign-and-notarize.sh" --preflight
fi

# Everything is assembled in a private staging directory and moved into place
# at the end, so a failure leaves no partial .build/dist/vX behind.
# .build/release-stage is the fixed staging directory of builds before
# 2026-10-26 (several hundred MB); nothing uses it any more.
rm -rf "$DIST" "$ROOT/.build/release-stage"
mkdir -p "$ROOT/.build"
STAGE=$(mktemp -d "$ROOT/.build/release-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
OUT="$STAGE/dist"
mkdir -p "$OUT"

# Swift 6.4 writes both --arch builds to the same path, so each product is
# copied out right after its own build and its architecture checked
# (che-ical-mcp#238).
build_arch() {
    local pkg=$1 bin=$2 arch=$3 bin_dir archs
    (cd "$ROOT/$pkg" && swift build -c release --force-resolved-versions --arch "$arch" --product "$bin")
    bin_dir=$(cd "$ROOT/$pkg" && swift build -c release --force-resolved-versions --arch "$arch" --product "$bin" --show-bin-path)
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
    # The per-arch builds left .build/release holding the last one (x86_64);
    # build once more for this machine so run.sh and source builds still work.
    (cd "$ROOT/$pkg" && swift build -c release --force-resolved-versions --product "$bin")
    UNIVERSAL="$STAGE/$bin"
    rm -f "$UNIVERSAL"
    lipo -create "$STAGE/$bin-arm64" "$STAGE/$bin-x86_64" -output "$UNIVERSAL"
    chmod +x "$UNIVERSAL"
    archs=$(lipo -archs "$UNIVERSAL" | tr ' ' '\n' | sort | tr '\n' ' ')
    [[ "$archs" == "arm64 x86_64 " ]] || { echo "Error: $bin has architectures '$archs'" >&2; exit 1; }

    # Checked before signing, so a wrong build is not sent to Apple first.
    # telegram-all answers --version without starting a server or opening
    # TDLib; stdin is closed and perl's alarm bounds the run in case it does
    # not. The bot binary has no such flag.
    if [[ "$bin" == CheTelegramAllMCP ]]; then
        reported=$(perl -e 'my $t = shift; alarm $t; exec @ARGV or die "exec failed: $!"' \
            -- "$VERSION_CHECK_TIMEOUT" "$UNIVERSAL" --version </dev/null 2>&1 || true)
        [[ "$reported" == "che-telegram-all-mcp $X" ]] || {
            echo "Error: $bin reports \"$reported\" within ${VERSION_CHECK_TIMEOUT}s, expected \"che-telegram-all-mcp $X\"" >&2; exit 1; }
    fi

    case "$MODE" in
        full)      "$SCRIPT_DIR/sign-and-notarize.sh" "$UNIVERSAL" ;;
        sign-only) "$SCRIPT_DIR/sign-and-notarize.sh" --sign-only "$UNIVERSAL" ;;
    esac

    # Pack HEAD's tracked mcpb files plus the binary, so nothing left over in
    # <pkg>/mcpb and no uncommitted edit ends up in the bundle, and the
    # tracked directory is never written to.
    BUNDLE="$STAGE/mcpb-$pkg"
    mkdir -p "$BUNDLE/server"
    while read -r _mode _type sha path; do
        rel=${path#"$pkg/mcpb/"}
        [[ "$rel" == server/.gitkeep ]] && continue
        mkdir -p "$BUNDLE/$(dirname "$rel")"
        git -C "$ROOT" cat-file blob "$sha" > "$BUNDLE/$rel"
    done < <(git -C "$ROOT" ls-tree -r HEAD -- "$pkg/mcpb")
    cp "$UNIVERSAL" "$BUNDLE/server/$bin"
    mcpb validate "$BUNDLE/manifest.json"
    mcpb pack "$BUNDLE" "$STAGE/$pkg.mcpb"

    cp "$UNIVERSAL" "$OUT/$bin"
    cp "$STAGE/$pkg.mcpb" "$OUT/$pkg.mcpb"
    # The files that ship are the ones just signed: the binary in the bundle
    # is byte-identical to the one beside it, and that one verifies.
    unzip -p "$OUT/$pkg.mcpb" "server/$bin" | cmp -s - "$OUT/$bin" || {
        echo "Error: the binary inside $pkg.mcpb differs from $bin" >&2; exit 1; }
    if [[ "$MODE" != unsigned ]]; then
        codesign --verify --strict "$OUT/$bin" || { echo "Error: $bin in the release files does not verify" >&2; exit 1; }
    fi
    write_sha256 "$OUT/$bin"
    write_sha256 "$OUT/$pkg.mcpb"
done

mkdir -p "$(dirname "$DIST")"
mv "$OUT" "$DIST"

echo ""
echo "[4/4] Release files in ${DIST#"$ROOT/"}, built from commit $COMMIT:"
(cd "$DIST" && for f in *; do [[ "$f" == *.sha256 ]] || printf '  %-28s %s\n' "$f" "$(cat "$f.sha256")"; done)
echo ""
case "$MODE" in
    full)      echo "=== Done: signed and notarized. Next steps are in RELEASING.md (the release targets commit $COMMIT). ===" ;;
    sign-only) echo "=== Done: signed, not notarized. Do not release these files. ===" ;;
    unsigned)  echo "=== Done: not signed. Do not release these files. ===" ;;
esac
