#!/bin/bash
# scripts/release/build-release.sh and the root Makefile (PsychQuant/che-msg#40).
#
# Runs the release scripts in a scratch copy of the repository with a fake
# `swift` and `mcpb` and the fake signing tools from lib/. The fake swift
# copies small Mach-O programs (compiled here with cc for arm64 and x86_64)
# instead of building, and writes both architectures to the same path, as
# Swift 6.4 does; real lipo, file and zip inspect the results. The fake
# codesign marks what it signs, so the tests can tell a signed file from an
# unsigned copy. Nothing is signed, nothing reaches the network, and the real
# Keychain is never read.
#
# Tests:
#   1. DEVELOPER_ID unset, signing required: refused before any build.
#   2. NOTARY_PROFILE unset, full mode: refused before any build.
#   3. Versions disagree: refused before any build, naming the place, in the
#      full mode and with --sign-only.
#   4. Tag vX already on origin, full mode: refused before any build.
#   5. Full mode: each package is built for arm64 and x86_64, combined, and
#      built once more for the host; both binaries are signed with hardened
#      runtime and notarized; .build/dist/vX holds exactly the 8 release files,
#      the binaries in it are the signed ones and equal the ones inside the
#      .mcpb bundles, which hold the manifest, PRIVACY.md and the binary only;
#      each .sha256 is its file's hash; the commit is printed; the staging
#      directory is removed.
#   6. A telegram-all binary that reports another version, or never answers
#      --version: refused before anything is signed, nothing in dist.
#   7. A per-arch build that has the wrong architecture: refused.
#   8. --sign-only without NOTARY_PROFILE: signed, never notarized, written to
#      .build/dist/vX-sign-only, even though tag vX exists.
#   9. --sign-only without DEVELOPER_ID: refused before any build.
#  10. No DEVELOPER_ID and signing not required: an unsigned build in
#      .build/dist/vX-unsigned, with a warning.
#  11. Full mode refuses an uncommitted change to a tracked file, an untracked
#      file in a package's Sources, and a symlink in a package's mcpb directory,
#      before building; --sign-only builds a dirty tree with a warning.
#  12. The second notarization fails: no .build/dist/vX is left; a stale file
#      in .build/dist/vX before a successful run is gone after it.
#  13. mcpb missing: refused before any build.
#  14. make release-signed / make sign-check with DEVELOPER_ID unset: refused
#      before build-release.sh runs; with the variables set, sign-check signs
#      without notarizing and release-signed notarizes; plain make prints the
#      targets and runs nothing; make check-pins checks consistency only.
#  15. Every swift build uses --force-resolved-versions; a Package.resolved
#      that is on disk but untracked, or tracked but missing from the working
#      tree, is refused before any build (#92).
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
# answers --version like the real binary; Hang never answers.
PROGS="$SCRATCH/progs"; mkdir -p "$PROGS"
cat > "$PROGS/all.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) {
        if (HANG) { sleep(300); }
        printf("che-telegram-all-mcp %s\n", VERSION);
    }
    return 0;
}
EOF
printf 'int main(void) { return 0; }\n' > "$PROGS/bot.c"
for arch in arm64 x86_64; do
    if ! { cc -arch "$arch" -DHANG=0 -DVERSION="\"$X\"" -o "$PROGS/CheTelegramAllMCP-$arch" "$PROGS/all.c" &&
           cc -arch "$arch" -DHANG=0 -DVERSION="\"0.0.1\"" -o "$PROGS/WrongVersion-$arch" "$PROGS/all.c" &&
           cc -arch "$arch" -DHANG=1 -DVERSION="\"$X\"" -o "$PROGS/Hang-$arch" "$PROGS/all.c" &&
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
    che-telegram-all-mcp/Package.resolved
    che-telegram-bot-mcp/Package.resolved
)

