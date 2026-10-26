#!/bin/bash
# scripts/release/build-release.sh and the root Makefile (PsychQuant/che-msg#40).
#
# Runs the release scripts in a scratch copy of the repository with a fake
# `swift` and `mcpb` and the fake signing tools from lib/. The fake swift
# copies small Mach-O programs (compiled here with cc for arm64 and x86_64)
# instead of building, and writes both architectures to the same path, as
# Swift 6.4 does; real lipo and file inspect the results. Nothing is signed,
# nothing reaches the network, and the real Keychain is never read.
#
# Tests:
#   1. DEVELOPER_ID unset, signing required: refused before any build.
#   2. NOTARY_PROFILE unset, full mode: refused before any build.
#   3. Versions disagree: refused before any build, naming the place.
#   4. Tag vX already on origin, full mode: refused before any build.
#   5. Full mode: each package is built for arm64 and x86_64 and combined;
#      both binaries are signed with hardened runtime and notarized; the
#      .mcpb bundles hold the signed binary, the manifest and PRIVACY.md and
#      nothing else; .build/dist/vX holds exactly the 8 release files, and
#      each .sha256 is the hash of its file.
#   6. A telegram-all binary that reports another version: refused.
#   7. --sign-only without NOTARY_PROFILE: signed, never notarized, written to
#      .build/dist/vX-sign-only, even though tag vX exists.
#   8. --sign-only without DEVELOPER_ID: refused before any build.
#   9. No DEVELOPER_ID and signing not required: an unsigned build in
#      .build/dist/vX-unsigned, with a warning.
#  10. make release-signed / make sign-check with DEVELOPER_ID unset: refused
#      before build-release.sh runs.
#
# Usage:
#   bash tests/release/test-build-release.sh
#
# Exit: 0 on all pass, 1 on any failure. Needs cc (Xcode Command Line Tools).

set -u
# Expected listings are in C collation; the maintainer's shell is usually UTF-8.
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/release/lib/fake_signing_tools.sh"

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/build-release-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
# The scripts under test create temp files; keep them inside the scratch directory.
export TMPDIR="$SCRATCH/tmp"
mkdir -p "$TMPDIR"
trap 'rm -rf "$SCRATCH"' EXIT

X=$(git -C "$ROOT" show HEAD:che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift |
    sed -nE 's/^[[:space:]]*public static let version = "([^"]*)".*/\1/p')
[ -n "$X" ] || { echo "ERROR: cannot read the version at HEAD" >&2; exit 1; }

# Thin Mach-O programs standing in for the built products. The telegram-all one
# answers --version like the real binary.
PROGS="$SCRATCH/progs"; mkdir -p "$PROGS"
cat > "$PROGS/all.c" <<'EOF'
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) { printf("che-telegram-all-mcp %s\n", VERSION); }
    return 0;
}
EOF
printf 'int main(void) { return 0; }\n' > "$PROGS/bot.c"
for arch in arm64 x86_64; do
    if ! { cc -arch "$arch" -DVERSION="\"$X\"" -o "$PROGS/CheTelegramAllMCP-$arch" "$PROGS/all.c" &&
           cc -arch "$arch" -DVERSION="\"0.0.1\"" -o "$PROGS/WrongVersion-$arch" "$PROGS/all.c" &&
           cc -arch "$arch" -o "$PROGS/CheTelegramBotMCP-$arch" "$PROGS/bot.c"; }; then
        echo "ERROR: cc cannot build for $arch" >&2; exit 1
    fi
done

