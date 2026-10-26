#!/bin/bash
# scripts/release/check-versions.sh refuses a release whose version is not the
# same everywhere it is pinned (PsychQuant/che-msg#40).
#
# Copies the files that pin a version from HEAD into a scratch git repo, breaks
# one place at a time, and checks that the script names that place and only
# that place. Nothing outside the scratch directory is read or written; the
# "origin" used for the remote tag check is a bare repo inside it.
#
# Tests:
#   1. HEAD as it is: every place agrees, exit 0.
#   2. One case per checked place: a different version there is reported by
#      file and by what was checked, exit 1, and nothing else is reported.
#   3. A file that is missing is reported as "not found".
#   4. A feature's minimum version in the plugin README is not a pin: changing
#      it is not reported.
#   5. --expect with another version reports every place.
#   6. Tag vX already exists locally, or on origin: refused.
#   7. --expect that is not x.y.z, an empty option value, or an unknown
#      option: exit 2.
#   8. Edges found by the #40 verify: a longer version (X.1, 1X) does not count
#      as naming X; X at the start of a line does; "### [X]" is not the section;
#      a second, different pin in one file is reported; the marketplace's
#      plugin order does not matter; a plugin version that is not x.y.z is
#      reported; a warning from git ls-remote on stderr is not a tag.
#   9. git ls-remote's stderr goes to a file made by mktemp (owner-only), not
#      to a predictable name in TMPDIR, and the file is removed whether the
#      listing succeeds or fails; when no such file can be made, the tag check
#      fails instead of being skipped (#94).
#
# Usage:
#   bash tests/release/test-check-versions.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
# Expected listings are in C collation; the maintainer's shell is usually UTF-8.
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="${CHECK_VERSIONS_UNDER_TEST:-$ROOT/scripts/release/check-versions.sh}"

FILES=(
    che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
    che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
    che-telegram-all-mcp/mcpb/manifest.json
    che-telegram-bot-mcp/mcpb/manifest.json
    plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
    plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
    CLAUDE.md
    plugins/che-telegram-mcp/README.md
    che-telegram-all-mcp/CHANGELOG.md
    che-telegram-bot-mcp/CHANGELOG.md
    plugins/che-telegram-mcp/CHANGELOG.md
    plugins/che-telegram-mcp/.claude-plugin/plugin.json
    .claude-plugin/marketplace.json
)

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/check-versions-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
# The scripts under test create temp files; keep them inside the scratch directory.
export TMPDIR="$SCRATCH/tmp"
mkdir -p "$TMPDIR"
trap 'rm -rf "$SCRATCH"' EXIT

# fresh_copy <name>: a git repo holding the FILES as committed at HEAD; prints its path.
fresh_copy() {
    local dir="$SCRATCH/$1" f
    mkdir -p "$dir"
    for f in "${FILES[@]}"; do
        mkdir -p "$dir/$(dirname "$f")"
        git -C "$ROOT" show "HEAD:$f" > "$dir/$f" || { echo "ERROR: cannot read $f at HEAD" >&2; exit 1; }
    done
    git -C "$dir" init -q && git -C "$dir" add -A && \
        git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m base || exit 1
    echo "$dir"
}

# edit <dir> <file> <python expression over s>: rewrites the file; the expression
# must change it, so a case can never pass because its edit silently missed.
edit() {
    python3 -I - "$1/$2" "$3" <<'PY' || { echo "ERROR: edit of $2 failed" >&2; exit 1; }
import re, sys, json
path, expr = sys.argv[1:3]
s = open(path, encoding="utf-8").read()
def one(old, new):
    if s.count(old) != 1:
        sys.exit(f"expected exactly one {old!r} in {path}, found {s.count(old)}")
    return s.replace(old, new)
def section(heading, old, new):
    start = s.index(heading)
    end = s.find("\n## [", start + 1)
    end = len(s) if end < 0 else end
    body = s[start:end]
    if old not in body:
        sys.exit(f"{old!r} not in section {heading!r} of {path}")
    return s[:start] + body.replace(old, new) + s[end:]
# expr comes only from the CASES table in this file, never from outside input.
t = eval(expr)
if t == s:
    sys.exit(f"edit left {path} unchanged")
open(path, "w", encoding="utf-8").write(t)
PY
}

