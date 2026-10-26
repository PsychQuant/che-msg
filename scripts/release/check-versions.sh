#!/bin/bash
# Refuse a release whose version is not the same in every place that pins it
# (PsychQuant/che-msg#40). v0.6.0 shipped a bot that still reported 0.1.0
# because nothing checked this.
#
# The binary version comes from CLIBootstrap.swift (or --expect); the plugin
# version from plugins/che-telegram-mcp/.claude-plugin/plugin.json. The places
# checked are exactly the ones below. A version written anywhere else is not a
# pin and is not checked: a feature's minimum version ("Needs … 0.8.0 or
# later" in the plugin README) and the history in a CHANGELOG stay as they are.
#
# Usage:
#   scripts/release/check-versions.sh [--expect X.Y.Z] [--expect-plugin X.Y.Z]
#                                     [--root DIR] [--no-tag-check] [--no-remote]
#
#   --expect X.Y.Z   the binary version to require (default: CLIBootstrap.swift)
#   --expect-plugin X.Y.Z  the plugin version to require (default: plugin.json)
#   --root DIR       the repository to check (default: this script's repository)
#   --no-tag-check   check consistency only, not that tag vX.Y.Z is still unused
#   --no-remote      look for the tag locally only, not on origin
#
# Exit: 0 every place agrees; 1 something does not (every problem is listed);
#       2 usage error or the binary version cannot be read.

set -u
export LC_ALL=C

ROOT=""
EXPECT=""
EXPECT_PLUGIN=""
TAG_CHECK=1
REMOTE=1
while [ $# -gt 0 ]; do
    case "$1" in
        # An empty value is refused rather than read as "use the default": a
        # caller passing --expect "$V" with V unset would otherwise check nothing.
        --expect) [ -n "${2:-}" ] || { echo "check-versions: --expect needs a version" >&2; exit 2; }
            EXPECT=$2; shift 2 ;;
        --expect-plugin) [ -n "${2:-}" ] || { echo "check-versions: --expect-plugin needs a version" >&2; exit 2; }
            EXPECT_PLUGIN=$2; shift 2 ;;
        --root) [ -n "${2:-}" ] || { echo "check-versions: --root needs a directory" >&2; exit 2; }
            ROOT=$2; shift 2 ;;
        --no-tag-check) TAG_CHECK=0; shift ;;
        --no-remote) REMOTE=0; shift ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "check-versions: unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" 2>/dev/null || { echo "check-versions: cannot enter $ROOT" >&2; exit 2; }

XYZ='^[0-9]+\.[0-9]+\.[0-9]+$'
PROBLEMS=0
ok()  { echo "✓ $1: $2"; }
bad() { echo "✗ $1"; PROBLEMS=$((PROBLEMS + 1)); }

# found <file> <sed -E program>: every distinct value the program prints, space-separated.
found() { [ -f "$1" ] && sed -nE "$2" "$1" | sort -u | tr '\n' ' ' | sed 's/ $//'; }

# expect <file> <what> <wanted> <value>
expect() {
    if [ -z "$4" ]; then bad "$1: $2 not found"
    elif [ "$4" = "$3" ]; then ok "$1" "$2 $3"
    else bad "$1: $2 is $4, expected $3"; fi
}

# json <file> <python expression over d>: prints the value, or nothing.
json() {
    [ -f "$1" ] && python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    v = eval(sys.argv[2])  # the expression is one of the fixed literals in this script
except Exception:
    v = None
print(v if isinstance(v, str) else "")' "$1" "$2"
}

# has_section <file> <version>: the CHANGELOG has a line starting "## [version]"
# (a "### [version]" heading or the text inside a sentence does not count).
has_section() { [ -f "$1" ] && awk -v h="## [$2]" 'index($0, h) == 1 { found = 1 } END { exit !found }' "$1"; }

# section_mentions <file> <section version> <version>: that section names the
# version as a whole: not part of 10.8.0, 0.8.01 or 0.8.0.1. A sentence-ending
# "0.8.0." still counts.
section_mentions() {
    awk -v h="## [$2]" -v v="$3" '
        index($0, h) == 1 { inside = 1; next }
        inside && index($0, "## [") == 1 { exit }
        inside { line = $0; while ((i = index(line, v)) > 0) {
            # substr(s, 0, 1) is the first character in macOS awk, so a match at
            # the start of the line needs its own case.
            before = (i > 1) ? substr(line, i - 1, 1) : ""
            after = substr(line, i + length(v), 2)
            if (before !~ /[0-9.]/ && after !~ /^[0-9]/ && after !~ /^\.[0-9]/) { hit = 1; exit }
            line = substr(line, i + 1) } }
        END { exit hit ? 0 : 1 }' "$1"
}

# ------------------------------------------------------------ binary version
ALL_SRC=che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
ALL_SRC_VERSION='s/^[[:space:]]*public static let version = "([^"]*)".*/\1/p'
if [ -z "$EXPECT" ]; then
    EXPECT=$(found "$ALL_SRC" "$ALL_SRC_VERSION")
    [ -n "$EXPECT" ] || { echo "check-versions: cannot read the binary version from $ALL_SRC" >&2; exit 2; }
fi
if ! [[ "$EXPECT" =~ $XYZ ]]; then
    echo "check-versions: binary version \"$EXPECT\" is not x.y.z" >&2
    exit 2
fi
X=$EXPECT