PINNED=(
    che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
    che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
    plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
    plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
    CLAUDE.md
    plugins/che-telegram-mcp/README.md
    che-telegram-all-mcp/CHANGELOG.md
    che-telegram-bot-mcp/CHANGELOG.md
    plugins/che-telegram-mcp/CHANGELOG.md
    plugins/che-telegram-mcp/.claude-plugin/plugin.json
    .claude-plugin/marketplace.json
    che-telegram-all-mcp/mcpb/manifest.json
    che-telegram-all-mcp/mcpb/PRIVACY.md
    che-telegram-all-mcp/mcpb/server/.gitkeep
    che-telegram-bot-mcp/mcpb/manifest.json
    che-telegram-bot-mcp/mcpb/PRIVACY.md
    che-telegram-bot-mcp/mcpb/server/.gitkeep
)

# make_repo <name> [wrong-version]: a scratch repository with the release
# scripts under test, the pinned files from HEAD, a bare origin, fake tools in
# <repo>/../fakebin and a call log in <repo>/../calls. Prints the repo path.
make_repo() {
    local base="$SCRATCH/$1" repo="$SCRATCH/$1/repo" f arch all_prog=CheTelegramAllMCP
    [ "${2:-}" = wrong-version ] && all_prog=WrongVersion
    mkdir -p "$repo/scripts/release" "$base/swiftbin"
    for f in "${PINNED[@]}"; do
        mkdir -p "$repo/$(dirname "$f")"
        git -C "$ROOT" show "HEAD:$f" > "$repo/$f" || exit 1
    done
    cp "$ROOT"/scripts/release/* "$repo/scripts/release/"
    cp "$ROOT/Makefile" "$repo/Makefile"
    echo "left over from an older build" > "$repo/che-telegram-all-mcp/mcpb/stale.mcpb"
    git -C "$repo" init -q && git -C "$repo" add -A . ':!che-telegram-all-mcp/mcpb/stale.mcpb' &&
        git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m base || exit 1
    git clone -q --bare "$repo" "$base/origin.git" && git -C "$repo" remote add origin "$base/origin.git" || exit 1
    : > "$base/calls"
    make_fake_signing_tools "$base/fakebin" "$base/calls"
    cat > "$base/fakebin/swift" <<EOF
#!/bin/bash
echo "swift \$*" >> "$base/calls"
arch=""; product=""; show=0
while [ \$# -gt 0 ]; do
    case "\$1" in
        --arch) arch=\$2; shift ;;
        --product) product=\$2; shift ;;
        --show-bin-path) show=1 ;;
    esac
    shift
done
if [ \$show = 1 ]; then echo "$base/swiftbin"; exit 0; fi
src=\$product; [ "\$product" = CheTelegramAllMCP ] && src=$all_prog
cp "$PROGS/\$src-\$arch" "$base/swiftbin/\$product"
EOF
    cat > "$base/fakebin/mcpb" <<EOF
#!/bin/bash
echo "mcpb \$*" >> "$base/calls"
if [ "\$1" = pack ]; then ( cd "\$2" && find . -type f | sed 's#^\./##' | sort ) > "\$3"; fi
exit 0
EOF
    chmod +x "$base/fakebin/swift" "$base/fakebin/mcpb"
    echo "$repo"
}

# build <repo> [env assignments...] -- [args...]: runs build-release.sh; sets OUT and RC.
build() {
    local repo=$1; shift
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    OUT=$(cd "$repo" && env -u DEVELOPER_ID -u NOTARY_PROFILE -u REQUIRE_CODESIGN \
        PATH="$repo/../fakebin:/usr/bin:/bin:/usr/sbin:/sbin" ${envs[@]+"${envs[@]}"} \
        bash scripts/release/build-release.sh "$@" 2>&1); RC=$?
}
calls() { grep "^$2" "$1/../calls"; }
expect_no_build() {
    if [ "$RC" -ne 0 ]; then pass "refused (exit $RC)"; else fail "exit 0"; fi
    if calls "$1" "swift build" >/dev/null; then fail "swift build ran"; else pass "nothing was built"; fi
}

SIGN_ENV=("DEVELOPER_ID=$FAKE_IDENTITY" NOTARY_PROFILE=test-profile REQUIRE_CODESIGN=1)

test_case "DEVELOPER_ID unset, signing required"
R=$(make_repo no-id)
build "$R" REQUIRE_CODESIGN=1 NOTARY_PROFILE=test-profile --
expect_no_build "$R"
if printf '%s' "$OUT" | grep -q DEVELOPER_ID; then pass "names DEVELOPER_ID"; else fail "no DEVELOPER_ID message: $OUT"; fi

test_case "NOTARY_PROFILE unset, full mode"
R=$(make_repo no-profile)
build "$R" "DEVELOPER_ID=$FAKE_IDENTITY" REQUIRE_CODESIGN=1 --
expect_no_build "$R"

test_case "versions disagree"
R=$(make_repo mismatch)
sed -i '' "s/\"version\": \"$X\"/\"version\": \"0.0.9\"/" "$R/che-telegram-bot-mcp/mcpb/manifest.json"
build "$R" "${SIGN_ENV[@]}" --
expect_no_build "$R"
if printf '%s' "$OUT" | grep -q 'che-telegram-bot-mcp/mcpb/manifest.json: version is 0.0.9'; then pass "names the manifest"; else fail "no manifest message: $OUT"; fi

test_case "tag v$X already on origin, full mode"
R=$(make_repo tagged)
git -C "$R/../origin.git" tag "v$X" HEAD
build "$R" "${SIGN_ENV[@]}" --
expect_no_build "$R"

test_case "full mode"
R=$(make_repo full)
build "$R" "${SIGN_ENV[@]}" --
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC: $(printf '%s' "$OUT" | tail -5)"; fi
DIST="$R/.build/dist/v$X"
for p in CheTelegramAllMCP CheTelegramBotMCP; do
    for a in arm64 x86_64; do
        if calls "$R" "swift build" | grep -v -- --show-bin-path | grep -q -- "--arch $a .*--product $p\|--product $p .*--arch $a"; then pass "$p built for $a"; else fail "$p not built for $a"; fi
    done
    archs=$(lipo -archs "$DIST/$p" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')
    if [ "$archs" = "arm64 x86_64 " ]; then pass "$p is universal"; else fail "$p architectures: '$archs'"; fi
    if calls "$R" "codesign --force" | grep -q -- "--options runtime.*$DIST/$p\|--options runtime.*/$p\$"; then pass "$p signed with hardened runtime"; else fail "$p not signed: $(calls "$R" 'codesign --force')"; fi
done
n=$(calls "$R" "xcrun notarytool submit" | wc -l | tr -d ' ')
if [ "$n" -eq 2 ]; then pass "two notarization submissions"; else fail "$n notarization submissions"; fi
FILES=$(cd "$DIST" 2>/dev/null && for f in *; do echo "$f"; done | sort | tr '\n' ' ')
WANT="CheTelegramAllMCP CheTelegramAllMCP.sha256 CheTelegramBotMCP CheTelegramBotMCP.sha256 che-telegram-all-mcp.mcpb che-telegram-all-mcp.mcpb.sha256 che-telegram-bot-mcp.mcpb che-telegram-bot-mcp.mcpb.sha256 "
if [ "$FILES" = "$WANT" ]; then pass "dist holds exactly the 8 release files"; else fail "dist holds: $FILES"; fi
for f in CheTelegramAllMCP CheTelegramBotMCP che-telegram-all-mcp.mcpb che-telegram-bot-mcp.mcpb; do
    if [ "$(cat "$DIST/$f.sha256" 2>/dev/null)" = "$(shasum -a 256 "$DIST/$f" 2>/dev/null | awk '{print $1}')" ]; then pass "$f.sha256 is its hash"; else fail "$f.sha256 does not match"; fi
done
for pkg in che-telegram-all-mcp:CheTelegramAllMCP che-telegram-bot-mcp:CheTelegramBotMCP; do
    name=${pkg%%:*}; bin=${pkg#*:}
    packed=$(tr '\n' ' ' < "$DIST/$name.mcpb" 2>/dev/null)
    if [ "$packed" = "PRIVACY.md manifest.json server/$bin " ]; then pass "$name.mcpb holds the manifest, PRIVACY.md and the binary only"; else fail "$name.mcpb holds: $packed"; fi
done
if calls "$R" "mcpb validate" >/dev/null; then pass "manifests validated before packing"; else fail "no mcpb validate"; fi
if ! git -C "$R" status --porcelain -- che-telegram-all-mcp/mcpb che-telegram-bot-mcp/mcpb | grep -qv stale.mcpb; then pass "tracked mcpb directories untouched"; else fail "mcpb directories changed: $(git -C "$R" status --porcelain)"; fi

test_case "a telegram-all binary that reports another version"
R=$(make_repo wrong wrong-version)
build "$R" "${SIGN_ENV[@]}" --
if [ "$RC" -ne 0 ]; then pass "refused (exit $RC)"; else fail "exit 0"; fi
if printf '%s' "$OUT" | grep -q '0.0.1'; then pass "shows the reported version"; else fail "no version message: $(printf '%s' "$OUT" | tail -3)"; fi
if [ -e "$R/.build/dist/v$X/CheTelegramAllMCP" ]; then fail "wrote the binary to dist"; else pass "nothing written to dist"; fi

test_case "--sign-only without NOTARY_PROFILE"
R=$(make_repo sign-only); git -C "$R" tag "v$X"
build "$R" "DEVELOPER_ID=$FAKE_IDENTITY" REQUIRE_CODESIGN=1 -- --sign-only
if [ "$RC" -eq 0 ]; then pass "exit 0 even though tag v$X exists"; else fail "exit $RC: $(printf '%s' "$OUT" | tail -5)"; fi
if calls "$R" "xcrun notarytool" >/dev/null; then fail "notarytool ran"; else pass "notarytool never ran"; fi
if [ -f "$R/.build/dist/v$X-sign-only/CheTelegramBotMCP" ] && [ ! -e "$R/.build/dist/v$X" ]; then pass "written to .build/dist/v$X-sign-only"; else fail "dist: $(ls "$R/.build/dist" 2>&1)"; fi
n=$(calls "$R" "codesign --force" | wc -l | tr -d ' ')
if [ "$n" -eq 2 ]; then pass "both binaries signed"; else fail "$n codesign calls"; fi

test_case "--sign-only without DEVELOPER_ID"
R=$(make_repo sign-only-no-id)
build "$R" REQUIRE_CODESIGN=1 -- --sign-only
expect_no_build "$R"

test_case "no DEVELOPER_ID, signing not required"
R=$(make_repo unsigned)
build "$R" --
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC: $(printf '%s' "$OUT" | tail -5)"; fi
if calls "$R" "codesign" >/dev/null; then fail "codesign ran"; else pass "nothing signed"; fi
if [ -f "$R/.build/dist/v$X-unsigned/CheTelegramAllMCP.sha256" ] && [ ! -e "$R/.build/dist/v$X" ]; then pass "written to .build/dist/v$X-unsigned"; else fail "dist: $(ls "$R/.build/dist" 2>&1)"; fi
if printf '%s' "$OUT" | grep -qi 'not signed'; then pass "warns that it is not signed"; else fail "no warning"; fi

test_case "make targets with DEVELOPER_ID unset"
R=$(make_repo make)
for target in release-signed sign-check; do
    OUT=$(cd "$R" && env -u DEVELOPER_ID -u NOTARY_PROFILE PATH="$R/../fakebin:/usr/bin:/bin:/usr/sbin:/sbin" make "$target" 2>&1); RC=$?
    if [ "$RC" -ne 0 ]; then pass "make $target refused (exit $RC)"; else fail "make $target: exit 0"; fi
done
if calls "$R" "swift build" >/dev/null; then fail "swift build ran"; else pass "nothing was built"; fi

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
