#!/bin/bash
# Mutation test for test-plugin-layout.sh (#138 verify rounds 1 and 2).
#
# A layout test that never fails is worse than none. Round 1 found the first
# version reported PASS when its own parser crashed; round 2 found blank lines,
# comments, quoted keys, BOMs, non-MCP tools and side-effecting "get_" tools
# that still slipped past it. Each case below copies the plugin into a scratch
# tree, breaks ONE thing, and asserts the layout test catches it with the RIGHT
# check. The real repo is never modified.
#
# Portable: uses perl -pi (not BSD-only `sed -i ''`).
#
# Usage:
#   bash tests/che-telegram-mcp/test-plugin-layout-mutations.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PLUGIN="$(cd "$SCRIPT_DIR/../../plugins/che-telegram-mcp" && pwd)"
LAYOUT_TEST="$SCRIPT_DIR/test-plugin-layout.sh"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/layout-mutations-XXXXXX") || {
    echo "✗ mktemp failed — cannot create a scratch tree" >&2
    exit 1
}
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "✗ scratch dir missing" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

PASSED=0
FAILED=0
ALL="mcp__plugin_che-telegram-mcp_telegram-all__"
BOT="mcp__plugin_che-telegram-mcp_telegram-bot__"

fresh() {   # build a clean scratch copy; echo its plugin dir
    rm -rf "$SCRATCH/tree"
    mkdir -p "$SCRATCH/tree/tests/che-telegram-mcp" "$SCRATCH/tree/plugins" "$SCRATCH/tree/.claude-plugin"
    cp -R "$SRC_PLUGIN" "$SCRATCH/tree/plugins/che-telegram-mcp"
    cp "$LAYOUT_TEST" "$SCRATCH/tree/tests/che-telegram-mcp/"
    cp -R "$SCRIPT_DIR/../lib" "$SCRATCH/tree/tests/lib"
    cp "$SCRIPT_DIR/../../.claude-plugin/marketplace.json" "$SCRATCH/tree/.claude-plugin/"
    echo "$SCRATCH/tree/plugins/che-telegram-mcp"
}

run_layout() {
    bash "$SCRATCH/tree/tests/che-telegram-mcp/test-plugin-layout.sh" 2>&1
}

# expect_fail <name> <pattern> — the layout test must exit non-zero AND print
# the pattern, so the RIGHT check caught it, not an unrelated one
expect_fail() {
    local name="$1" pattern="$2" out rc
    out=$(run_layout); rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "$pattern"; then
        echo "  ✓ $name"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ $name (exit $rc; expected /$pattern/)"
        printf '%s\n' "$out" | sed 's/^/      /'
        FAILED=$((FAILED + 1))
    fi
}
expect_pass() {
    local name="$1" out rc
    out=$(run_layout); rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  ✓ $name"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ $name (exit $rc, expected pass)"
        printf '%s\n' "$out" | sed 's/^/      /'
        FAILED=$((FAILED + 1))
    fi
}
# set_frontmatter_field <file> <key-line-prefix> <replacement lines...>
# Replaces the `allowed-tools` block (key line plus its list/indented lines)
# with the given raw lines. Preserves the file's newline style.
set_allowed() {
    local file="$1"; shift
    python3 - "$file" "$@" <<'EOF'
import sys
path, lines = sys.argv[1], sys.argv[2:]
text = open(path, encoding="utf-8", newline="").read()
nl = "\r\n" if "\r\n" in text else "\n"
head, rest = text.split(nl + "---" + nl, 1)
out, skip = [], False
for line in head.split(nl):
    if line.startswith("allowed-tools:"):
        out.extend(lines); skip = True; continue
    if skip and (line.startswith(" ") or line.startswith("-")):
        continue
    skip = False
    out.append(line)
open(path, "w", encoding="utf-8", newline="").write(nl.join(out) + nl + "---" + nl + rest)
EOF
}
add_bom() { python3 -c 'import sys;p=sys.argv[1];b=open(p,"rb").read();open(p,"wb").write(b"\xef\xbb\xbf"+b)' "$1"; }

echo "test-plugin-layout-mutations.sh (#138)"

# --- baseline and fail-closed ---
P=$(fresh); expect_pass "unmodified copy passes"
P=$(fresh); echo '{ not json' > "$P/.mcp.json"
expect_fail "broken .mcp.json fails closed" "parser crashed"
P=$(fresh); rm "$P/README.md"
expect_fail "missing README fails closed" "parser crashed"