# run <dir> [args...]: runs the script; sets OUT and RC.
run() {
    local dir=$1; shift
    OUT=$(bash "$CHECK" --root "$dir" "$@" 2>&1); RC=$?
}
crosses() { printf '%s\n' "$OUT" | grep -c '^✗'; }

BASE=$(fresh_copy base)
X=$(sed -nE 's/^[[:space:]]*public static let version = "([^"]*)".*/\1/p' "$BASE/${FILES[0]}")
P=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$BASE/plugins/che-telegram-mcp/.claude-plugin/plugin.json")
B="$(( ${X%%.*} + 1 )).0.0"     # a version that differs from X
PB="$(( ${P%%.*} + 1 )).0.0"
echo "HEAD pins binary $X, plugin $P"

# ------------------------------------------------------------------- baseline
test_case "HEAD as it is"
run "$BASE" --no-remote
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC:"$'\n'"$OUT"; fi

# ------------------------------------------------------------- one per place
# name | file | python edit | fragment the report must contain
CASES=(
"CLIBootstrap|che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift|one('version = \"$X\"', 'version = \"$B\"')|CLIBootstrap.swift: CLIBootstrap.version is $B"
"bot server|che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift|one('version: \"$X\"', 'version: \"$B\"')|Server.swift: server version is $B"
"all manifest|che-telegram-all-mcp/mcpb/manifest.json|one('\"version\": \"$X\"', '\"version\": \"$B\"')|che-telegram-all-mcp/mcpb/manifest.json: version is $B"
"bot manifest|che-telegram-bot-mcp/mcpb/manifest.json|one('\"version\": \"$X\"', '\"version\": \"$B\"')|che-telegram-bot-mcp/mcpb/manifest.json: version is $B"
"all wrapper|plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh|one('DESIRED_VERSION=\"$X\"', 'DESIRED_VERSION=\"$B\"')|che-telegram-all-mcp-wrapper.sh: DESIRED_VERSION is $B"
"bot wrapper|plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh|one('DESIRED_VERSION=\"$X\"', 'DESIRED_VERSION=\"$B\"')|che-telegram-bot-mcp-wrapper.sh: DESIRED_VERSION is $B"
"CLAUDE.md|CLAUDE.md|one('目前 $X', '目前 $B')|CLAUDE.md: pin note is $B"
"README all URL|plugins/che-telegram-mcp/README.md|one('download/v$X/CheTelegramAllMCP ', 'download/v$B/CheTelegramAllMCP ')|README.md: download URL (CheTelegramAllMCP) is $B"
"README bot URL|plugins/che-telegram-mcp/README.md|one('download/v$X/CheTelegramBotMCP ', 'download/v$B/CheTelegramBotMCP ')|README.md: download URL (CheTelegramBotMCP) is $B"
"README all record|plugins/che-telegram-mcp/README.md|one('echo $X > ~/bin/.CheTelegramAllMCP.version', 'echo $B > ~/bin/.CheTelegramAllMCP.version')|README.md: version record line (CheTelegramAllMCP) is $B"
"README bot record|plugins/che-telegram-mcp/README.md|one('echo $X > ~/bin/.CheTelegramBotMCP.version', 'echo $B > ~/bin/.CheTelegramBotMCP.version')|README.md: version record line (CheTelegramBotMCP) is $B"
"README all pin|plugins/che-telegram-mcp/README.md|one('\`che-telegram-all-mcp\` v$X', '\`che-telegram-all-mcp\` v$B')|README.md: Version section pin (che-telegram-all-mcp) is $B"
"README bot pin|plugins/che-telegram-mcp/README.md|one('\`che-telegram-bot-mcp\` v$X', '\`che-telegram-bot-mcp\` v$B')|README.md: Version section pin (che-telegram-bot-mcp) is $B"
"all CHANGELOG|che-telegram-all-mcp/CHANGELOG.md|one('## [$X]', '## [$B]')|che-telegram-all-mcp/CHANGELOG.md: no section ## [$X]"
"bot CHANGELOG|che-telegram-bot-mcp/CHANGELOG.md|one('## [$X]', '## [$B]')|che-telegram-bot-mcp/CHANGELOG.md: no section ## [$X]"
"plugin CHANGELOG mention|plugins/che-telegram-mcp/CHANGELOG.md|section('## [$P]', '$X', '$B')|plugins/che-telegram-mcp/CHANGELOG.md: section ## [$P] does not mention $X"
"plugin CHANGELOG section|plugins/che-telegram-mcp/CHANGELOG.md|one('## [$P]', '## [$PB]')|plugins/che-telegram-mcp/CHANGELOG.md: no section ## [$P]"
"plugin.json|plugins/che-telegram-mcp/.claude-plugin/plugin.json|one('\"version\": \"$P\"', '\"version\": \"$PB\"')|plugin.json: plugin version is $PB"
"marketplace|.claude-plugin/marketplace.json|json.dumps({**json.loads(s), 'plugins': [dict(p, version='$PB') if p['name'] == 'che-telegram-mcp' else p for p in json.loads(s)['plugins']]}, indent=2) + '\n'|.claude-plugin/marketplace.json: che-telegram-mcp version is $PB"
"README plugin version|plugins/che-telegram-mcp/README.md|one('Plugin version: $P ', 'Plugin version: $PB ')|README.md: Plugin version is $PB"
)
i=0
for c in "${CASES[@]}"; do
    i=$((i + 1))
    IFS='|' read -r name file expr want <<< "$c"
    test_case "a different version in: $name"
    D=$(fresh_copy "case-$i"); edit "$D" "$file" "$expr"
    # --expect and --expect-plugin pin both versions, so editing CLIBootstrap.swift
    # or plugin.json (where they are read from by default) is reported there and
    # nowhere else.
    run "$D" --no-remote --expect "$X" --expect-plugin "$P"
    if [ "$RC" -eq 1 ]; then pass "exit 1"; else fail "exit $RC"; fi
    if printf '%s\n' "$OUT" | grep -qF -- "$want"; then pass "reports: $want"; else fail "does not report '$want':"$'\n'"$OUT"; fi
    n=$(crosses)
    if [ "$n" -eq 1 ]; then pass "reports nothing else"; else fail "reports $n problems:"$'\n'"$(printf '%s\n' "$OUT" | grep '^✗')"; fi
