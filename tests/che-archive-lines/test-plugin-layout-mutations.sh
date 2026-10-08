#!/bin/bash
# Mutation test for tests/che-archive-lines/test-plugin-layout.sh (#139).
#
# Each case copies the plugin into a scratch tree, breaks ONE thing, and
# asserts the layout test catches it with the RIGHT check — including that a
# missing skill fails the checks that read it instead of passing them. The real
# repo is never modified. Portable: perl -pi, not BSD-only `sed -i ''`.
#
# Usage:
#   bash tests/che-archive-lines/test-plugin-layout-mutations.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PLUGIN="$(cd "$SCRIPT_DIR/../../plugins/che-archive-lines" && pwd)"
LAYOUT_TEST="$SCRIPT_DIR/test-plugin-layout.sh"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/archive-lines-mutations-XXXXXX") || {
    echo "✗ mktemp failed — cannot create a scratch tree" >&2
    exit 1
}
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "✗ scratch dir missing" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

PASSED=0
FAILED=0

fresh() {
    rm -rf "$SCRATCH/tree"
    mkdir -p "$SCRATCH/tree/tests/che-archive-lines" "$SCRATCH/tree/plugins" "$SCRATCH/tree/.claude-plugin"
    cp -R "$SRC_PLUGIN" "$SCRATCH/tree/plugins/che-archive-lines"
    cp "$LAYOUT_TEST" "$SCRATCH/tree/tests/che-archive-lines/"
    cp -R "$SCRIPT_DIR/../lib" "$SCRATCH/tree/tests/lib"
    cp "$SCRIPT_DIR/../../.claude-plugin/marketplace.json" "$SCRATCH/tree/.claude-plugin/"
    echo "$SCRATCH/tree/plugins/che-archive-lines"
}
run_layout() { bash "$SCRATCH/tree/tests/che-archive-lines/test-plugin-layout.sh" 2>&1; }
expect_fail() {
    local name="$1" pattern="$2" out rc
    out=$(run_layout); rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "$pattern"; then
        echo "  ✓ $name"; PASSED=$((PASSED + 1))
    else
        echo "  ✗ $name (exit $rc; expected /$pattern/)"
        printf '%s\n' "$out" | sed 's/^/      /'; FAILED=$((FAILED + 1))
    fi
}
expect_pass() {
    local name="$1" out rc
    out=$(run_layout); rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  ✓ $name"; PASSED=$((PASSED + 1))
    else
        echo "  ✗ $name (exit $rc, expected pass)"
        printf '%s\n' "$out" | sed 's/^/      /'; FAILED=$((FAILED + 1))
    fi
}
add_bom() { python3 -c 'import sys;p=sys.argv[1];b=open(p,"rb").read();open(p,"wb").write(b"\xef\xbb\xbf"+b)' "$1"; }
set_allowed() {  # $1 = file, $2 = replacement for the whole allowed-tools block (key + list items)
    ALLOWED_LINE="$2" perl -0pi -e 's/^allowed-tools:[^\n]*\n(?:[ \t]+-[^\n]*\n)*/$ENV{ALLOWED_LINE}\n/m' "$1"
}
set_dmi() {  # $1 = file, $2 = replacement for the whole disable-model-invocation line
    DMI_LINE="$2" perl -pi -e 's/^disable-model-invocation:.*$/$ENV{DMI_LINE}/' "$1"
}
SKILL=skills/archive-lines/SKILL.md
S='${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh'
R_SAVE="Bash($S save)"; R_TEST="Bash($S test)"; R_HELP="Bash($S help)"; R_CAL="Bash($S calibrate)"
SAVE_CMD='"${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh" save'
replace_save() {  # $1 = file, $2 = replacement for the save invocation
    FROM="$SAVE_CMD" TO="$2" perl -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$1"
}

echo "test-plugin-layout-mutations.sh (#139)"

