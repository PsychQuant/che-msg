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
#   VERSION_CHECK_TIMEOUT         seconds each telegram-all --version check may
#                                 take (default 20)
#
# Before anything is built: the full mode runs check-versions.sh, including the
# check that tag vX is unused, and requires every tracked file to be committed
# and no untracked or ignored file in a package's Sources or among its
# Package*.swift manifests (SwiftPM compiles those whatever git ignores;
# .DS_Store aside), because the release must be reproducible from the commit
# its tag will point at; the other modes check consistency only and warn about
# uncommitted changes. Every mode refuses a commit that tracks a symlink
# anywhere in a package. Signing modes also run sign-and-notarize.sh
# --preflight. In every mode, each package's Package.resolved must be tracked
# and present, and every swift build uses exactly its versions
# (--force-resolved-versions).
#
# The .mcpb bundles hold the mcpb files of the commit printed at the start,
# whatever the working tree holds or HEAD becomes. telegram-all's --version is
# checked before signing and, in the signing modes, once more on the signed
# binary, so every signed build launches the hardened-runtime binary once.
# Before the full mode writes .build/dist/vX it checks again that HEAD is that
# commit and the tree passes the same gate; an edit made and undone while the
# build runs is not noticed (PsychQuant/che-msg#94). The output directory
# appears only when every file in it is done.

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
for entry in "${PACKAGES[@]}"; do SOURCE_PATHS+=("${entry%%:*}/Sources" ":(glob)${entry%%:*}/Package*.swift"); done
# uncommitted_changes: one line per change to a tracked file, then per file
# git does not track in a package's Sources or among its Package*.swift
# manifests, ignored ones included: SwiftPM compiles those whatever git
# ignores, and reads a Package@swift-6.swift instead of Package.swift.
# .DS_Store is left out; SwiftPM does not compile it. Nothing when the tree is
# what the commit holds. The full mode checks this at the start and again
# before the release files appear.
uncommitted_changes() {
    local ignored
    git -C "$ROOT" status --porcelain --untracked-files=no || return
    git -C "$ROOT" ls-files --others --exclude-standard -- "${SOURCE_PATHS[@]}" || return
    ignored=$(git -C "$ROOT" ls-files --others --ignored --exclude-standard -- "${SOURCE_PATHS[@]}") || return
    awk '!/(^|\/)\.DS_Store$/' <<<"$ignored"
}
CHANGES=$(uncommitted_changes)
if [[ -n "$CHANGES" ]]; then
    if [[ "$MODE" == full ]]; then
        echo "Error: the working tree has uncommitted changes. A release is built from commit ${COMMIT:0:12}," >&2
        echo "       and its tag will point at that commit, so commit, stash or remove these first:" >&2
        sed 's/^/         /' <<<"$CHANGES" >&2
        exit 1
    fi
    echo "  ⚠ uncommitted changes: this build is not what commit ${COMMIT:0:12} would produce."
    echo "    Its binaries are built from the working tree, but its .mcpb bundles hold the"
    echo "    committed manifest.json and PRIVACY.md of that commit."
fi
# Every build uses exactly the dependency versions recorded in the package's
# tracked Package.resolved (PsychQuant/che-msg#92); swift-sdk and
# swift-argument-parser are ranges, so without it the build would use whatever
# this checkout last resolved, and nothing would record it. The file must also be
# on disk: with an earlier .build, a missing file does not fail the build, which
# then uses that earlier resolution.
for entry in "${PACKAGES[@]}"; do
    pkg=${entry%%:*}
    if ! git -C "$ROOT" ls-files --error-unmatch -- "$pkg/Package.resolved" >/dev/null 2>&1; then
        problem="is not tracked"
        remedy="if it holds the versions you mean to release, commit it (git add $pkg/Package.resolved);"
    elif [ ! -f "$ROOT/$pkg/Package.resolved" ]; then
        problem="is missing from the working tree"
        remedy="restore the committed copy (git checkout -- $pkg/Package.resolved);"
    else
        continue
    fi
    echo "Error: $pkg/Package.resolved $problem. The release builds only the dependency versions it records:" >&2
    echo "       $remedy to update the dependencies on purpose," >&2
    echo "       run swift package update in $pkg, run its tests, and commit the file." >&2
    exit 1