done

# -------------------------------------------------------------- missing file
test_case "a missing file"
D=$(fresh_copy missing); rm "$D/che-telegram-bot-mcp/mcpb/manifest.json"
run "$D" --no-remote
if [ "$RC" -eq 1 ]; then pass "exit 1"; else fail "exit $RC"; fi
if printf '%s\n' "$OUT" | grep -qF 'che-telegram-bot-mcp/mcpb/manifest.json: version not found'; then pass "reports the file as not found"; else fail "no not-found report:"$'\n'"$OUT"; fi

# -------------------------------------------------------- not a pin: ignored
test_case "a feature's minimum version in the plugin README"
D=$(fresh_copy minimum)
edit "$D" plugins/che-telegram-mcp/README.md "re.sub(r'Needs \`che-telegram-all-mcp\` [0-9.]+ or later', 'Needs \`che-telegram-all-mcp\` 0.0.1 or later', s, count=1)"
run "$D" --no-remote
if [ "$RC" -eq 0 ]; then pass "not reported (exit 0)"; else fail "exit $RC:"$'\n'"$OUT"; fi

# ------------------------------------------------------------ wrong --expect
test_case "--expect another version"
run "$BASE" --no-remote --expect "$B"
if [ "$RC" -eq 1 ]; then pass "exit 1"; else fail "exit $RC"; fi
n=$(crosses)
if [ "$n" -ge 15 ]; then pass "reports every binary pin ($n problems)"; else fail "reports only $n problems:"$'\n'"$OUT"; fi

# ---------------------------------------------------------------------- edges
for longer in "$X.1" "1$X"; do
    test_case "plugin CHANGELOG names only $longer"
    D=$(fresh_copy "longer-${longer//./-}")
    edit "$D" plugins/che-telegram-mcp/CHANGELOG.md "section('## [$P]', '$X', '$longer')"
    run "$D" --no-remote
    if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF "section ## [$P] does not mention $X"; then pass "$longer does not count as $X"; else fail "$longer counted as $X (exit $RC)"; fi
done