P=$(fresh); expect_pass "unmodified copy passes"
P=$(fresh); add_bom "$P/$SKILL"
expect_pass "UTF-8 BOM on the skill is accepted"
P=$(fresh); set_allowed "$P/$SKILL" "allowed-tools: $R_HELP $R_SAVE $R_TEST"
expect_pass "allowed-tools as a one-line string, in another order, is accepted"

P=$(fresh); perl -0pi -e 's/\A---\n/---\nallowed-tools: [Read\n/' "$P/$SKILL"
expect_fail "broken YAML is never parsed (outside the subset)" "FAIL \(fm\)"

P=$(fresh); mkdir -p "$P/commands"; printf -- '---\ndescription: x\n---\n' > "$P/commands/archive-lines.md"
expect_fail "commands/ reappears" "FAIL \(a\)"

P=$(fresh); rm "$P/$SKILL"
expect_fail "skill deleted: (b) fails" "FAIL \(b\)"
expect_fail "skill deleted: (e) does not pass silently" "FAIL \(e\)"
expect_fail "skill deleted: (f) does not pass silently" "FAIL \(f\)"
expect_fail "skill deleted: (n) does not pass silently" "FAIL \(n\)"

P=$(fresh); chmod -x "$P/scripts/line-save-chat.sh"
expect_fail "script not executable" "FAIL \(b\)"

# ---- (b)/(c): every invocation, every spelling ----
P=$(fresh); replace_save "$P/$SKILL" './scripts/line-save-chat.sh save'
expect_fail "relative ./scripts/ path" "FAIL \(b\)"
P=$(fresh); replace_save "$P/$SKILL" 'bash scripts/line-save-chat.sh save'
expect_fail "relative scripts/ path without ./" "FAIL \(b\)"
P=$(fresh); replace_save "$P/$SKILL" '"$CLAUDE_PLUGIN_ROOT/scripts/line-save-chat.sh" save'
expect_fail "unbraced \$CLAUDE_PLUGIN_ROOT" "FAIL \(c\)"
P=$(fresh); printf '\nSCRIPT_DIR="$(dirname "$0")"\n' >> "$P/$SKILL"
expect_fail "\$(dirname \"\$0\") derivation" "FAIL \(c\)"
P=$(fresh); printf '\nSCRIPT_DIR="${0%%/*}/scripts"\n' >> "$P/$SKILL"
expect_fail "\${0%%/*} derivation" "FAIL \(c\)"

# ---- (d): per-machine paths, including files that are not valid UTF-8 ----
P=$(fresh); printf '\nSee /Users/example/notes for details.\n' >> "$P/README.md"
expect_fail "home-directory path in README" "FAIL \(d\)"
P=$(fresh); printf '\nScript: ~/Library/CloudStorage/Dropbox/x/run.sh\n' >> "$P/$SKILL"
expect_fail "CloudStorage path in the skill" "FAIL \(d\)"
P=$(fresh); printf '\nScript: ~/Dropbox/che_workspace/x/run.sh\n' >> "$P/README.md"
expect_fail "legacy ~/Dropbox path" "FAIL \(d\)"
P=$(fresh); printf '\nScript: ~/Library/Mobile Documents/com~apple~CloudDocs/x.sh\n' >> "$P/README.md"
expect_fail "iCloud Drive path" "FAIL \(d\)"
P=$(fresh); printf '\n\xff /Users/example/secret/\n' >> "$P/README.md"
expect_fail "home path in a file that is not valid UTF-8" "FAIL \(d\)"
P=$(fresh); python3 -c 'import sys;p=sys.argv[1];t=open(p,encoding="utf-8").read();open(p,"w",encoding="utf-16").write(t+"\nSee /Users/example/secret/\n")' "$P/README.md"
expect_fail "home path in a UTF-16 file" "FAIL \(d\)"