# --- (a) (b) (b2) toolchain contract ---
P=$(fresh); printf '#!/bin/bash\n' > "$P/bin/test-x.sh"; chmod +x "$P/bin/test-x.sh"
expect_fail "test script in bin/" "FAIL \(a\)"
P=$(fresh); printf 'x' > "$P/bin/.DS_Store"
expect_pass ".DS_Store in bin/ is ignored"
P=$(fresh); perl -pi -e 's#/bin/che-telegram-bot#/scripts/che-telegram-bot#' "$P/.mcp.json"
expect_fail ".mcp.json points outside bin/" "FAIL \(b\)"
P=$(fresh); perl -pi -e 's/^DESIRED_VERSION=.*/DESIRED_VERSION="\$X"/' "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "wrapper loses its literal pin" "FAIL \(b2\)"
P=$(fresh); perl -pi -e 's/^(DESIRED_VERSION="[0-9.]+")$/$1\n[ -n "\${TG_PIN:-}" ] && DESIRED_VERSION="\$TG_PIN"/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "conditional override after the literal pin" "FAIL \(b2\)"

# --- (c) hook quoting ---
P=$(fresh); perl -pi -e 's#"\\"\$\{CLAUDE_PLUGIN_ROOT\}\\"/hooks#"\${CLAUDE_PLUGIN_ROOT}/hooks#' "$P/hooks/hooks.json"
expect_fail "unquoted hook path" "FAIL \(c\)"
P=$(fresh); perl -pi -e 's#"\\"\$\{CLAUDE_PLUGIN_ROOT\}\\"/hooks/check-mcp\.sh"#"\\"\${CLAUDE_PLUGIN_ROOT}/hooks/check-mcp.sh\\""#' "$P/hooks/hooks.json"
grep -q 'CLAUDE_PLUGIN_ROOT}/hooks/check-mcp.sh\\""' "$P/hooks/hooks.json" || echo "  ! mutation did not apply: fully quoted hook"
expect_pass "fully quoted hook path is accepted"

# --- (d) what may appear in allowed-tools ---
P=$(fresh); set_allowed "$P/skills/search/SKILL.md" "allowed-tools:" "  - ${ALL}search"
expect_fail "tool that does not exist" "FAIL \(d\)"
P=$(fresh); set_allowed "$P/skills/chats/SKILL.md" "allowed-tools:" "  - ${ALL}ban_chat_member"
expect_fail "bot tool under the all prefix" "not documented under telegram-all"
P=$(fresh); set_allowed "$P/skills/send/SKILL.md" "allowed-tools:" "  - ${ALL}auth_status" "  - Bash"
expect_fail "Bash pre-approved in send" "FAIL \(d\)"

# --- (f) send_message in every YAML spelling ---
P=$(fresh); set_allowed "$P/skills/send/SKILL.md" "allowed-tools:" "  - \"${ALL}send_message\""
expect_fail "quoted value" "FAIL \(f\)"
P=$(fresh); set_allowed "$P/skills/send/SKILL.md" "allowed-tools:" "- ${ALL}send_message"
expect_fail "column-0 list" "FAIL \(f\)"
P=$(fresh); set_allowed "$P/skills/send/SKILL.md" "allowed-tools: [${ALL}auth_status, ${ALL}send_message]"
expect_fail "flow-style list" "FAIL \(f\)"
P=$(fresh); set_allowed "$P/skills/send/SKILL.md" "allowed-tools:" "  - ${ALL}search_chats" "" "  - ${ALL}send_message"
expect_fail "blank line inside the list" "FAIL \(f\)"
P=$(fresh); set_allowed "$P/skills/send/SKILL.md" "allowed-tools:" "  - ${ALL}search_chats" "# note" "  - ${ALL}send_message"
expect_fail "column-0 comment inside the list" "FAIL \(f\)"
P=$(fresh); perl -pi -e 's/^allowed-tools:/"allowed-tools":/' "$P/skills/send/SKILL.md"
set_allowed "$P/skills/send/SKILL.md" "allowed-tools:" >/dev/null 2>&1
perl -0pi -e 's/("allowed-tools":\r?\n)/$1  - '"${ALL}"'send_message\r\n/' "$P/skills/send/SKILL.md"
expect_fail "quoted key" "FAIL \(f\)"
P=$(fresh); set_allowed "$P/skills/send/SKILL.md" "allowed-tools:" "  - ${ALL}send_message"; add_bom "$P/skills/send/SKILL.md"
expect_fail "UTF-8 BOM on send" "FAIL \(f\)"
P=$(fresh); perl -0pi -e 's/^(description: [^\n]*\n)/$1allowed-tools:\n  - '"${ALL}"'send_message\n/m' "$P/skills/telegram-messaging/SKILL.md"; add_bom "$P/skills/telegram-messaging/SKILL.md"
expect_fail "UTF-8 BOM on the model-invocable router" "FAIL \(f\)"