test_case "plugin CHANGELOG names the version at the start of a line"
D=$(fresh_copy line-start)
edit "$D" plugins/che-telegram-mcp/CHANGELOG.md "section('## [$P]', '$X', '$B')"
edit "$D" plugins/che-telegram-mcp/CHANGELOG.md "re.sub('(?m)^(' + re.escape('## [$P]') + '[^\\n]*\\n)', lambda m: m.group(1) + '\\n$X is the binary version this release pins.\\n', s, count=1)"
run "$D" --no-remote
if [ "$RC" -eq 0 ]; then pass "counted (exit 0)"; else fail "exit $RC:"$'\n'"$(printf '%s\n' "$OUT" | grep '^✗')"; fi

test_case "a heading that only contains the section's text"
D=$(fresh_copy subheading)
edit "$D" che-telegram-all-mcp/CHANGELOG.md "one('## [$X]', '### [$X]')"
run "$D" --no-remote --expect "$X" --expect-plugin "$P"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF "che-telegram-all-mcp/CHANGELOG.md: no section ## [$X]"; then pass "### [$X] is not the section"; else fail "### [$X] accepted (exit $RC)"; fi

test_case "a second, different pin in one file"
D=$(fresh_copy duplicate)
edit "$D" plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh "s + 'DESIRED_VERSION=\"$B\"\\n'"
run "$D" --no-remote --expect "$X" --expect-plugin "$P"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF "che-telegram-all-mcp-wrapper.sh: DESIRED_VERSION is"; then pass "reported"; else fail "not reported (exit $RC)"; fi

test_case "the marketplace lists another plugin first"
D=$(fresh_copy market-order)
edit "$D" .claude-plugin/marketplace.json "json.dumps({**json.loads(s), 'plugins': sorted(json.loads(s)['plugins'], key=lambda q: q['name'] == 'che-telegram-mcp')}, indent=2) + '\\n'"
run "$D" --no-remote
if [ "$RC" -eq 0 ]; then pass "order does not matter (exit 0)"; else fail "exit $RC:"$'\n'"$(printf '%s\n' "$OUT" | grep '^✗')"; fi

test_case "a plugin version that is not x.y.z"
D=$(fresh_copy plugin-xyz)
edit "$D" plugins/che-telegram-mcp/.claude-plugin/plugin.json "one('\"version\": \"$P\"', '\"version\": \"${P%.*}\"')"
run "$D" --no-remote
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF "plugin version \"${P%.*}\" is not x.y.z"; then pass "reported"; else fail "not reported (exit $RC)"; fi