# ---- (e): exactly the three exact rules; nothing runs outside them ----
P=$(fresh); set_allowed "$P/$SKILL" 'allowed-tools: Bash(*), Read, Write, Glob'
expect_fail "allowed-tools back to Bash(*)" "FAIL \(e\)"
P=$(fresh); set_allowed "$P/$SKILL" "allowed-tools: Bash($S *)"
expect_fail "trailing-* rule (also pre-approves calibrate and piped input)" "FAIL \(e\)"
P=$(fresh); set_allowed "$P/$SKILL" 'allowed-tools: Bash(bash *line-save-chat.sh *)'
expect_fail "leading-wildcard rule (also matches bash -c)" "FAIL \(e\)"
P=$(fresh); set_allowed "$P/$SKILL" "allowed-tools: $R_SAVE $R_TEST $R_HELP $R_CAL"
expect_fail "calibrate rule added" "FAIL \(e\)"
P=$(fresh); set_allowed "$P/$SKILL" "allowed-tools: $R_SAVE $R_TEST $R_HELP Read"
expect_fail "bare Read added next to the rules" "FAIL \(e\)"
P=$(fresh); set_allowed "$P/$SKILL" "allowed-tools: $R_SAVE $R_TEST"
expect_fail "help rule missing" "FAIL \(e\)"
P=$(fresh); set_allowed "$P/$SKILL" "\"allowed-tools\":
  - $R_SAVE
  - $R_TEST
  - $R_HELP

  - Write"
expect_fail "quoted key + blank line hides Write" "FAIL \(e\)"
P=$(fresh); set_allowed "$P/$SKILL" 'allowed-tools: Bash(*)'; add_bom "$P/$SKILL"
expect_fail "BOM does not hide Bash(*)" "FAIL \(e\)"
P=$(fresh); perl -0pi -e 's/^(description: [^\n]*\n)/$1hooks:\n  PreToolUse:\n    - hooks:\n        - type: command\n          command: "true"\n/m' "$P/$SKILL"
expect_fail "skill registers hooks" "FAIL \(e\)"
P=$(fresh); printf '\nCurrent date: !`date`\n' >> "$P/$SKILL"
expect_fail "skill body runs a !\`command\`" "FAIL \(e\)"
P=$(fresh); printf '\n```!\ndate\n```\n' >> "$P/$SKILL"
expect_fail "skill body runs a \`\`\`! block" "FAIL \(e\)"

# ---- (f): only the literal true; the frontmatter boundary Claude Code uses ----
P=$(fresh); perl -ni -e 'print unless /^disable-model-invocation:/' "$P/$SKILL"
expect_fail "disable-model-invocation removed" "FAIL \(f\)"
P=$(fresh); set_dmi "$P/$SKILL" 'disable-model-invocation: false # temporarily'
expect_fail "disable-model-invocation false with a comment" "FAIL \(f\)"
P=$(fresh); set_dmi "$P/$SKILL" 'disable-model-invocation: 1'
expect_fail "disable-model-invocation: 1" "FAIL \(f\)"
P=$(fresh); set_dmi "$P/$SKILL" 'disable-model-invocation: yes'
expect_fail "disable-model-invocation: yes" "FAIL \(f\)"
P=$(fresh); set_dmi "$P/$SKILL" 'disable-model-invocation: "true"'
expect_fail "disable-model-invocation: \"true\" (quoted)" "FAIL \(f\)"
P=$(fresh); perl -pi -e 's/^description: /description: LINE --- /' "$P/$SKILL"
expect_fail "--- inside a value ends the frontmatter early (as in Claude Code)" "FAIL \(f\)"

P=$(fresh); python3 -c 'import sys;p=sys.argv[1];b=open(p,"rb").read().replace(b"\n",b"\r");open(p,"wb").write(b)' "$P/$SKILL"
expect_fail "lone-CR line endings: Claude Code reads no frontmatter" "FAIL \(fm\)"