# make_repo <name> [variant]: a scratch repository with the release scripts
# under test, the pinned files from HEAD, a bare origin, fake tools in
# <repo>/../fakebin and a call log in <repo>/../calls. Prints the repo path.
#   variant: wrong-version  the telegram-all build reports 0.0.1
#            hang-version   the telegram-all build never answers --version
#            same-arch      every build is arm64, whatever --arch says
# FAKE_MODE, when set, is passed to the fake signing tools.
make_repo() {
    local base="$SCRATCH/$1" repo="$SCRATCH/$1/repo" f all_prog=CheTelegramAllMCP same_arch=0
    case "${2:-}" in
        wrong-version) all_prog=WrongVersion ;;
        hang-version) all_prog=Hang ;;
        same-arch) same_arch=1 ;;
    esac
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
    make_fake_signing_tools "$base/fakebin" "$base/calls" "${FAKE_MODE:-}"
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
if [ "\$product" = CheTelegramBotMCP ] && [ -x "$base/hook" ]; then "$base/hook"; rm -f "$base/hook"; fi
if [ \$show = 1 ]; then echo "$base/swiftbin"; exit 0; fi
[ -z "\$arch" ] && arch=arm64             # a build without --arch is for the host
[ $same_arch = 1 ] && arch=arm64
src=\$product; [ "\$product" = CheTelegramAllMCP ] && src=$all_prog
cp "$PROGS/\$src-\$arch" "$base/swiftbin/\$product"
EOF
    cat > "$base/fakebin/mcpb" <<EOF
#!/bin/bash
echo "mcpb \$*" >> "$base/calls"
if [ "\$1" = pack ]; then ( cd "\$2" && zip -qrX "\$3" . ); fi
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
        VERSION_CHECK_TIMEOUT=3 bash scripts/release/build-release.sh "$@" 2>&1); RC=$?
}
# run_make <repo> [env assignments...] -- <target...>: sets OUT and RC.
run_make() {
    local repo=$1; shift
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    OUT=$(cd "$repo" && env -u DEVELOPER_ID -u NOTARY_PROFILE -u REQUIRE_CODESIGN \
        PATH="$repo/../fakebin:/usr/bin:/bin:/usr/sbin:/sbin" ${envs[@]+"${envs[@]}"} \
        make "$@" 2>&1); RC=$?
}
# during_build <repo> <command>: the fake swift runs <command> once, right
# before the bot package is built: after telegram-all was signed and, in the
# full mode, notarized, as an edit during the notarization wait would be.
during_build() { printf '#!/bin/bash\n%s\n' "$2" > "$1/../hook"; chmod +x "$1/../hook"; }
commit_in() { git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q "${@:2}"; }
calls() { grep "^$2" "$1/../calls"; }
expect_no_build() {
    if [ "$RC" -ne 0 ]; then pass "refused (exit $RC)"; else fail "exit 0"; fi
    if calls "$1" "swift build" >/dev/null; then fail "swift build ran"; else pass "nothing was built"; fi
}
signed() { tail -n 1 "$1" 2>/dev/null | grep -qxF "$FAKE_SIGNED_MARK"; }
bundle_list() { unzip -Z1 "$1" 2>/dev/null | sort | tr '\n' ' '; }

SIGN_ENV=("DEVELOPER_ID=$FAKE_IDENTITY" NOTARY_PROFILE=test-profile REQUIRE_CODESIGN=1)

# ----------------------------------------------------------- refused early
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
for mode in full sign-only; do
    R=$(make_repo "mismatch-$mode")
    sed -i '' "s/\"version\": \"$X\"/\"version\": \"0.0.9\"/" "$R/che-telegram-bot-mcp/mcpb/manifest.json"
    git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qam "bump one manifest"
    if [ "$mode" = full ]; then build "$R" "${SIGN_ENV[@]}" --; else build "$R" "DEVELOPER_ID=$FAKE_IDENTITY" REQUIRE_CODESIGN=1 -- --sign-only; fi
    expect_no_build "$R"
    if printf '%s' "$OUT" | grep -q 'che-telegram-bot-mcp/mcpb/manifest.json: version is 0.0.9'; then pass "$mode: names the manifest"; else fail "$mode: no manifest message: $OUT"; fi