README=plugins/che-telegram-mcp/README.md
PLUGIN_JSON=plugins/che-telegram-mcp/.claude-plugin/plugin.json
PLUGIN_CHANGELOG=plugins/che-telegram-mcp/CHANGELOG.md

echo "Binary version $X"
expect "$ALL_SRC" "CLIBootstrap.version" "$X" "$(found "$ALL_SRC" "$ALL_SRC_VERSION")"
f=che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
expect "$f" "server version" "$X" "$(found "$f" 's/^[[:space:]]*version: "([^"]*)".*/\1/p')"
for pkg in che-telegram-all-mcp che-telegram-bot-mcp; do
    f=$pkg/mcpb/manifest.json
    expect "$f" "version" "$X" "$(json "$f" 'd["version"]')"
done
for w in che-telegram-all-mcp che-telegram-bot-mcp; do
    f=plugins/che-telegram-mcp/bin/$w-wrapper.sh
    expect "$f" "DESIRED_VERSION" "$X" "$(found "$f" 's/^DESIRED_VERSION="([^"]*)"$/\1/p')"
done
expect CLAUDE.md "pin note" "$X" "$(found CLAUDE.md 's/.*目前 ([0-9][0-9.]*).*/\1/p')"
for b in CheTelegramAllMCP CheTelegramBotMCP; do
    expect "$README" "download URL ($b)" "$X" "$(found "$README" "s#.*releases/download/v([^/]*)/$b( .*|\$)#\\1#p")"
    expect "$README" "version record line ($b)" "$X" "$(found "$README" "s#^echo ([^ ]*) > ~/bin/\\.$b\\.version\$#\\1#p")"
done
for p in che-telegram-all-mcp che-telegram-bot-mcp; do
    expect "$README" "Version section pin ($p)" "$X" "$(found "$README" "/^Plugin version: /s/.*\`$p\` v([0-9][^ ]*).*/\\1/p")"
done
for pkg in che-telegram-all-mcp che-telegram-bot-mcp; do
    f=$pkg/CHANGELOG.md
    if has_section "$f" "$X"; then ok "$f" "section ## [$X]"; else bad "$f: no section ## [$X]"; fi
done

# ------------------------------------------------------------ plugin version
P_JSON=$(json "$PLUGIN_JSON" 'd["version"]')
P=${EXPECT_PLUGIN:-$P_JSON}
if [ -n "$EXPECT_PLUGIN" ] && ! [[ "$EXPECT_PLUGIN" =~ $XYZ ]]; then
    echo "check-versions: plugin version \"$EXPECT_PLUGIN\" is not x.y.z" >&2
    exit 2
fi
echo ""
echo "Plugin version ${P:-?}"
if [ -z "$P" ]; then
    bad "$PLUGIN_JSON: plugin version not found"
else
    if [ -z "$EXPECT_PLUGIN" ] && ! [[ "$P_JSON" =~ $XYZ ]]; then
        bad "$PLUGIN_JSON: plugin version \"$P_JSON\" is not x.y.z"
    fi
    expect "$PLUGIN_JSON" "plugin version" "$P" "$P_JSON"
    f=.claude-plugin/marketplace.json
    expect "$f" "che-telegram-mcp version" "$P" \
        "$(json "$f" 'next(p["version"] for p in d["plugins"] if p["name"] == "che-telegram-mcp")')"
    expect "$README" "Plugin version" "$P" "$(found "$README" 's/^Plugin version: ([^ ]*) .*/\1/p')"
    if ! has_section "$PLUGIN_CHANGELOG" "$P"; then
        bad "$PLUGIN_CHANGELOG: no section ## [$P]"
    elif section_mentions "$PLUGIN_CHANGELOG" "$P" "$X"; then
        ok "$PLUGIN_CHANGELOG" "section ## [$P] mentions $X"
    else
        bad "$PLUGIN_CHANGELOG: section ## [$P] does not mention $X"
    fi
fi

# ---------------------------------------------------------------------- tags
# A version that was released is never released again: wrappers download only
# when the version changes, so a re-signed v$X would never reach anyone.
if [ "$TAG_CHECK" = 1 ]; then
    echo ""
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        bad "$ROOT is not a git repository, so tag v$X cannot be checked"
    elif git rev-parse -q --verify "refs/tags/v$X" >/dev/null; then
        bad "tag v$X already exists locally — a released version is never published again; bump the version"
    elif [ "$REMOTE" = 0 ]; then
        ok "tags" "v$X does not exist locally (origin not checked)"
    # Only stdout lists tags; git writes warnings (a redirected URL, a new SSH
    # host key) to stderr even when the listing succeeds.
    elif ! remote_tags=$(git ls-remote --tags origin "refs/tags/v$X" 2>"${TMPDIR:-/tmp}/check-versions-ls-remote.$$"); then
        bad "cannot list origin's tags ($(head -1 "${TMPDIR:-/tmp}/check-versions-ls-remote.$$")) — rerun when origin is reachable, or pass --no-remote to check local tags only"
    elif [ -n "$remote_tags" ]; then
        bad "tag v$X already exists on origin — a released version is never published again; bump the version"
    else
        ok "tags" "v$X exists neither locally nor on origin"
    fi
    rm -f "${TMPDIR:-/tmp}/check-versions-ls-remote.$$"
fi

echo ""
if [ "$PROBLEMS" -eq 0 ]; then
    echo "All versions agree: binary $X, plugin $P."
    exit 0
fi
echo "$PROBLEMS problem(s) above; fix them before releasing v$X."
exit 1