# ---- (fm): the plain YAML subset PyYAML and Claude Code's Bun.YAML read alike ----
subst() {  # $1 = file, $2 = python expression over bytes b
    python3 -c 'import sys;p=sys.argv[1];b=open(p,"rb").read();b='"$2"';open(p,"wb").write(b)' "$1"
}
P=$(fresh); subst "$P/$SKILL" 'b.replace(b"---\n",b"---\xc2\x85\n",1)'
expect_fail "NEL after the opening --- (Claude Code's \\s does not match it)" "FAIL \(fm\)"
P=$(fresh); subst "$P/$SKILL" 'b.replace(b"\ndisable-model-invocation",b"\xe2\x80\xa8disable-model-invocation",1)'
expect_fail "U+2028 inside the frontmatter (Bun.YAML rejects the block)" "FAIL \(fm\)"
P=$(fresh); subst "$P/$SKILL" 'b.replace(b"\ndisable-model-invocation",b"\xc2\x85disable-model-invocation",1)'
expect_fail "NEL inside the frontmatter (Claude Code's re-parse loses disable-model-invocation)" "FAIL \(fm\)"
P=$(fresh); perl -0pi -e 's/^(description: [^\n]*\n)/$1? extra\n/m' "$P/$SKILL"
expect_fail "explicit-key line" "FAIL \(fm\)"
P=$(fresh); perl -pi -e 's/^name: archive-lines$/name: &n archive-lines/' "$P/$SKILL"
expect_fail "anchor in a value" "FAIL \(fm\)"

P=$(fresh); subst "$P/$SKILL" 'b.replace(b"\ndisable-model-invocation",b"\xe2\x80\xa9disable-model-invocation",1)'
expect_fail "U+2029 inside the frontmatter" "FAIL \(fm\)"
P=$(fresh); perl -pi -e 's/^description: .*$/description: "Save the current LINE chat\nvia: the bundled script"/' "$P/$SKILL"
expect_fail "quoted value left open, next line looks like a key (PyYAML joins, Bun rejects)" "FAIL \(fm\)"
P=$(fresh); perl -pi -e 's/^(disable-model-invocation: true)$/$1\ndescription: "Save the LINE chat #x\ndisable-model-invocation: false\n#"/' "$P/$SKILL"; perl -ni -e 'print unless /^description: [^"]/' "$P/$SKILL"
expect_fail "open quote that Claude Code's re-parse turns into disable-model-invocation: false" "FAIL \(fm\)"
P=$(fresh); perl -pi -e 's/^(description: .*)$/$1 .../' "$P/$SKILL"
expect_fail "... inside a value (bun 1.3.11 ends the document there)" "FAIL \(fm\)"
P=$(fresh); perl -pi -e 's/^name: archive-lines$/name:\tarchive-lines/' "$P/$SKILL"
expect_fail "tab in the frontmatter" "FAIL \(fm\)"
P=$(fresh); perl -0pi -e 's/^(name: archive-lines\n)/$1name: other\n/m' "$P/$SKILL"
expect_fail "duplicate key" "FAIL \(fm\)"
P=$(fresh); perl -0pi -e 's/^(argument-hint: [^\n]*\n)/$1  - stray\n/m' "$P/$SKILL"
expect_fail "list item under a key that has a value" "FAIL \(fm\)"

# ---- (e): only the reviewed frontmatter keys ----
P=$(fresh); perl -0pi -e 's/^(description: [^\n]*\n)/$1model: opus\n/m' "$P/$SKILL"
expect_fail "unreviewed frontmatter key (model)" "FAIL \(e\)"