# --- (f) side-effecting tools that are not send_message ---
P=$(fresh); set_allowed "$P/skills/chats/SKILL.md" "allowed-tools:" "  - ${ALL}delete_messages"
expect_fail "delete_messages" "FAIL \(f\)"
P=$(fresh); set_allowed "$P/skills/chats/SKILL.md" "allowed-tools:" "  - ${ALL}dump_chat_to_markdown"
expect_fail "dump_chat_to_markdown (writes files)" "FAIL \(f\)"
P=$(fresh); set_allowed "$P/skills/chats/SKILL.md" "allowed-tools:" "  - ${BOT}get_updates"
expect_fail "bot get_updates (drops updates)" "FAIL \(f\)"
P=$(fresh); set_allowed "$P/skills/chats/SKILL.md" "allowed-tools:" "  - ${ALL}auth_send_phone"
expect_fail "auth step outside the auth skill" "FAIL \(f\)"

# --- (g) (h) (e) (fm) ---
P=$(fresh); rm -r "$P/skills/telegram-messaging"
expect_fail "router skill deleted" "FAIL \(g\)"
P=$(fresh); perl -0pi -e 's/^(description: [^\n]*\n)/$1disable-model-invocation: "true"\n/m' "$P/skills/telegram-messaging/SKILL.md"
expect_fail "router disabled with a quoted value" "FAIL \(g\)"
P=$(fresh); perl -0pi -e 's/^(description: [^\n]*\n)/$1disable-model-invocation: true # temporarily\n/m' "$P/skills/telegram-messaging/SKILL.md"
expect_fail "router disabled with a trailing comment" "FAIL \(g\)"
P=$(fresh); perl -ni -e 'print unless /^disable-model-invocation:/' "$P/skills/send/SKILL.md"
expect_fail "send loses disable-model-invocation" "FAIL \(h\)"
# (h) accepts only the literal true; (g) rejects anything Claude Code may read as true
for v in '1' 'yes' '"true"'; do
    P=$(fresh); DMI="disable-model-invocation: $v" perl -pi -e 's/^disable-model-invocation:.*$/$ENV{DMI}/' "$P/skills/send/SKILL.md"
    expect_fail "send with disable-model-invocation: $v" "FAIL \(h\)"
done
for v in 'on' '1'; do
    P=$(fresh); DMI="disable-model-invocation: $v" perl -0pi -e 's/^(description: [^\n]*\n)/$1$ENV{DMI}\n/m' "$P/skills/telegram-messaging/SKILL.md"
    expect_fail "router disabled with disable-model-invocation: $v" "FAIL \(g\)"
done
# (g): only absent or the literal false keeps the router model-invocable
for v in '1.0' '1e0'; do
    P=$(fresh); DMI="disable-model-invocation: $v" perl -0pi -e 's/^(description: [^\n]*\n)/$1$ENV{DMI}\n/m' "$P/skills/telegram-messaging/SKILL.md"
    expect_fail "router disabled with disable-model-invocation: $v" "FAIL \(g\)"