done
# A symlink a package tracks is followed by SwiftPM (in Sources or as
# Package.swift) or packed by its target (in mcpb), so a file from outside the
# repository would end up in the release while git stays clean. No mode builds
# a commit that tracks one anywhere in a package.
for entry in "${PACKAGES[@]}"; do
    pkg=${entry%%:*}
    LINKS=""
    # From a file, not a process substitution: a failed ls-tree stops the
    # build instead of reading as "no symlinks".
    TREE=$(mktemp "${TMPDIR:-/tmp}/build-release-tree.XXXXXX")
    git -C "$ROOT" ls-tree -r -z "$COMMIT" -- "$pkg" > "$TREE" ||
        { rm -f "$TREE"; echo "Error: cannot list $pkg at commit ${COMMIT:0:12}" >&2; exit 1; }
    while IFS= read -r -d '' record; do
        if [[ "${record%% *}" == 120000 ]]; then LINKS+="         ${record#*$'\t'}"$'\n'; fi
    done < "$TREE"
    rm -f "$TREE"
    if [[ -n "$LINKS" ]]; then
        echo "Error: $pkg tracks a symlink, which the build would follow, possibly out of the repository:" >&2
        printf '%s' "$LINKS" >&2
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

# check_version <binary> <name>: the binary reports version X. telegram-all
# answers --version without starting a server or opening TDLib; stdin is
# closed and perl's alarm bounds the run in case it does not. The bot binary
# has no such flag.
check_version() {
    # The binary has to exit 0 as well: one that prints the version and then
    # crashes, or is killed by the alarm, fails the check.
    local reported status=0
    reported=$(perl -e 'my $t = shift; alarm $t; exec @ARGV or die "exec failed: $!"' \
        -- "$VERSION_CHECK_TIMEOUT" "$1" --version </dev/null 2>&1) || status=$?
    [[ $status -eq 0 && "$reported" == "che-telegram-all-mcp $X" ]] || {
        echo "Error: $2 reports \"$reported\" and exits with $status within ${VERSION_CHECK_TIMEOUT}s, expected \"che-telegram-all-mcp $X\" and 0" >&2; exit 1; }
}

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
    if [[ "$bin" == CheTelegramAllMCP ]]; then
        check_version "$UNIVERSAL" "$bin"
    fi

    case "$MODE" in
        full)      "$SCRIPT_DIR/sign-and-notarize.sh" "$UNIVERSAL" ;;
        sign-only) "$SCRIPT_DIR/sign-and-notarize.sh" --sign-only "$UNIVERSAL" ;;
    esac
    # And once more signed: the hardened runtime can stop a binary that ran
    # unsigned (a library it may not load, an entitlement it lacks), so every
    # signed build launches the file that ships at least once.
    if [[ "$bin" == CheTelegramAllMCP && "$MODE" != unsigned ]]; then
        check_version "$UNIVERSAL" "the signed $bin"
    fi

    # Pack the mcpb files of commit $COMMIT plus the binary, so nothing left
    # over in <pkg>/mcpb, no uncommitted edit and nothing committed since the
    # build started ends up in the bundle, and the tracked directory is never
    # written to. -z keeps a name git would quote (non-ASCII) as it is.
    BUNDLE="$STAGE/mcpb-$pkg"
    mkdir -p "$BUNDLE/server"
    # Listed into a file first, so a failed or cut-short ls-tree stops the
    # build instead of packing a partial bundle.
    git -C "$ROOT" ls-tree -r -z "$COMMIT" -- "$pkg/mcpb" > "$STAGE/tree-$pkg" ||
        { echo "Error: cannot list $pkg/mcpb at commit ${COMMIT:0:12}" >&2; exit 1; }
    while IFS= read -r -d '' record; do
        path=${record#*$'\t'}
        sha=${record%%$'\t'*}; sha=${sha##* }
        rel=${path#"$pkg/mcpb/"}
        [[ "$rel" == server/.gitkeep ]] && continue
        mkdir -p "$BUNDLE/$(dirname "$rel")"
        git -C "$ROOT" cat-file blob "$sha" > "$BUNDLE/$rel"
    done < "$STAGE/tree-$pkg"
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

# The checkout stays open through the notarization waits: a commit, a branch
# switch or an edit there reaches the second package's build while the output
# still names commit $COMMIT. So before anything appears in .build/dist/vX,
# the full mode checks again that HEAD is that commit and the tree clean.
if [[ "$MODE" == full ]]; then
    HEAD_NOW=$(git -C "$ROOT" rev-parse HEAD)
    CHANGES=$(uncommitted_changes)
    if [[ "$HEAD_NOW" != "$COMMIT" || -n "$CHANGES" ]]; then
        echo "Error: the checkout changed while the release was being built from commit ${COMMIT:0:12}:" >&2
        [[ "$HEAD_NOW" == "$COMMIT" ]] || echo "         HEAD is now ${HEAD_NOW:0:12}" >&2
        [[ -z "$CHANGES" ]] || sed 's/^/         /' <<<"$CHANGES" >&2
        echo "       The files may not be what that commit produces, so nothing was written to ${DIST#"$ROOT/"}." >&2
        echo "       Put the checkout back on that commit with a clean tree, and run the build again." >&2
        exit 1
    fi
fi

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