# ---- (a): nothing outside the reviewed components can run commands ----
P=$(fresh); mkdir -p "$P/hooks"; printf '{"hooks":{}}\n' > "$P/hooks/hooks.json"
expect_fail "hooks/hooks.json added" "FAIL \(a\)"
P=$(fresh); printf '{"mcpServers":{}}\n' > "$P/.mcp.json"
expect_fail ".mcp.json added" "FAIL \(a\)"
P=$(fresh); python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["hooks"]={"SessionStart":[]};json.dump(d,open(p,"w"))' "$P/.claude-plugin/plugin.json"
expect_fail "plugin.json declares hooks" "FAIL \(a\)"
P=$(fresh); mkdir -p "$P/skills/other"; printf -- '---\nname: other\ndescription: x\nallowed-tools: Bash(*)\n---\n' > "$P/skills/other/SKILL.md"
expect_fail "a second skill" "FAIL \(a\)"

P=$(fresh); mkdir -p "$P/bin"; printf '#!/bin/bash\n' > "$P/bin/line-save-chat.sh"
expect_fail "bin/ added" "FAIL \(a\)"
P=$(fresh); python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));[e.update(hooks={"SessionStart":[]}) for e in d["plugins"] if e["name"]=="che-archive-lines"];json.dump(d,open(p,"w"))' "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "marketplace entry declares hooks" "FAIL \(a\)"
P=$(fresh); python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));[e.update(source={"source":"github","repo":"someone/else"}) for e in d["plugins"] if e["name"]=="che-archive-lines"];json.dump(d,open(p,"w"))' "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "marketplace entry source points elsewhere" "FAIL \(a\)"

# ---- (n) ----
P=$(fresh); perl -ni -e 'print unless /^name:/' "$P/$SKILL"
expect_fail "name removed (no bare /archive-lines alias)" "FAIL \(n\)"

# (j) install references name this marketplace (PsychQuant/che-msg#42)
P=$(fresh); perl -pi -e 's/install che-archive-lines\@che-msg/install che-archive-lines\@psychquant-claude-plugins/' "$P/README.md"
expect_fail "README install id names the old marketplace" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's{marketplace add PsychQuant/che-msg}{marketplace add PsychQuant/psychquant-claude-plugins}' "$P/README.md"
expect_fail "README marketplace add points at the old repository" "FAIL \(j\)"
P=$(fresh); perl -ni -e 'print unless /install che-archive-lines\@che-msg/' "$P/README.md"
expect_fail "README never installs from this marketplace" "FAIL \(j\)"
P=$(fresh); printf '\n    claude plugin uninstall che-archive-lines@some-old-marketplace\n' >> "$P/README.md"
expect_pass "an uninstall line may name another marketplace"
P=$(fresh); perl -pi -e 's/"name": "che-msg"/"name": "other-marketplace"/' "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "marketplace renamed but README not" "FAIL \(j\)"
P=$(fresh); rm "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "no marketplace.json makes (j) unverifiable, not passed" "FAIL \(j\)"
P=$(fresh); printf '\n\xff\n' >> "$P/README.md"
expect_fail "README that is not UTF-8 makes (j) unverifiable, not passed" "FAIL \(j\)"
P=$(fresh); printf '\n\xff\n' >> "$P/README.md"
expect_fail "README that is not UTF-8 still lets (a) run (no parser crash)" "PASS \(a\)"

# (j) verify round 1 of PsychQuant/che-msg#42: punctuation, per-command uninstall, `..`
P=$(fresh); printf '\nThen run /plugin install che-archive-lines@che-msg.\n' >> "$P/README.md"
expect_pass "install id followed by a full stop"
P=$(fresh); printf '\n    claude plugin uninstall che-archive-lines@old-mp; claude plugin install che-archive-lines@old-mp\n' >> "$P/README.md"
expect_fail "uninstall and install from the old marketplace on one line" "FAIL \(j\)"
P=$(fresh); printf '\n[x](https://github.com/PsychQuant/che-msg/blob/main/plugins/che-archive-lines/../../tests/lib/install_refs.py)\n' >> "$P/README.md"
expect_fail "link that climbs out of the plugin with .." "FAIL \(j\)"