done
P=$(fresh); perl -0pi -e 's/^(description: [^\n]*\n)/$1disable-model-invocation: false\n/m' "$P/skills/telegram-messaging/SKILL.md"
expect_pass "router with disable-model-invocation: false is accepted"
# (i): no hooks and no !`command` / ```! blocks (they run when the skill is invoked)
P=$(fresh); perl -0pi -e 's/^(description: [^\n]*\n)/$1hooks:\n  PreToolUse:\n    - hooks:\n        - type: command\n          command: "true"\n/m' "$P/skills/chats/SKILL.md"
expect_fail "skill registers hooks" "FAIL \(i\)"
P=$(fresh); printf '\nCurrent date: !`date`\n' >> "$P/skills/chats/SKILL.md"
expect_fail "skill body runs a !\`command\`" "FAIL \(i\)"
P=$(fresh); printf '\n```!\ndate\n```\n' >> "$P/skills/search/SKILL.md"
expect_fail "skill body runs a \`\`\`! block" "FAIL \(i\)"
# A lone CR does not end a line for Claude Code: no frontmatter at all
P=$(fresh); python3 -c 'import sys;p=sys.argv[1];b=open(p,"rb").read().replace(b"\r\n",b"\r");open(p,"wb").write(b)' "$P/skills/send/SKILL.md"
expect_fail "frontmatter with lone-CR line endings is unreadable" "FAIL \(fm\)"
# (fm): the plain YAML subset PyYAML and Claude Code's Bun.YAML read alike
subst() {  # $1 = file, $2 = python expression over bytes b
    python3 -c 'import sys;p=sys.argv[1];b=open(p,"rb").read();b='"$2"';open(p,"wb").write(b)' "$1"
}
P=$(fresh); subst "$P/skills/send/SKILL.md" 'b.replace(b"---\r\n",b"---\xc2\x85\r\n",1)'
expect_fail "NEL after the opening --- (Claude Code's \\s does not match it)" "FAIL \(fm\)"
P=$(fresh); subst "$P/skills/send/SKILL.md" 'b.replace(b"\r\ndisable-model-invocation",b"\xe2\x80\xa8disable-model-invocation",1)'
expect_fail "U+2028 inside send's frontmatter (Bun.YAML rejects the block)" "FAIL \(fm\)"
P=$(fresh); subst "$P/skills/send/SKILL.md" 'b.replace(b"\r\ndisable-model-invocation",b"\xc2\x85disable-model-invocation",1)'
expect_fail "NEL inside send's frontmatter (Bun.YAML drops the block)" "FAIL \(fm\)"
P=$(fresh); perl -0pi -e 's/^(description: [^\n]*\n)/$1? extra\n/m' "$P/skills/chats/SKILL.md"
expect_fail "explicit-key line" "FAIL \(fm\)"
P=$(fresh); perl -0pi -e 's/^(description: [^\n]*\n)/$1_base: &b\n  disable-model-invocation: true\n<<: *b\n/m' "$P/skills/telegram-messaging/SKILL.md"
expect_fail "merge key on the router (outside the subset, so (g) cannot pass)" "FAIL \(g\)"
P=$(fresh); subst "$P/skills/send/SKILL.md" 'b.replace(b"\r\ndisable-model-invocation",b"\xe2\x80\xa9disable-model-invocation",1)'
expect_fail "U+2029 inside send's frontmatter" "FAIL \(fm\)"
P=$(fresh); perl -pi -e 's/^description: [^\r]*/description: "Send a Telegram message\r\nvia: the personal account"/' "$P/skills/send/SKILL.md"
expect_fail "quoted value left open, next line looks like a key (PyYAML joins, Bun rejects)" "FAIL \(fm\)"
P=$(fresh); perl -pi -e 's/^(description: [^\r]*)/$1 .../' "$P/skills/send/SKILL.md"
expect_fail "... inside a value (bun 1.3.11 ends the document there)" "FAIL \(fm\)"
P=$(fresh); perl -pi -e 's/^(description: [^\r]*)/$1 .../' "$P/skills/send/SKILL.md"
expect_fail "unreadable frontmatter makes (h) unverifiable, not passed" "FAIL \(h\)"
P=$(fresh); perl -pi -e 's/^(description: [^\n]*)/$1 .../' "$P/skills/telegram-messaging/SKILL.md"
expect_fail "unreadable router frontmatter makes (g) unverifiable, not passed" "FAIL \(g\)"
# Claude Code ends the frontmatter at the first ---, even inside a value
P=$(fresh); perl -pi -e 's/^description: /description: Send --- /' "$P/skills/send/SKILL.md"
expect_fail "--- inside send's description drops disable-model-invocation" "FAIL \(h\)"
P=$(fresh); mkdir -p "$P/commands"; printf -- '---\nname: x\n---\n' > "$P/commands/x.md"
expect_fail "commands/ reappears" "FAIL \(e\)"
P=$(fresh); perl -0pi -e 's/\A---\r?\n/# notes\n---\n/' "$P/skills/chats/SKILL.md"
expect_fail "skill without readable frontmatter" "FAIL \(fm\)"

