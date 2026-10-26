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
    cp "$SCRIPT_DIR/../../README.md" "$SCRATCH/tree/"
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
# expect_fast_pass <name> <seconds> — as expect_pass, and the layout test must
# also finish within <seconds> (perl's alarm kills it otherwise)
expect_fast_pass() {
    local name="$1" secs="$2" out rc
    out=$(perl -e 'alarm shift; exec @ARGV' "$secs" bash "$SCRATCH/tree/tests/che-telegram-mcp/test-plugin-layout.sh" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  ✓ $name"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ $name (exit $rc; 142 = killed after ${secs}s)"
        printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
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
expect_fail "broken .mcp.json fails closed, and says why (#54 verify: no longer a parser crash)" "\.mcp\.json cannot be read"
P=$(fresh); rm "$P/README.md"
expect_fail "missing README fails closed" "parser crashed"

# --- (a) (b) (b2) toolchain contract ---
P=$(fresh); printf '#!/bin/bash\n' > "$P/bin/test-x.sh"; chmod +x "$P/bin/test-x.sh"
expect_fail "test script in bin/" "FAIL \(a\)"
P=$(fresh); printf 'x' > "$P/bin/.DS_Store"
expect_pass ".DS_Store in bin/ is ignored"
P=$(fresh); rm "$P/lib/download.sh"
expect_fail "lib/download.sh missing (#56)" "sources lib/download\.sh, which is not a regular file"
P=$(fresh); perl -pi -e 's#lib/download\.sh#lib/nowhere.sh#' "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "a wrapper sources a lib file that does not exist (#56)" "che-telegram-bot-mcp-wrapper\.sh sources lib/nowhere\.sh"
P=$(fresh); perl -pi -e 's#/bin/che-telegram-bot#/scripts/che-telegram-bot#' "$P/.mcp.json"
expect_fail ".mcp.json points outside bin/" "FAIL \(b\)"
P=$(fresh); perl -pi -e 's/^DESIRED_VERSION=.*/DESIRED_VERSION="\$X"/' "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "wrapper loses its literal pin" "FAIL \(b2\)"
P=$(fresh); perl -pi -e 's/^(DESIRED_VERSION="[0-9.]+")$/$1\n[ -n "\${TG_PIN:-}" ] && DESIRED_VERSION="\$TG_PIN"/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "conditional override after the literal pin" "FAIL \(b2\)"

# --- (b3) the sha256 pin (#50) ---
HEX=$(printf '%064d' 0 | tr 0 a)
DV=$(sed -n 's/^DESIRED_VERSION="\(.*\)"$/\1/p' "$SRC_PLUGIN/bin/che-telegram-all-mcp-wrapper.sh")
P=$(fresh); perl -pi -e "s/^SHA256_PIN_VERSION=.*/SHA256_PIN_VERSION=\"$DV\"/; s/^SHA256_PIN=.*/SHA256_PIN=\"$HEX\"/" "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "a pin for DESIRED_VERSION passes (#50)"
P=$(fresh); perl -pi -e "s/^SHA256_PIN_VERSION=.*/SHA256_PIN_VERSION=\"0.0.1\"/; s/^SHA256_PIN=.*/SHA256_PIN=\"$HEX\"/" "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "a pin left from another version (#50)" "pins a sha256 for v0\.0\.1, but DESIRED_VERSION is"
P=$(fresh); perl -pi -e "s/^SHA256_PIN_VERSION=.*/SHA256_PIN_VERSION=\"\"/; s/^SHA256_PIN=.*/SHA256_PIN=\"$HEX\"/" "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "a pin without its version (#50)" "sets only one of SHA256_PIN_VERSION and SHA256_PIN"
P=$(fresh); perl -pi -e "s/^SHA256_PIN=.*/SHA256_PIN=\"\"/" "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "a version without its pin (#50)" "sets only one of SHA256_PIN_VERSION and SHA256_PIN"
P=$(fresh); perl -pi -e "s/^SHA256_PIN_VERSION=.*/SHA256_PIN_VERSION=\"\"/; s/^SHA256_PIN=.*/SHA256_PIN=\"\"/" "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_pass "no pin at all passes (#50)"
P=$(fresh); perl -pi -e "s/^SHA256_PIN_VERSION=.*/SHA256_PIN_VERSION=\"$DV\"/; s/^SHA256_PIN=.*/SHA256_PIN=\"\U$HEX\E\"/" "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "an uppercase pin (#50)" "must assign SHA256_PIN exactly once, as a literal empty or 64"
HEX63=${HEX:1}
P=$(fresh); perl -pi -e "s/^SHA256_PIN_VERSION=.*/SHA256_PIN_VERSION=\"$DV\"/; s/^SHA256_PIN=.*/SHA256_PIN=\"$HEX63\"/" "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "a pin of 63 digits (#50)" "must assign SHA256_PIN exactly once"
P=$(fresh); perl -pi -e 's/^(SHA256_PIN="[^"]*")$/$1\n[ -n "\${TG_SHA:-}" ] && SHA256_PIN="\$TG_SHA"/' "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "a conditional override of the pin (#50)" "must assign SHA256_PIN exactly once.*found 2"
P=$(fresh); perl -ni -e 'print unless /^SHA256_PIN_VERSION=/' "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "the pin version line missing (#50)" "must assign SHA256_PIN_VERSION exactly once"

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
P=$(fresh); perl -pi -e 's{che-telegram-mcp/README\.md#when-telegram-all}{che-telegram-mcp/READ_ME.md#when-telegram-all}' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "wrapper docsUrl names a file that does not exist" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's/^### When telegram-all does not start/### Startup problems/' "$P/README.md"
expect_fail "wrapper docsUrl anchor no longer matches a README heading" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's/"name": "che-msg"/"name": "other-marketplace"/' "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "marketplace renamed but README and wrapper not" "FAIL \(j\)"
P=$(fresh); rm "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "no marketplace.json makes (j) unverifiable, not passed" "FAIL \(j\)"

# (j) verify round 1 of PsychQuant/che-msg#42: punctuation, per-command uninstall, fenced headings, repeated and non-ASCII headings
P=$(fresh); printf '\nThen run /plugin install che-telegram-mcp@che-msg.\n' >> "$P/README.md"
expect_pass "install id followed by a full stop"
P=$(fresh); printf '\n    claude plugin uninstall che-telegram-mcp@old-mp; claude plugin install che-telegram-mcp@old-mp\n' >> "$P/README.md"
expect_fail "uninstall and install from the old marketplace on one line" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's/#when-telegram-all-does-not-start/#1-add-the-marketplace-and-install-the-plugin/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor that only matches a comment inside a code block" "FAIL \(j\)"
P=$(fresh); printf '\n## Dup\n\ntext\n\n## Dup\n' >> "$P/README.md"; perl -pi -e 's/#when-telegram-all-does-not-start/#dup-1/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor to the second of two identical headings"
P=$(fresh); printf '\n## 遷移步驟\n' >> "$P/README.md"; perl -CSD -pi -e 's/#when-telegram-all-does-not-start/#\x{9077}\x{79fb}\x{6b65}\x{9a5f}/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor to a heading with non-ASCII letters"

# (j) verify round 2 of PsychQuant/che-msg#42
P=$(fresh); printf '\nRun `/plugin marketplace add PsychQuant/che-msg`.\n' >> "$P/README.md"
expect_pass "marketplace add in backticks followed by a full stop"
P=$(fresh); printf '\nRun `claude plugin uninstall che-telegram-mcp@old-mp`, then `claude plugin install che-telegram-mcp@old-mp`.\n' >> "$P/README.md"
expect_fail "uninstall and install from the old marketplace in prose, no shell separator" "FAIL \(j\)"
P=$(fresh); printf '\n<https://github.com/PsychQuant/psychquant-claude-plugins/blob/feat/x/plugins/che-telegram-mcp/README.md>\n' >> "$P/README.md"
expect_fail "link to the old repository on a ref that contains /" "FAIL \(j\)"
P=$(fresh); printf '\n````markdown\n```bash\n# Fake heading\n```\n````\n' >> "$P/README.md"; perl -pi -e 's/#when-telegram-all-does-not-start/#fake-heading/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor to a # line inside a four-backtick fence that wraps a three-backtick one" "FAIL \(j\)"
P=$(fresh); printf '\n## Dup\n\n## Dup\n\n## Dup-1\n' >> "$P/README.md"; perl -pi -e 's/#when-telegram-all-does-not-start/#dup-1-1/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor dup-1-1 (GitHub skips the slug the third heading already took)"
P=$(fresh); printf '\n## 遷移步驟\n' >> "$P/README.md"; perl -CSD -pi -e 's/#when-telegram-all-does-not-start/#\x{9077}\x{79fb}\x{932f}/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor to a non-ASCII heading that does not exist" "FAIL \(j\)"
P=$(fresh); printf '\n## 遷移步驟\n' >> "$P/README.md"; perl -pi -e 's/#when-telegram-all-does-not-start/#%E9%81%B7%E7%A7%BB%E6%AD%A5%E9%A9%9F/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor percent-encoded, matching a non-ASCII heading"
P=$(fresh); printf '\n## 遷移步驟\n' >> "$P/README.md"; perl -pi -e 's/#when-telegram-all-does-not-start/#%E9%81%B7%E7%A7%BB%E9%8C%AF/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor percent-encoded, matching no heading" "FAIL \(j\)"

# (j) verify round 3 of PsychQuant/che-msg#42
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
P=$(fresh); perl -pi -e 's{che-telegram-mcp/README\.md#}{che-telegram-mcp/readme.md#}' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl to README.md spelled readme.md (case-insensitive disk)" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '/plugin marketplace add <PsychQuant/psychquant-claude-plugins>' >> "$P/README.md"
expect_fail "marketplace add <old repo>" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's{marketplace add PsychQuant/che-msg}{marketplace add --scope user PsychQuant/che-msg}' "$P/README.md"
expect_pass "marketplace add with --scope before the argument, and no other marketplace add"
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
P=$(fresh); printf '%s\n' '' '<!--' '## Hidden' '-->' >> "$P/README.md"; perl -pi -e 's/#when-telegram-all-does-not-start/#hidden/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor to a heading inside an HTML comment" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '```js```' '## After' >> "$P/README.md"; perl -pi -e 's/#when-telegram-all-does-not-start/#after/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor to a heading after a one-line triple-backtick span"
P=$(fresh); printf '%s\n' '' '## [Foo](http://x) bar' >> "$P/README.md"; perl -pi -e 's/#when-telegram-all-does-not-start/#foo-bar/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_pass "docsUrl anchor to a heading that contains a link"

# (j) verify round 4 of PsychQuant/che-msg#42: the former name is found by itself, not
# by parsing URLs; each case differs on the round-3 lib (868c2dd) unless marked
P=$(fresh); printf '%s\n' '' 'See https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-telegram-mcp。' >> "$P/README.md"
expect_fail "old-repo URL followed by a full-width full stop" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '見https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-telegram-mcp說明' >> "$P/README.md"
expect_fail "old-repo URL run into Chinese text on both sides" "FAIL \(j\)"
P=$(fresh); printf '\nSee https://github.com/PsychQuant/psychquant\xe2\x80\x8b-claude-plugins/tree/main/plugins/che-telegram-mcp\n' >> "$P/README.md"
expect_fail "old repository name with a zero-width space inside it (regression lock)" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'https://raw.githubusercontent.com/PsychQuant/psychquant-claude-plugins/main/plugins/che-telegram-mcp/README.md' >> "$P/README.md"
expect_fail "old-repo raw.githubusercontent.com URL" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'https://github.com/PsychQuant/psychquant-claude-plugins/edit/main/plugins/che-telegram-mcp/README.md' >> "$P/README.md"
expect_fail "old-repo /edit/ URL" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'https://github.com/PsychQuant/psychquant-claude-plugins/blame/main/plugins/che-telegram-mcp/README.md' >> "$P/README.md"
expect_fail "old-repo /blame/ URL" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'claude plugin marketplace add PsychQuant/che-msg && claude plugin marketplace add PsychQuant/psychquant-claude-plugins' >> "$P/README.md"
expect_fail "second marketplace add on one line names the old repository" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '/plugin Marketplace Add PsychQuant/PsychQuant-Claude-Plugins' >> "$P/README.md"
expect_fail "marketplace add of the old repository in other letter case" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '/plugin marketplace add PsychQuant／psychquant-claude-plugins' >> "$P/README.md"
expect_fail "old repository after a full-width slash (regression lock)" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '請執行 /plugin install 安裝che-telegram-mcp@psychquant-claude-plugins' >> "$P/README.md"
expect_fail "old install id run into Chinese text" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '/plugin install x_che-telegram-mcp@old-mp' >> "$P/README.md"
expect_fail "install id after an underscore" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'git clone https://github.com/PsychQuant/psychquant-claude-plugins.git' >> "$P/README.md"
expect_fail "clone URL of the old repository" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'Source: https://github.com/PsychQuant/psychquant-claude-plugins' >> "$P/README.md"
expect_fail "link to the old repository's front page" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'See [#999](https://github.com/PsychQuant/psychquant-claude-plugins/issues/999) and [#998](https://github.com/PsychQuant/psychquant-claude-plugins/pull/998).' >> "$P/README.md"
expect_pass "issue and pull request links to the old repository are history (regression lock)"
P=$(fresh); printf '%s\n' '' 'Run `marketplace add` before you install anything.' >> "$P/README.md"
expect_pass "marketplace add mentioned in prose"
P=$(fresh); perl -ni -e 'print unless m{marketplace add PsychQuant/che-msg}' "$P/README.md"
expect_fail "README never says marketplace add .../che-msg" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '> ```' '> # Fake' '> ```' >> "$P/README.md"; perl -pi -e 's/#when-telegram-all-does-not-start/#fake/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor to a # line inside a fence inside a block quote" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' '> ## Quoted Head' >> "$P/README.md"; perl -pi -e 's/#when-telegram-all-does-not-start/#quoted-head/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl anchor to a heading inside a block quote is not counted (fails closed)" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's{github\.com/PsychQuant/che-msg/blob}{github.com/someone-else/che-msg/blob}' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "docsUrl owner differs from the wrapper's GITHUB_REPO" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '# docsUrl: see the README' >> "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "docsUrl mentioned outside a JSON member" "FAIL \(j\)"
P=$(fresh); L=$(wc -l < "$P/README.md"); printf '%s\n' '' 'a \' 'b' 'claude plugin install che-telegram-mcp@old-mp' >> "$P/README.md"
expect_fail "line numbers count physical lines after a continuation" "README\.md:$((L + 4)) names che-telegram-mcp@old-mp"

# (j) verify round 5 of PsychQuant/che-msg#42: every file of the plugin and the root
# README are scanned; each case differs on the round-4 lib (e92b26d) unless marked
P=$(fresh); perl -pi -e 's{GITHUB_REPO="PsychQuant/che-msg"}{GITHUB_REPO="PsychQuant/psychquant-claude-plugins"}' "$P/hooks/check-mcp.sh"
expect_fail "hook's GITHUB_REPO names the old repository" "FAIL \(j\)"
P=$(fresh); perl -0pi -e 's/\A\{/{\n  "homepage": "https:\/\/github.com\/PsychQuant\/psychquant-claude-plugins",/' "$P/.claude-plugin/plugin.json"
expect_fail "plugin.json homepage is the old repository" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'claude plugin marketplace add PsychQuant/psychquant-claude-plugins' >> "$P/skills/auth/SKILL.md"
expect_fail "a skill tells users to add the old marketplace" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's{marketplace add PsychQuant/che-msg}{marketplace add PsychQuant/psychquant-claude-plugins}' "$SCRATCH/tree/README.md"
expect_fail "the repository's root README adds the old marketplace" "FAIL \(j\)"
P=$(fresh); mkdir -p "$P/bin/lib"; printf '%s\n' '# https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-telegram-mcp' > "$P/bin/lib/x.sh"
expect_fail "old repository in a file below bin/" "bin/lib/x\.sh:1 names the former"
P=$(fresh); printf '%s\n' 'SOURCE=https://github.com/PsychQuant/psychquant-claude-plugins' > "$P/bin/.env.example"
expect_fail "old repository in a dotfile in bin/" "bin/\.env\.example:1 names the former"
P=$(fresh); printf '%s\n' '# https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-telegram-mcp' >> "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "old repository in a wrapper comment (regression lock)" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's/"docsUrl":"[^"]*",?//' "$P"/bin/*-wrapper.sh
expect_fail "the wrappers' docsUrl removed, so rule 5 would check nothing" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's/#when-telegram-bot-does-not-start/#when-telegram-bot-stops/' "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "the bot wrapper's docsUrl links a heading the README does not have (#67)" "docsUrl anchor #when-telegram-bot-stops matches no heading"
P=$(fresh); printf '%s\n' '' "echo '{\"docsUrl\":\"https://github.com/PsychQuant/che-msg/blob/main/plugins/che-telegram-mcp/README.md#gone\"}'" >> "$P/hooks/check-mcp.sh"
expect_fail "a docsUrl outside bin/ with an anchor that matches nothing" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's{PsychQuant/che-msg}{PsychQuant/other-repo}g' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "wrapper GITHUB_REPO and docsUrl both name a repository that is not che-msg (regression lock)" "FAIL \(j\)"
P=$(fresh); perl -ni -e 'print unless /^GITHUB_REPO=/' "$P/bin/che-telegram-all-mcp-wrapper.sh"
expect_fail "a docsUrl in a file with no GITHUB_REPO line (regression lock)" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's{marketplace add PsychQuant/che-msg}{marketplace add che-msg}' "$P/README.md"
expect_fail "marketplace add names che-msg without an owner" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'Tracked in PsychQuant/psychquant-claude-plugins#152.' >> "$P/README.md"
expect_fail "Owner/repo#N shorthand for an old-repository issue is reported (fails closed; link /issues/<n>)" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'https://github.com/PsychQuant/psychquant-claude-plugins/issues/1/../../tree/main/plugins/che-telegram-mcp' >> "$P/README.md"
expect_fail "issue link followed by dot segments into the old repository" "FAIL \(j\)"
P=$(fresh); L=$(wc -l < "$P/README.md"); printf '\nx\xe2\x80\xa8claude plugin install che-telegram-mcp@old-mp\n' >> "$P/README.md"
expect_fail "U+2028 inside a line does not shift line numbers" "README\.md:$((L + 2)) names che-telegram-mcp@old-mp"
P=$(fresh); printf '%s\n' '' "o https://github.com/PsychQuant/psychquant-claude-plugins/tree/main/plugins/che-telegram-mcp" >> "$P/CHANGELOG.md"
expect_pass "CHANGELOG.md may name the old repository (regression lock)"
P=$(fresh); python3 -c 'import sys; open(sys.argv[1], "a").write("\n# a" + " " * 200000 + "b\n\n# " + "[" * 80000 + "\n")' "$P/README.md"
expect_fast_pass "a README heading with 200000 spaces and one with 80000 [ are read in time" 20
P=$(fresh); python3 -c 'import sys; open(sys.argv[1], "w").write("[" * 100000)' "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "deeply nested marketplace.json reports (j) instead of crashing the parser" "FAIL \(j\)"
if [ "$(id -u)" -eq 0 ]; then
    echo "  - skipped: unreadable-file case (root can read a mode-000 file)"
else
    P=$(fresh); printf 'x\n' > "$P/notes.txt"; chmod 000 "$P/notes.txt"
    expect_fail "an unreadable file in the plugin reports (j) instead of crashing the parser" "FAIL \(j\)"
fi
P=$(fresh); python3 -c 'import sys; open(sys.argv[1], "a").write("\n" * 3000000)' "$P/README.md"
expect_fail "a README over 2 MB is reported, not read" "FAIL \(j\)"

# (j) verify round 6 of PsychQuant/che-msg#42: directories, rule 4 options, shape b,
# marketplace.json; each case differs on the round-5 lib (cbf36ea) unless marked
P=$(fresh); mkdir -p "$SCRATCH/ext"; printf '%s\n' 'claude plugin marketplace add PsychQuant/psychquant-claude-plugins' > "$SCRATCH/ext/x.md"; ln -s "$SCRATCH/ext" "$P/linkdir"
expect_fail "a symlink to a directory is reported, not skipped" "linkdir is a symlink to a directory"
rm -rf "$SCRATCH/ext"
if [ "$(id -u)" -eq 0 ]; then
    echo "  - skipped: unreadable-directory case (root can list a mode-000 directory)"
else
    P=$(fresh); mkdir "$P/sub"; printf '%s\n' 'GITHUB_REPO="PsychQuant/psychquant-claude-plugins"' > "$P/sub/x.sh"; chmod 000 "$P/sub"
    expect_fail "a directory that cannot be listed is reported, not skipped" "sub .*not checked"
    chmod 755 "$P/sub"
fi
P=$(fresh); perl -pi -e 's{marketplace add PsychQuant/che-msg}{marketplace add --scope PsychQuant/che-msg}' "$P/README.md"
expect_fail "marketplace add --scope <repo> has no marketplace argument" "never says .marketplace add"
P=$(fresh); perl -pi -e 's{marketplace add PsychQuant/che-msg}{marketplace add /che-msg}' "$P/README.md"
expect_fail "marketplace add /che-msg (nothing before the slash)" "never says .marketplace add"
P=$(fresh); printf '%s\n' '' 'See https://github.com/PsychQuant/psychquant-claude-plugins#1' >> "$P/README.md"
expect_fail "link to the old repository's front page with a numeric anchor" "FAIL \(j\)"
P=$(fresh); printf '%s\n' '' 'https://github.com/PsychQuant/psychquant-claude-plugins/issues/12abc' >> "$P/README.md"
expect_fail "issue number followed by letters" "FAIL \(j\)"
P=$(fresh); perl -0pi -e 's{"source": "\./plugins/che-telegram-mcp"}{"source": {"source": "github", "repo": "PsychQuant/psychquant-claude-plugins"}}' "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "marketplace.json sources the plugin from the old repository" "marketplace\.json:[0-9]+ names the former"
P=$(fresh); perl -pi -e 's/"docsUrl":"[^"]*",?//' "$P"/bin/*-wrapper.sh; printf '%s\n' '# "docsUrl":"https://github.com/PsychQuant/che-msg/blob/main/plugins/che-telegram-mcp/README.md#when-telegram-all-does-not-start"' >> "$P/hooks/check-mcp.sh"
expect_fail "the wrappers' docsUrl removed while a hook comment still has one" "no file in bin/ has a docsUrl"
P=$(fresh); printf '%s\n' '' 'If the server is locked, the error carries a docsUrl that links here.' >> "$P/skills/auth/SKILL.md"
expect_pass "a skill that mentions docsUrl in prose"
P=$(fresh); python3 -c 'import sys; open(sys.argv[1], "a").write("\n# a" + " " * 990 + "b" * 1 + ("\n# a" + " " * 990 + "b") * 1499 + ("\n# " + "[" * 990) * 300 + ("\n# " + "_" * 990 + "a") * 100 + "\n")' "$P/README.md"
expect_fast_pass "1900 README headings just under the length cap are read in time (round 5 lib: about 20 s)" 5

P=$(fresh); printf '%s\n' '' 'security add-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_PHONE" -U -w '"'"'+886912345678'"'"'' >> "$P/README.md"
expect_fail "a README Keychain command with the secret after -w (#51)" "FAIL \(k\)"
P=$(fresh); printf '%s\n' '    echo "  security add-generic-password -a x -s Y -w VALUE -U" >&2' >> "$P/bin/che-telegram-bot-mcp-wrapper.sh"
expect_fail "a wrapper hint with a value after -w (#51)" "che-telegram-bot-mcp-wrapper.sh:[0-9]+: .-w. is not the last"

P=$(fresh); printf '%s\n' '' 'security add-generic-password -a x -s TELEGRAM_BOT_TOKEN -w "hunter2"' >> "$P/skills/send/SKILL.md"
expect_fail "a skill with a Keychain command that has a value (#51 verify)" "skills/send/SKILL\.md:[0-9]+: .-w. is not the last"
P=$(fresh); printf '%s\n' 'security add-generic-password -a x -s Y -p secret -U -w' > "$P/hooks/.notes"
expect_fail "-p with a value in a dotfile under hooks/ (#51 verify)" "hooks/\.notes:[0-9]+: .-p. / .-X."
P=$(fresh); printf '%s\n' '' "printf '%s' \"\$TOKEN\" | security add-generic-password -a x -s Y -U -w" >> "$P/README.md"
expect_fail "a value piped into security (#51 verify)" "a value is piped into security"

P=$(fresh); printf '\377\376\000binary\n' > "$P/hooks/icon.png"
out=$(run_layout)
if printf '%s\n' "$out" | grep -q 'FAIL (k)'; then
    echo "  ✗ a binary file that never names the command does not fail (k) (#51 verify r2)"; printf '%s\n' "$out" | sed 's/^/      /'; FAILED=$((FAILED + 1))
else
    echo "  ✓ a binary file that never names the command does not fail (k) (#51 verify r2)"; PASSED=$((PASSED + 1))
fi
P=$(fresh); printf '\377\nsecurity add-generic-password -a x -s Y -w hunter2\n' > "$P/hooks/notes.bin"
expect_fail "a non-UTF-8 file with a Keychain command is still checked (#51 verify r2)" "hooks/notes\.bin:2: .-w. is not the last"

P=$(fresh); printf '%s\n' '' 'security add-generic-password -a x -s Y -pSECRET -U -w' >> "$P/README.md"
expect_fail "-p attached to its value (#51 verify r2)" "README\.md:[0-9]+: .-p. / .-X."

# ---------- #54: only reviewed components ((a) whitelist, (b) .mcp.json keys) ----------
# jedit <file> <python statement on d>: edit a JSON file in the scratch tree
jedit() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); exec(sys.argv[2]); json.dump(d, open(p, "w"), indent=2)' "$1" "$2"; }
P=$(fresh); printf '%s\n' '{"hooks": {"PreToolUse": []}}' > "$P/settings.json"
expect_fail "a settings.json with hooks at the plugin root (#54)" "^    \./ contains"
P=$(fresh); mkdir "$P/agents"; printf '%s\n' '---' 'name: x' '---' > "$P/agents/x.md"
expect_fail "an agents/ directory (#54)" "^    \./ contains"
P=$(fresh); mkdir "$P/monitors"; : > "$P/monitors/m.json"
expect_fail "a monitors/ directory (#54)" "^    \./ contains"
P=$(fresh); mkdir "$P/mods"; : > "$P/mods/tool-check.js"
expect_fail "a mods/ directory with a tool.check handler (#54)" "^    \./ contains"
P=$(fresh); printf '%s\n' '{}' > "$P/.lsp.json"
expect_fail "a .lsp.json at the plugin root (#54)" "^    \./ contains"
P=$(fresh); jedit "$P/.claude-plugin/plugin.json" 'd["hooks"] = {"SessionStart": []}'
expect_fail "plugin.json with inline hooks (#54)" "plugin\.json declares"
P=$(fresh); jedit "$P/.claude-plugin/plugin.json" 'd["skills"] = "./other-skills"'
expect_fail "plugin.json with a skills path (#54)" "plugin\.json declares"
P=$(fresh); jedit "$SCRATCH/tree/.claude-plugin/marketplace.json" '[e.__setitem__("hooks", {"SessionStart": []}) for e in d["plugins"] if e["name"] == "che-telegram-mcp"]'
expect_fail "the marketplace entry declares hooks (#54)" "marketplace entry declares"
P=$(fresh); jedit "$SCRATCH/tree/.claude-plugin/marketplace.json" '[e.__setitem__("source", "./plugins/elsewhere") for e in d["plugins"] if e["name"] == "che-telegram-mcp"]'
expect_fail "the marketplace entry's source points elsewhere (#54)" "marketplace entry source is"
P=$(fresh); jedit "$P/hooks/hooks.json" 'd["hooks"]["PreToolUse"] = [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/hooks/check-mcp.sh"}]}]'
expect_fail "hooks.json with a second event, quoted correctly (#54)" "hooks\.json .*PreToolUse"
P=$(fresh); printf '%s\n' '#!/bin/bash' > "$P/hooks/extra.sh"
expect_fail "an extra file in hooks/ (#54)" "hooks/ contains"
P=$(fresh); printf '%s\n' '#!/bin/bash' > "$P/lib/extra.sh"
expect_fail "an extra file in lib/ (#54, #56)" "lib/ contains"
P=$(fresh); mkdir "$P/skills/extra"; printf '%s\n' '---' 'name: extra' 'description: x' '---' 'body' > "$P/skills/extra/SKILL.md"
expect_fail "an extra skill without allowed-tools (#54)" "skills/ contains"
P=$(fresh); : > "$P/skills/chats/notes.md"
expect_fail "an extra file next to a SKILL.md (#54)" "skills/chats/ contains"
P=$(fresh); jedit "$P/.mcp.json" 'd["telegram-extra"] = {"type": "stdio", "command": "${CLAUDE_PLUGIN_ROOT}/bin/che-telegram-all-mcp-wrapper.sh"}'
expect_fail "a third server in .mcp.json (#54)" "\.mcp\.json .*telegram-extra"
P=$(fresh); jedit "$P/.mcp.json" 'd["telegram-all"]["env"] = {"TELEGRAM_2FA_PASSWORD": "x"}'
expect_fail "a server with an env block in .mcp.json (#54)" "telegram-all declares .*env"

# ---------- #86: README pre-approved table matches each skill's allowed-tools ((l)) ----------
P=$(fresh); perl -0pi -e 's{(allowed-tools:(\r?)\n(?:  - .*\n)*)}{$1  - mcp__plugin_che-telegram-mcp_telegram-all__get_me$2\n}' "$P/skills/chats/SKILL.md"
expect_fail "a skill pre-approves a tool the table does not list (#86)" "FAIL \(l\)"
P=$(fresh); perl -pi -e 's{^\| `chats` \| `auth_status`, `get_chats` \|}{| `chats` | `auth_status`, `get_chats`, `get_me` |}' "$P/README.md"
expect_fail "the table lists a tool the skill does not pre-approve (#86)" "FAIL \(l\)"
P=$(fresh); perl -pi -e 's{^(\| `chats` .*)$}{$1\n| `ghost` | `auth_status` | — |}' "$P/README.md"
expect_fail "the table has a row for a skill that does not exist (#86)" "ghost"
P=$(fresh); perl -ni -e 'print unless /^\| `chats` \|/' "$P/README.md"
expect_fail "the table has no row for a skill that pre-approves tools (#86)" "no row for chats"
# #48 put auth_run in both places; each half of that edit alone must fail.
P=$(fresh); perl -pi -e 's{^\| `auth` \| `auth_status`, `auth_run`, }{| `auth` | `auth_status`, }' "$P/README.md"
expect_fail "the auth skill pre-approves auth_run, its table row does not (#48's half edit, #86)" "auth_run"
P=$(fresh); perl -ni -e 'print unless /^  - mcp__plugin_che-telegram-mcp_telegram-all__auth_run\r?$/' "$P/skills/auth/SKILL.md"
expect_fail "the table row lists auth_run, the auth skill does not pre-approve it (#48's half edit, #86)" "auth_run"
P=$(fresh); perl -pi -e 's{^\| Skill \| Pre-approved \| Not pre-approved \|}{| Skill | Allowed | Not allowed |}' "$P/README.md"
expect_fail "the table's header is rewritten, so the table cannot be found (#86)" "FAIL \(l\)"
P=$(fresh); perl -pi -e 's{^\| `search` \| `auth_status`, `search_chats`, `search_messages`, `get_chat_history` \|}{| `search` | `get_chat_history`, `search_messages`, `auth_status`, `search_chats` |}' "$P/README.md"
expect_pass "the same tools in another order in a row (#86)"
# Pre-approved in the frontmatter and in its row, but also listed as not pre-approved: only the
# not-pre-approved comparison in (l) can catch it ((f) allows search_messages, the sets match).
P=$(fresh); perl -0pi -e 's{(allowed-tools:(\r?)\n(?:  - .*\n)*)}{$1  - mcp__plugin_che-telegram-mcp_telegram-all__search_messages$2\n}' "$P/skills/send/SKILL.md"
perl -pi -e 's{^\| `send` \| `auth_status`, `search_chats` \| \*\*`send_message`\*\*}{| `send` | `auth_status`, `search_chats`, `search_messages` | **`search_messages`**, **`send_message`**}' "$P/README.md"
expect_fail "a skill pre-approves a tool its row lists as not pre-approved (#86)" "send: allowed-tools has \['search_messages'\], which the README lists as not pre-approved"

# ---------- #54 / #86 verify follow-ups ----------
P=$(fresh); printf '#!/bin/bash\n' > "$P/bin/evil-wrapper.sh"; chmod +x "$P/bin/evil-wrapper.sh"
expect_fail "a third executable wrapper in bin/ (#54 verify)" "^    bin/ contains"
P=$(fresh); printf '#!/bin/bash\n' > "$P/bin/.sneaky"; chmod +x "$P/bin/.sneaky"
expect_fail "an executable dotfile in bin/ (#54 verify)" "^    bin/ contains"
P=$(fresh); rm "$P/hooks/check-mcp.sh"; mkdir "$P/hooks/check-mcp.sh"
expect_fail "hooks/check-mcp.sh is a directory (#54 verify)" "check-mcp\.sh is not an executable file"
P=$(fresh); printf '[]\n' > "$P/.claude-plugin/plugin.json"
expect_fail "plugin.json is a JSON array (#54 verify)" "plugin\.json is not a JSON object"
P=$(fresh); printf '{\n' > "$P/.claude-plugin/plugin.json"
expect_fail "plugin.json cannot be parsed (#54 verify)" "plugin\.json cannot be read"
P=$(fresh); printf '[]\n' > "$P/hooks/hooks.json"
expect_fail "hooks.json is a JSON array (#54 verify)" "hooks\.json is not a JSON object"
P=$(fresh); jedit "$P/hooks/hooks.json" 'd["description"] = "x"'
expect_fail "hooks.json with an extra top-level key (#54 verify)" "hooks\.json has top-level keys"
P=$(fresh); jedit "$P/hooks/hooks.json" 'd["hooks"]["SessionStart"][0]["hooks"].append({"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/hooks/check-mcp.sh --again"})'
expect_fail "hooks.json with a second SessionStart command (#54 verify)" "SessionStart runs"
P=$(fresh); jedit "$P/hooks/hooks.json" 'd["hooks"]["SessionStart"][0]["hooks"][0]["type"] = "mcp_tool"'
expect_fail "a SessionStart handler of another type with the same command (#54 verify)" "handlers .* are not all"
P=$(fresh); jedit "$P/hooks/hooks.json" 'd["hooks"]["SessionStart"][0]["hooks"][0]["async"] = True'
expect_fail "a SessionStart handler with an extra key (#54 verify)" "handlers .* are not all"
P=$(fresh); jedit "$SCRATCH/tree/.claude-plugin/marketplace.json" 'd["plugins"].append({"name": "che-telegram-mcp-extra", "source": "./plugins/che-telegram-mcp", "hooks": {}})'
expect_fail "a second marketplace entry loading this directory under another name (#54 verify)" "entries for che-telegram-mcp \(by name or source\)"
P=$(fresh); rm "$SCRATCH/tree/.claude-plugin/marketplace.json"
expect_fail "marketplace.json missing (#54 verify)" "marketplace\.json not found"
P=$(fresh); perl -pi -e 's{^\| `chats` \| `auth_status`, `get_chats` \|}{| `chats` | `auth_status`, `get_chats`, get_me |}' "$P/README.md"
expect_fail "a Pre-approved cell with a tool not in backticks (#86 verify)" "has text that is not a .tool."
P=$(fresh); perl -pi -e 's{^(\| `chats` .*)$}{$1\n| `telegram-messaging` | — | — |}' "$P/README.md"
expect_fail "a row for a skill that pre-approves nothing (#86 verify)" "row for telegram-messaging, which pre-approves no tools"

echo
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