# (j) verify round 2 of PsychQuant/che-msg#42: each case fails or passes differently on the round-1 lib (4106a1f)
P=$(fresh); printf '\nRun `/plugin marketplace add PsychQuant/che-msg`.\n' >> "$P/README.md"
expect_pass "marketplace add in backticks followed by a full stop"
P=$(fresh); printf '\nRun `claude plugin uninstall che-archive-lines@old-mp`, then `claude plugin install che-archive-lines@old-mp`.\n' >> "$P/README.md"
expect_fail "uninstall and install from the old marketplace in prose, no shell separator" "FAIL \(j\)"
P=$(fresh); printf '\n<https://github.com/PsychQuant/che-msg/tree/main/plugins/che-archive-lines/..>\n' >> "$P/README.md"
expect_fail "link ending in /.. climbs out of the plugin" "FAIL \(j\)"
P=$(fresh); printf '\n<https://github.com/PsychQuant/psychquant-claude-plugins/blob/feat/x/plugins/che-archive-lines/README.md>\n' >> "$P/README.md"
expect_fail "link to the old repository on a ref that contains /" "FAIL \(j\)"

# (j) verify round 3 of PsychQuant/che-msg#42: URLs read as tokens; each case differs on the round-2 lib (5076746)
P=$(fresh); printf '%s\n' '' 'See https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-archive-lines.' >> "$P/README.md"
expect_fail "old-repo URL followed by a full stop" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'See https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-archive-lines?plain=1' >> "$P/README.md"
expect_fail "old-repo URL with a query string" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '**https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-archive-lines**' >> "$P/README.md"
expect_fail "old-repo URL in bold" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '| x | https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-archive-lines|' >> "$P/README.md"
expect_fail "old-repo URL in a table cell" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' http://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-archive-lines >> "$P/README.md"
expect_fail "old-repo URL over http://" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'See https://github.com/PsychQuant/che-msg/blob/main/plugins/che-archive-lines/README.md.' >> "$P/README.md"
expect_pass "this repository's URL to a file, followed by a full stop"
P=$(fresh); printf '%s\n' '' https://github.com/PsychQuant/che-msg/blob/main/plugins/che-archive-lines/readme.md >> "$P/README.md"
expect_fail "URL to README.md spelled readme.md (case-insensitive disk)" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '/plugin marketplace add <PsychQuant/psychquant-claude-plugins>' >> "$P/README.md"
expect_fail "marketplace add <old repo>" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '/plugin marketplace add $REPO' >> "$P/README.md"
expect_fail "marketplace add with a shell variable cannot be checked" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'claude plugin marketplace add --scope user PsychQuant/che-msg' >> "$P/README.md"
expect_pass "marketplace add with --scope before the argument"
P=$(fresh); printf '%s\n' '' 'claude plugin marketplace add \' '  PsychQuant/psychquant-claude-plugins' >> "$P/README.md"
expect_fail "marketplace add continued on the next line" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'claude plugin uninstall --scope user che-archive-lines@old-mp' >> "$P/README.md"
expect_pass "uninstall with --scope before the old id"
P=$(fresh); printf '%s\n' '' 'claude plugin uninstall "che-archive-lines@old-mp"' >> "$P/README.md"
expect_pass "uninstall with the old id in quotes"
P=$(fresh); printf '%s\n' '' 'claude plugin uninstall \' '  che-archive-lines@old-mp' >> "$P/README.md"
expect_pass "uninstall continued on the next line"
P=$(fresh); printf '%s\n' '' 'old-che-archive-lines@old-mp is another plugin' >> "$P/README.md"
expect_pass "a longer plugin name ending in this one"
P=$(fresh); ln -s ../../tests/lib/install_refs.py "$P/escape.md"; printf '%s\n' '' '<https://github.com/PsychQuant/che-msg/blob/main/plugins/che-archive-lines/escape.md>' >> "$P/README.md"
expect_fail "link to a symlink inside the plugin that resolves outside it" "FAIL \(j\)"

echo
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