# (j) install references name this marketplace (PsychQuant/che-msg#42)
P=$(fresh); perl -pi -e 's/install che-telegram-mcp\@che-msg/install che-telegram-mcp\@psychquant-claude-plugins/' "$P/README.md"
expect_fail "README install id names the old marketplace" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's{marketplace add PsychQuant/che-msg}{marketplace add PsychQuant/psychquant-claude-plugins}' "$P/README.md"
expect_fail "README marketplace add points at the old repository" "FAIL \(j\)"
P=$(fresh); perl -ni -e 'print unless /install che-telegram-mcp\@che-msg/' "$P/README.md"
expect_fail "README never installs from this marketplace" "FAIL \(j\)"
P=$(fresh); printf '\n    claude plugin uninstall che-telegram-mcp@some-old-marketplace\n' >> "$P/README.md"
expect_pass "an uninstall line may name another marketplace"
P=$(fresh); perl -pi -e 's{github\.com/PsychQuant/che-msg/blob}{github.com/PsychQuant/psychquant-claude-plugins/blob}' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "wrapper docsUrl points at the old repository" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's{che-telegram-mcp/README\.md#multi-session}{che-telegram-mcp/READ_ME.md#multi-session}' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "wrapper docsUrl names a file that does not exist" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's/^## Multi-session limitation/## Running two sessions/' "$P/README.md"
expect_fail "wrapper docsUrl anchor no longer matches a README heading" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's/"name": "che-msg"/"name": "other-marketplace"/' "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "marketplace renamed but README and wrapper not" "FAIL \(j\)"
P=$(fresh); rm "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "no marketplace.json makes (j) unverifiable, not passed" "FAIL \(j\)"

# (j) verify round 1 of PsychQuant/che-msg#42: punctuation, per-command uninstall, `..`, fenced headings, repeated and non-ASCII headings
P=$(fresh); printf '\nThen run /plugin install che-telegram-mcp@che-msg.\n' >> "$P/README.md"
expect_pass "install id followed by a full stop"
P=$(fresh); printf '\n    claude plugin uninstall che-telegram-mcp@old-mp; claude plugin install che-telegram-mcp@old-mp\n' >> "$P/README.md"
expect_fail "uninstall and install from the old marketplace on one line" "FAIL \(j\)"
P=$(fresh); printf '\n[x](https://github.com/PsychQuant/che-msg/blob/main/plugins/che-telegram-mcp/../../tests/lib/install_refs.py)\n' >> "$P/README.md"
expect_fail "link that climbs out of the plugin with .." "FAIL \(j\)"
P=$(fresh); perl -pi -e 's/#multi-session-limitation/#1-add-the-marketplace-and-install-the-plugin/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor that only matches a comment inside a code block" "FAIL \(j\)"
P=$(fresh); printf '\n## Dup\n\ntext\n\n## Dup\n' >> "$P/README.md"; perl -pi -e 's/#multi-session-limitation/#dup-1/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor to the second of two identical headings"
P=$(fresh); printf '\n## 遷移步驟\n' >> "$P/README.md"; perl -CSD -pi -e 's/#multi-session-limitation/#\x{9077}\x{79fb}\x{6b65}\x{9a5f}/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor to a heading with non-ASCII letters"

# (j) verify round 2 of PsychQuant/che-msg#42: each case fails or passes differently on the round-1 lib (4106a1f)
P=$(fresh); printf '\nRun `/plugin marketplace add PsychQuant/che-msg`.\n' >> "$P/README.md"
expect_pass "marketplace add in backticks followed by a full stop"
P=$(fresh); printf '\nRun `claude plugin uninstall che-telegram-mcp@old-mp`, then `claude plugin install che-telegram-mcp@old-mp`.\n' >> "$P/README.md"
expect_fail "uninstall and install from the old marketplace in prose, no shell separator" "FAIL \(j\)"
P=$(fresh); printf '\n<https://github.com/PsychQuant/che-msg/tree/main/plugins/che-telegram-mcp/..>\n' >> "$P/README.md"
expect_fail "link ending in /.. climbs out of the plugin" "FAIL \(j\)"
P=$(fresh); printf '\n<https://github.com/PsychQuant/psychquant-claude-plugins/blob/feat/x/plugins/che-telegram-mcp/README.md>\n' >> "$P/README.md"
expect_fail "link to the old repository on a ref that contains /" "FAIL \(j\)"
P=$(fresh); ln -s ../../tests/lib/install_refs.py "$P/escape.md"; printf '\n<https://github.com/PsychQuant/che-msg/blob/main/plugins/che-telegram-mcp/escape.md>\n' >> "$P/README.md"
expect_fail "link to a symlink inside the plugin that resolves outside it" "FAIL \(j\)"
P=$(fresh); printf '\n````markdown\n```bash\n# Fake heading\n```\n````\n' >> "$P/README.md"; perl -pi -e 's/#multi-session-limitation/#fake-heading/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor to a # line inside a four-backtick fence that wraps a three-backtick one" "FAIL \(j\)"
P=$(fresh); printf '\n## Dup\n\n## Dup\n\n## Dup-1\n' >> "$P/README.md"; perl -pi -e 's/#multi-session-limitation/#dup-1-1/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor dup-1-1 (GitHub skips the slug the third heading already took)"
P=$(fresh); printf '\n## 遷移步驟\n' >> "$P/README.md"; perl -CSD -pi -e 's/#multi-session-limitation/#\x{9077}\x{79fb}\x{932f}/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor to a non-ASCII heading that does not exist" "FAIL \(j\)"
P=$(fresh); printf '\n## 遷移步驟\n' >> "$P/README.md"; perl -pi -e 's/#multi-session-limitation/#%E9%81%B7%E7%A7%BB%E6%AD%A5%E9%A9%9F/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor percent-encoded, matching a non-ASCII heading"
P=$(fresh); printf '\n## 遷移步驟\n' >> "$P/README.md"; perl -pi -e 's/#multi-session-limitation/#%E9%81%B7%E7%A7%BB%E9%8C%AF/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor percent-encoded, matching no heading" "FAIL \(j\)"