done

test_case "tag v$X already on origin, full mode"
R=$(make_repo tagged)
git -C "$R/../origin.git" tag "v$X" HEAD
build "$R" "${SIGN_ENV[@]}" --
expect_no_build "$R"

test_case "mcpb missing"
R=$(make_repo no-mcpb); rm "$R/../fakebin/mcpb"
build "$R" "${SIGN_ENV[@]}" --
expect_no_build "$R"
if printf '%s' "$OUT" | grep -q mcpb; then pass "names mcpb"; else fail "no mcpb message: $OUT"; fi

# --------------------------------------------------------------- full mode
test_case "full mode"
R=$(make_repo full)
build "$R" "${SIGN_ENV[@]}" --
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC: $(printf '%s' "$OUT" | tail -5)"; fi
DIST="$R/.build/dist/v$X"
for p in CheTelegramAllMCP CheTelegramBotMCP; do
    builds=$(calls "$R" "swift build" | grep -v -- --show-bin-path | grep -- "--product $p")
    for a in arm64 x86_64; do
        if printf '%s\n' "$builds" | grep -q -- "--arch $a"; then pass "$p built for $a"; else fail "$p not built for $a"; fi
    done
    if printf '%s\n' "$builds" | tail -1 | grep -qv -- "--arch"; then pass "$p built for the host last (.build/release usable)"; else fail "$p: last build has an --arch: $(printf '%s\n' "$builds" | tail -1)"; fi
    archs=$(lipo -archs "$DIST/$p" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')
    if [ "$archs" = "arm64 x86_64 " ]; then pass "$p is universal"; else fail "$p architectures: '$archs'"; fi
    if signed "$DIST/$p"; then pass "dist/$p is the signed file"; else fail "dist/$p is not the signed file"; fi
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
    listed=$(bundle_list "$DIST/$name.mcpb")
    if [ "$listed" = "PRIVACY.md manifest.json server/ server/$bin " ] || [ "$listed" = "PRIVACY.md manifest.json server/$bin " ]; then pass "$name.mcpb holds the manifest, PRIVACY.md and the binary only"; else fail "$name.mcpb holds: $listed"; fi
    if unzip -p "$DIST/$name.mcpb" "server/$bin" 2>/dev/null | cmp -s - "$DIST/$bin"; then pass "$name.mcpb holds the same signed binary as dist"; else fail "$name.mcpb holds a different binary"; fi
done
if calls "$R" "mcpb validate" >/dev/null; then pass "manifests validated before packing"; else fail "no mcpb validate"; fi
builds=$(calls "$R" "swift build" | grep -c .); unpinned=$(calls "$R" "swift build" | grep -v -- --force-resolved-versions)
if [ "$builds" -ge 4 ] && [ -z "$unpinned" ]; then pass "every swift build ($builds) uses the versions in Package.resolved (#92)"; else fail "$builds swift builds; without --force-resolved-versions: ${unpinned:-none}"; fi
if ! git -C "$R" status --porcelain -- che-telegram-all-mcp/mcpb che-telegram-bot-mcp/mcpb | grep -qv stale.mcpb; then pass "tracked mcpb directories untouched"; else fail "mcpb directories changed: $(git -C "$R" status --porcelain)"; fi
if printf '%s' "$OUT" | grep -qF "$(git -C "$R" rev-parse HEAD)"; then pass "prints the commit it was built from"; else fail "commit not printed"; fi
if ! ls -d "$R"/.build/release-stage* >/dev/null 2>&1; then pass "staging directory removed"; else fail "staging left: $(ls -d "$R"/.build/release-stage*)"; fi

test_case "a telegram-all binary that reports another version"
R=$(make_repo wrong wrong-version)
build "$R" "${SIGN_ENV[@]}" --
if [ "$RC" -ne 0 ]; then pass "refused (exit $RC)"; else fail "exit 0"; fi
if printf '%s' "$OUT" | grep -q '0.0.1'; then pass "shows the reported version"; else fail "no version message: $(printf '%s' "$OUT" | tail -3)"; fi
if calls "$R" "codesign --force" >/dev/null; then fail "something was signed first"; else pass "refused before signing"; fi
if [ -e "$R/.build/dist/v$X" ]; then fail "left a dist directory"; else pass "nothing in dist"; fi

test_case "a telegram-all binary that never answers --version"
R=$(make_repo hang hang-version)
start=$(date +%s); build "$R" "${SIGN_ENV[@]}" --; took=$(( $(date +%s) - start ))
if [ "$RC" -ne 0 ] && [ "$took" -lt 60 ]; then pass "refused after ${took}s"; else fail "exit $RC after ${took}s"; fi
if calls "$R" "codesign --force" >/dev/null; then fail "something was signed first"; else pass "refused before signing"; fi

test_case "a per-arch build with the wrong architecture"
R=$(make_repo same-arch same-arch)
build "$R" "${SIGN_ENV[@]}" --
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'x86_64'; then pass "refused, naming x86_64"; else fail "exit $RC: $(printf '%s' "$OUT" | tail -3)"; fi

# ---------------------------------------------------------- other modes
test_case "--sign-only without NOTARY_PROFILE"
R=$(make_repo sign-only); git -C "$R" tag "v$X"
build "$R" "DEVELOPER_ID=$FAKE_IDENTITY" REQUIRE_CODESIGN=1 -- --sign-only
if [ "$RC" -eq 0 ]; then pass "exit 0 even though tag v$X exists"; else fail "exit $RC: $(printf '%s' "$OUT" | tail -5)"; fi
if calls "$R" "xcrun notarytool" >/dev/null; then fail "notarytool ran"; else pass "notarytool never ran"; fi
if [ -f "$R/.build/dist/v$X-sign-only/CheTelegramBotMCP" ] && [ ! -e "$R/.build/dist/v$X" ]; then pass "written to .build/dist/v$X-sign-only"; else fail "dist: $(ls "$R/.build/dist" 2>&1)"; fi
n=$(calls "$R" "codesign --force" | wc -l | tr -d ' ')
if [ "$n" -eq 2 ]; then pass "both binaries signed"; else fail "$n codesign calls"; fi
if signed "$R/.build/dist/v$X-sign-only/CheTelegramAllMCP"; then pass "dist holds the signed file"; else fail "dist holds an unsigned file"; fi

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

# ------------------------------------------------------- tied to a commit
test_case "an uncommitted change to a tracked file"
R=$(make_repo dirty); echo "local edit" >> "$R/plugins/che-telegram-mcp/README.md"
build "$R" "${SIGN_ENV[@]}" --
expect_no_build "$R"
if printf '%s' "$OUT" | grep -qi 'uncommitted'; then pass "says the tree has uncommitted changes"; else fail "no message: $(printf '%s' "$OUT" | tail -3)"; fi
build "$R" "DEVELOPER_ID=$FAKE_IDENTITY" REQUIRE_CODESIGN=1 -- --sign-only
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'uncommitted'; then pass "--sign-only builds it with a warning"; else fail "--sign-only: exit $RC"; fi

test_case "a Package.resolved on disk but not tracked (#92)"
for mode in full sign-only; do
    R=$(make_repo "untracked-resolved-$mode")
    git -C "$R" rm -q --cached che-telegram-bot-mcp/Package.resolved && git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q -m "stop tracking the lock file"
    if [ -f "$R/che-telegram-bot-mcp/Package.resolved" ]; then pass "$mode: the file is still on disk"; else fail "$mode: setup removed the file"; fi
    if [ "$mode" = full ]; then build "$R" "${SIGN_ENV[@]}" --; else build "$R" "DEVELOPER_ID=$FAKE_IDENTITY" REQUIRE_CODESIGN=1 -- --sign-only; fi
    expect_no_build "$R"
    if printf '%s' "$OUT" | grep -q 'che-telegram-bot-mcp/Package.resolved is not tracked'; then pass "$mode: says it is not tracked"; else fail "$mode: no message: $(printf '%s' "$OUT" | tail -3)"; fi
done

test_case "a tracked Package.resolved missing from the working tree (#92)"
R=$(make_repo missing-resolved); rm "$R/che-telegram-bot-mcp/Package.resolved"
build "$R" "DEVELOPER_ID=$FAKE_IDENTITY" REQUIRE_CODESIGN=1 -- --sign-only
expect_no_build "$R"
if printf '%s' "$OUT" | grep -q 'che-telegram-bot-mcp/Package.resolved is missing'; then pass "--sign-only: says it is missing"; else fail "--sign-only: no message: $(printf '%s' "$OUT" | tail -3)"; fi

test_case "an untracked file in a package's Sources"
R=$(make_repo untracked); echo "// local" > "$R/che-telegram-all-mcp/Sources/Extra.swift"
build "$R" "${SIGN_ENV[@]}" --
expect_no_build "$R"

test_case "a symlink in a package's mcpb directory"
R=$(make_repo symlink); echo "outside" > "$SCRATCH/symlink/outside.txt"
ln -s ../../../outside.txt "$R/che-telegram-all-mcp/mcpb/EXTRA.md"
git -C "$R" add che-telegram-all-mcp/mcpb/EXTRA.md && git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm "add a symlink"
build "$R" "${SIGN_ENV[@]}" --
expect_no_build "$R"
if printf '%s' "$OUT" | grep -q 'symlink'; then pass "names the symlink"; else fail "no message: $(printf '%s' "$OUT" | tail -3)"; fi

# --------------------------------------------- bundles hold the commit (#94)
test_case "a non-ASCII file name under mcpb (#94)"
R=$(make_repo non-ascii); git -C "$R" config core.quotePath true   # git's default, whatever the global config says
printf 'notes\n' > "$R/che-telegram-all-mcp/mcpb/說明.md"
git -C "$R" add "che-telegram-all-mcp/mcpb/說明.md" && commit_in "$R" -m "a non-ASCII name"
build "$R" "${SIGN_ENV[@]}" --
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC: $(printf '%s' "$OUT" | tail -3)"; fi
if [ "$(unzip -p "$R/.build/dist/v$X/che-telegram-all-mcp.mcpb" '說明.md' 2>/dev/null)" = notes ]; then pass "packed under its real name"; else fail "not packed as 說明.md: $(unzip -Z1 "$R/.build/dist/v$X/che-telegram-all-mcp.mcpb" 2>&1 | tr '\n' ' ')"; fi

test_case "a dirty tree's sign-only and unsigned bundles hold the commit's files (#94)"
for mode in sign-only unsigned; do
    R=$(make_repo "dirty-pack-$mode")
    committed=$(cat "$R/che-telegram-bot-mcp/mcpb/PRIVACY.md")
    echo "an uncommitted line" >> "$R/che-telegram-bot-mcp/mcpb/PRIVACY.md"
    if [ "$mode" = sign-only ]; then build "$R" "DEVELOPER_ID=$FAKE_IDENTITY" REQUIRE_CODESIGN=1 -- --sign-only; else build "$R" --; fi
    if [ "$RC" -eq 0 ]; then pass "$mode: exit 0"; else fail "$mode: exit $RC: $(printf '%s' "$OUT" | tail -3)"; fi
    if [ "$(unzip -p "$R/.build/dist/v$X-$mode/che-telegram-bot-mcp.mcpb" PRIVACY.md 2>/dev/null)" = "$committed" ]; then pass "$mode: the bundle holds the committed PRIVACY.md"; else fail "$mode: the bundle does not hold the committed PRIVACY.md"; fi
    if printf '%s' "$OUT" | grep -q 'committed manifest'; then pass "$mode: the warning says the bundles hold the committed manifest"; else fail "$mode: no such warning: $(printf '%s' "$OUT" | grep -i uncommitted)"; fi
done

test_case "a commit made while a sign-only build runs does not reach its bundles (#94)"
R=$(make_repo moved-sign-only); START=$(git -C "$R" rev-parse HEAD)
committed=$(cat "$R/che-telegram-bot-mcp/mcpb/PRIVACY.md")
during_build "$R" "echo 'a later line' >> '$R/che-telegram-bot-mcp/mcpb/PRIVACY.md' && git -C '$R' -c user.name=t -c user.email=t@example.invalid commit -qam later"
build "$R" "DEVELOPER_ID=$FAKE_IDENTITY" REQUIRE_CODESIGN=1 -- --sign-only
if [ "$RC" -eq 0 ] && [ "$(git -C "$R" rev-parse HEAD)" != "$START" ]; then pass "built while HEAD moved (exit 0)"; else fail "exit $RC, or HEAD did not move: $(printf '%s' "$OUT" | tail -3)"; fi
if [ "$(unzip -p "$R/.build/dist/v$X-sign-only/che-telegram-bot-mcp.mcpb" PRIVACY.md 2>/dev/null)" = "$committed" ]; then pass "the bundle holds the PRIVACY.md of the commit it printed"; else fail "the bundle holds the later commit's PRIVACY.md"; fi

test_case "the checkout changes while a full build runs (#94)"
for change in commit edit untracked; do
    R=$(make_repo "moved-full-$change")
    mkdir -p "$R/.build/dist/v$X"; echo old > "$R/.build/dist/v$X/old-asset"
    case "$change" in
        commit)    during_build "$R" "echo 'a later line' >> '$R/che-telegram-bot-mcp/mcpb/PRIVACY.md' && git -C '$R' -c user.name=t -c user.email=t@example.invalid commit -qam later"
                   want="HEAD is now" ;;
        edit)      during_build "$R" "echo 'local edit' >> '$R/plugins/che-telegram-mcp/README.md'"
                   want="plugins/che-telegram-mcp/README.md" ;;
        untracked) during_build "$R" "echo '// local' > '$R/che-telegram-bot-mcp/Sources/Extra.swift'"
                   want="che-telegram-bot-mcp/Sources/Extra.swift" ;;
    esac
    build "$R" "${SIGN_ENV[@]}" --
    if [ "$RC" -ne 0 ]; then pass "$change: refused (exit $RC)"; else fail "$change: exit 0"; fi
    # Both packages were notarized, so the refusal is the check at the end.
    n=$(calls "$R" "xcrun notarytool submit" | wc -l | tr -d ' ')
    if [ "$n" -eq 2 ]; then pass "$change: refused after both notarizations"; else fail "$change: $n notarization submissions: $(printf '%s' "$OUT" | tail -3)"; fi
    if printf '%s' "$OUT" | grep -q 'changed while' && printf '%s' "$OUT" | grep -qF "$want"; then pass "$change: says what changed ($want)"; else fail "$change: no message: $(printf '%s' "$OUT" | tail -4)"; fi
    if [ -e "$R/.build/dist/v$X" ]; then fail "$change: left .build/dist/v$X: $(ls "$R/.build/dist/v$X" | tr '\n' ' ')"; else pass "$change: no .build/dist/v$X"; fi
    if ! ls -d "$R"/.build/release-stage* >/dev/null 2>&1; then pass "$change: staging directory removed"; else fail "$change: staging left"; fi