test_case "git ls-remote prints a warning on stderr"
D=$(fresh_copy ls-remote-warning)
git clone -q --bare "$D" "$SCRATCH/warn-origin.git" && git -C "$D" remote add origin "$SCRATCH/warn-origin.git" || exit 1
REAL_GIT=$(command -v git)
mkdir -p "$SCRATCH/fakegit"
# shellcheck disable=SC2016  # $1 and $@ belong to the fake git script
printf '#!/bin/bash\n[ "$1" = ls-remote ] && echo "warning: redirecting to https://example.invalid/" >&2\nexec "%s" "$@"\n' "$REAL_GIT" > "$SCRATCH/fakegit/git"
chmod +x "$SCRATCH/fakegit/git"
OUT=$(PATH="$SCRATCH/fakegit:$PATH" bash "$CHECK" --root "$D" 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then pass "the warning is not a tag (exit 0)"; else fail "exit $RC:"$'\n'"$(printf '%s\n' "$OUT" | grep '^✗')"; fi

test_case "git ls-remote's stderr goes to a private temp file (#94)"
# A fake git records the permissions of the file its stderr is written to: a
# file made by mktemp is the owner's only, one made by a plain redirection
# follows the umask (022 here), as a predictable name in TMPDIR would.
mkdir -p "$SCRATCH/modegit"
# shellcheck disable=SC2016  # $1 and $@ belong to the fake git script
printf '#!/bin/bash\n[ "$1" = ls-remote ] && python3 -I -c "import os; print(oct(os.fstat(2).st_mode & 0o777))" > "%s"\nexec "%s" "$@"\n' \
    "$SCRATCH/stderr-mode" "$REAL_GIT" > "$SCRATCH/modegit/git"
chmod +x "$SCRATCH/modegit/git"
before=$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')
OUT=$(umask 022; PATH="$SCRATCH/modegit:$PATH" bash "$CHECK" --root "$D" 2>&1); RC=$?
mode=$(cat "$SCRATCH/stderr-mode" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$mode" = 0o600 ]; then pass "only its owner can read it (mode $mode)"; else fail "exit $RC, mode ${mode:-not recorded}"; fi
after=$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')
if [ "$after" = "$before" ]; then pass "removed after the listing"; else fail "TMPDIR entries $before -> $after"; fi
D=$(fresh_copy ls-remote-fails); git -C "$D" remote add origin "$SCRATCH/no-such-origin.git"
OUT=$(PATH="$SCRATCH/modegit:$PATH" bash "$CHECK" --root "$D" 2>&1); RC=$?
after=$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')
if [ "$RC" -eq 1 ] && [ "$after" = "$before" ]; then pass "removed when origin cannot be listed"; else fail "exit $RC, TMPDIR entries $before -> $after"; fi

test_case "no temporary file can be made for git ls-remote's errors (#94 verify)"
D=$(fresh_copy no-tmpdir)
git clone -q --bare "$D" "$SCRATCH/no-tmpdir-origin.git" && git -C "$D" remote add origin "$SCRATCH/no-tmpdir-origin.git" || exit 1
OUT=$(TMPDIR="$SCRATCH/no-such-dir" bash "$CHECK" --root "$D" 2>&1); RC=$?
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q "cannot create a temporary file"; then pass "the tag check fails instead of being skipped"; else fail "exit $RC:"$'\n'"$(printf '%s\n' "$OUT" | tail -2)"; fi

# ---------------------------------------------------------------------- tags
test_case "tag v$X exists locally"
D=$(fresh_copy tag-local); git -C "$D" tag "v$X"
run "$D" --no-remote
if [ "$RC" -eq 1 ]; then pass "exit 1"; else fail "exit $RC"; fi
if printf '%s\n' "$OUT" | grep -qF "tag v$X already exists locally"; then pass "refuses the existing tag"; else fail "no tag refusal:"$'\n'"$OUT"; fi
run "$D" --no-remote --no-tag-check
if [ "$RC" -eq 0 ]; then pass "--no-tag-check skips it (exit 0)"; else fail "--no-tag-check: exit $RC"; fi

test_case "tag v$X exists on origin only"
D=$(fresh_copy tag-remote)
git clone -q --bare "$D" "$SCRATCH/origin.git" && git -C "$D" remote add origin "$SCRATCH/origin.git" || exit 1
run "$D"
if [ "$RC" -eq 0 ]; then pass "no tag anywhere: exit 0"; else fail "no tag anywhere: exit $RC:"$'\n'"$OUT"; fi
git -C "$SCRATCH/origin.git" tag "v$X" HEAD
run "$D"
if [ "$RC" -eq 1 ]; then pass "exit 1"; else fail "exit $RC"; fi
if printf '%s\n' "$OUT" | grep -qF "tag v$X already exists on origin"; then pass "refuses the tag on origin"; else fail "no origin refusal:"$'\n'"$OUT"; fi

test_case "origin cannot be listed"
D=$(fresh_copy tag-unreachable); git -C "$D" remote add origin "$SCRATCH/no-such-origin.git"
run "$D"
if [ "$RC" -eq 1 ]; then pass "fails closed (exit 1)"; else fail "exit $RC"; fi
if printf '%s\n' "$OUT" | grep -qF -- "--no-remote"; then pass "says how to check local tags only"; else fail "no hint:"$'\n'"$OUT"; fi

# --------------------------------------------------------------------- usage
test_case "usage errors"
run "$BASE" --expect latest
if [ "$RC" -eq 2 ]; then pass "--expect latest: exit 2"; else fail "--expect latest: exit $RC"; fi
run "$BASE" --bogus
if [ "$RC" -eq 2 ]; then pass "unknown option: exit 2"; else fail "unknown option: exit $RC"; fi
run "$BASE" --expect-plugin 1.x
if [ "$RC" -eq 2 ]; then pass "--expect-plugin 1.x: exit 2"; else fail "--expect-plugin 1.x: exit $RC"; fi
for opt in --expect --expect-plugin --root; do
    run "$BASE" "$opt" ""
    if [ "$RC" -eq 2 ]; then pass "$opt \"\": exit 2"; else fail "$opt \"\": exit $RC"; fi
done

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