# (j) verify round 3 of PsychQuant/che-msg#42: URLs read as tokens; each case differs on the round-2 lib (5076746)
P=$(fresh); printf '%s\n' '' 'See https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-telegram-mcp.' >> "$P/README.md"
expect_fail "old-repo URL followed by a full stop" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'See https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-telegram-mcp?plain=1' >> "$P/README.md"
expect_fail "old-repo URL with a query string" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '**https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-telegram-mcp**' >> "$P/README.md"
expect_fail "old-repo URL in bold" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '| x | https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-telegram-mcp|' >> "$P/README.md"
expect_fail "old-repo URL in a table cell" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' http://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-telegram-mcp >> "$P/README.md"
expect_fail "old-repo URL over http://" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'See https://github.com/PsychQuant/che-msg/blob/main/plugins/che-telegram-mcp/README.md.' >> "$P/README.md"
expect_pass "this repository's URL to a file, followed by a full stop"
P=$(fresh); printf '%s\n' '' https://github.com/PsychQuant/che-msg/blob/main/plugins/che-telegram-mcp/readme.md >> "$P/README.md"
expect_fail "URL to README.md spelled readme.md (case-insensitive disk)" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '/plugin marketplace add <PsychQuant/psychquant-claude-plugins>' >> "$P/README.md"
expect_fail "marketplace add <old repo>" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '/plugin marketplace add $REPO' >> "$P/README.md"
expect_fail "marketplace add with a shell variable cannot be checked" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'claude plugin marketplace add --scope user PsychQuant/che-msg' >> "$P/README.md"
expect_pass "marketplace add with --scope before the argument"
P=$(fresh); printf '%s\n' '' 'claude plugin marketplace add \' '  PsychQuant/psychquant-claude-plugins' >> "$P/README.md"
expect_fail "marketplace add continued on the next line" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'claude plugin uninstall --scope user che-telegram-mcp@old-mp' >> "$P/README.md"
expect_pass "uninstall with --scope before the old id"
P=$(fresh); printf '%s\n' '' 'claude plugin uninstall "che-telegram-mcp@old-mp"' >> "$P/README.md"
expect_pass "uninstall with the old id in quotes"
P=$(fresh); printf '%s\n' '' 'claude plugin uninstall \' '  che-telegram-mcp@old-mp' >> "$P/README.md"
expect_pass "uninstall continued on the next line"
P=$(fresh); printf '%s\n' '' 'old-che-telegram-mcp@old-mp is another plugin' >> "$P/README.md"
expect_pass "a longer plugin name ending in this one"
P=$(fresh); printf '%s\n' '' '<!--' '## Hidden' '-->' >> "$P/README.md"; perl -pi -e 's/#multi-session-limitation/#hidden/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor to a heading inside an HTML comment" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '```js```' '## After' >> "$P/README.md"; perl -pi -e 's/#multi-session-limitation/#after/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor to a heading after a one-line triple-backtick span"
P=$(fresh); printf '%s\n' '' '## [Foo](http://x) bar' >> "$P/README.md"; perl -pi -e 's/#multi-session-limitation/#foo-bar/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor to a heading that contains a link"
P=$(fresh); printf '%s\n' '' '> ## Quoted Head' >> "$P/README.md"; perl -pi -e 's/#multi-session-limitation/#quoted-head/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor to a heading inside a block quote"

echo
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