done

# ----------------------------------------------------------- dist handling
test_case "the second notarization fails"
R=$(FAKE_MODE=notarize-fails-second make_repo second-fails)
build "$R" "${SIGN_ENV[@]}" --
if [ "$RC" -ne 0 ]; then pass "refused (exit $RC)"; else fail "exit 0"; fi
if [ -e "$R/.build/dist/v$X" ]; then fail "left $(ls "$R/.build/dist/v$X" | wc -l | tr -d ' ') files in .build/dist/v$X"; else pass "no .build/dist/v$X left"; fi

test_case "a stale file in .build/dist/vX"
R=$(make_repo stale); mkdir -p "$R/.build/dist/v$X"; echo old > "$R/.build/dist/v$X/old-asset"
build "$R" "${SIGN_ENV[@]}" --
if [ "$RC" -eq 0 ] && [ ! -e "$R/.build/dist/v$X/old-asset" ]; then pass "gone after a successful run"; else fail "exit $RC; still there: $(ls "$R/.build/dist/v$X" 2>&1 | tr '\n' ' ')"; fi

test_case "the fixed staging directory of older builds is removed"
R=$(make_repo old-stage); mkdir -p "$R/.build/release-stage/dist"; echo old > "$R/.build/release-stage/dist/CheTelegramAllMCP"
build "$R" "${SIGN_ENV[@]}" --
if [ "$RC" -eq 0 ] && [ ! -e "$R/.build/release-stage" ]; then pass "removed"; else fail "exit $RC; .build/release-stage still there"; fi

# ------------------------------------------------------------------- make
test_case "make targets with DEVELOPER_ID unset"
R=$(make_repo make)
for target in release-signed sign-check; do
    run_make "$R" -- "$target"
    if [ "$RC" -ne 0 ]; then pass "make $target refused (exit $RC)"; else fail "make $target: exit 0"; fi
done
if calls "$R" "swift build" >/dev/null; then fail "swift build ran"; else pass "nothing was built"; fi

test_case "make sign-check with DEVELOPER_ID set"
R=$(make_repo make-sign-check)
run_make "$R" "DEVELOPER_ID=$FAKE_IDENTITY" NOTARY_PROFILE=test-profile VERSION_CHECK_TIMEOUT=3 -- sign-check
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC: $(printf '%s' "$OUT" | tail -3)"; fi
if calls "$R" "xcrun notarytool submit" >/dev/null; then fail "sign-check notarized"; else pass "nothing was notarized"; fi
if [ -d "$R/.build/dist/v$X-sign-only" ] && [ ! -e "$R/.build/dist/v$X" ]; then pass "a sign-only build"; else fail "dist: $(ls "$R/.build/dist" 2>&1)"; fi

test_case "make release-signed with both variables set"
R=$(make_repo make-release)
run_make "$R" "DEVELOPER_ID=$FAKE_IDENTITY" NOTARY_PROFILE=test-profile VERSION_CHECK_TIMEOUT=3 -- release-signed
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC: $(printf '%s' "$OUT" | tail -3)"; fi
n=$(calls "$R" "xcrun notarytool submit" | wc -l | tr -d ' ')
if [ "$n" -eq 2 ] && [ -d "$R/.build/dist/v$X" ]; then pass "notarized both and wrote .build/dist/v$X"; else fail "$n submissions; dist: $(ls "$R/.build/dist" 2>&1)"; fi

test_case "plain make and make check-pins"
R=$(make_repo make-default); git -C "$R" tag "v$X"
run_make "$R" --
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'release-signed'; then pass "plain make lists the targets"; else fail "plain make: exit $RC: $OUT"; fi
if [ -s "$R/../calls" ]; then fail "plain make ran tools: $(head -2 "$R/../calls")"; else pass "plain make runs nothing"; fi
run_make "$R" -- check-pins
if [ "$RC" -eq 0 ]; then pass "check-pins passes on a released version"; else fail "check-pins: exit $RC"; fi
run_make "$R" -- check-versions
if [ "$RC" -ne 0 ]; then pass "check-versions refuses the released version"; else fail "check-versions: exit 0"; fi

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
