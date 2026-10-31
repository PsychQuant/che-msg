#!/bin/bash
# Mutation test for tests/che-slack-mcp/test-plugin-layout.sh.
#
# A layout test that never fails is worse than none. Each case copies the
# plugin and the files the layout test reads into a scratch tree, breaks ONE
# thing, and asserts the layout test fails with the RIGHT check. The real
# repository is never modified.
#
# Usage:
#   bash tests/che-slack-mcp/test-plugin-layout-mutations.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAYOUT_TEST="$SCRIPT_DIR/test-plugin-layout.sh"
if [ ! -d "$REPO/plugins/che-slack-mcp" ]; then
    echo "✗ plugins/che-slack-mcp not found — nothing to mutate"
    exit 1
fi
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/slack-layout-mutations-XXXXXX") || { echo "✗ mktemp failed" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

PASSED=0
FAILED=0
RULE="mcp__plugin_che-slack-mcp_slack__"

fresh() {   # build a clean scratch tree; echo its plugin dir
    local t="$SCRATCH/tree"
    rm -rf "$t"
    mkdir -p "$t/tests/che-slack-mcp" "$t/plugins" "$t/.claude-plugin" "$t/openspec" \
             "$t/che-slack-mcp/Sources/slack-all"
    cp -R "$REPO/plugins/che-slack-mcp" "$t/plugins/che-slack-mcp"
    cp "$LAYOUT_TEST" "$t/tests/che-slack-mcp/"
    cp -R "$REPO/tests/lib" "$t/tests/lib"
    cp "$REPO/.claude-plugin/marketplace.json" "$t/.claude-plugin/"
    cp "$REPO/README.md" "$t/"
    cp "$REPO/openspec/LANGUAGE.md" "$t/openspec/"
    cp "$REPO/che-slack-mcp/README.md" "$REPO/che-slack-mcp/CHANGELOG.md" "$t/che-slack-mcp/"
    cp -R "$REPO/che-slack-mcp/Sources/CheSlackMCPCore" "$t/che-slack-mcp/Sources/"
    cp "$REPO/che-slack-mcp/Sources/slack-all/main.swift" "$t/che-slack-mcp/Sources/slack-all/"
    echo "$t/plugins/che-slack-mcp"
}

run_layout() { bash "$SCRATCH/tree/tests/che-slack-mcp/test-plugin-layout.sh" 2>&1; }

# expect_fail <name> <pattern>: the layout test exits non-zero AND prints the
# pattern, so the right check caught it.
expect_fail() {
    local out rc
    out=$(run_layout); rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "$2"; then
        echo "  ✓ $1"; PASSED=$((PASSED + 1))
    else
        echo "  ✗ $1 (exit $rc; expected /$2/)"
        printf '%s\n' "$out" | sed 's/^/      /'
        FAILED=$((FAILED + 1))
    fi
}
expect_pass() {
    local out rc
    out=$(run_layout); rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  ✓ $1"; PASSED=$((PASSED + 1))
    else
        echo "  ✗ $1 (exit $rc, expected pass)"
        printf '%s\n' "$out" | sed 's/^/      /'
        FAILED=$((FAILED + 1))
    fi
}
# applied <file> <fixed string>: warn when a mutation did not take effect,
# since the case would then test nothing.
applied() { grep -qF -- "$2" "$1" || echo "  ! mutation did not apply in $1: $2"; }

echo "test-plugin-layout-mutations.sh (che-slack-mcp)"

P=$(fresh); expect_pass "unmodified copy passes"
P=$(fresh); echo '{ not json' > "$P/.mcp.json"
expect_fail "broken .mcp.json fails closed" "parser crashed"
P=$(fresh); rm "$P/README.md"
expect_fail "missing README fails closed" "parser crashed"

# (a)
P=$(fresh); printf '#!/bin/bash\n' > "$P/bin/test-x.sh"; chmod +x "$P/bin/test-x.sh"
expect_fail "test script in bin/" "FAIL \(a\)"
P=$(fresh); printf 'x' > "$P/bin/.DS_Store"
expect_pass ".DS_Store in bin/ is ignored"

# (b) (b2)
P=$(fresh); perl -pi -e 's/^  "slack":/  "slack-mcp":/' "$P/.mcp.json"; applied "$P/.mcp.json" '"slack-mcp":'
expect_fail "server renamed, so the README's rules match nothing" "FAIL \(b\)"
P=$(fresh); perl -pi -e 's/^DESIRED_VERSION=.*/DESIRED_VERSION="0.8.0"/' "$P/bin/che-slack-mcp-wrapper.sh"
applied "$P/bin/che-slack-mcp-wrapper.sh" 'DESIRED_VERSION="0.8.0"'
expect_fail "pin differs from the server's version" "FAIL \(b2\)"
P=$(fresh); perl -pi -e 's/^(DESIRED_VERSION="[0-9.]+")$/$1\n[ -n "\${PIN:-}" ] && DESIRED_VERSION="\$PIN"/' "$P/bin/che-slack-mcp-wrapper.sh"
applied "$P/bin/che-slack-mcp-wrapper.sh" 'DESIRED_VERSION="$PIN"'
expect_fail "conditional override after the literal pin" "FAIL \(b2\)"

# (c)
P=$(fresh); python3 - "$SCRATCH/tree/.claude-plugin/marketplace.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for e in d["plugins"]:
    if e["name"] == "che-slack-mcp":
        e["version"] = "9.9.9"
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
EOF
expect_fail "marketplace version differs from plugin.json" "FAIL \(c\)"

# (d)
P=$(fresh); perl -ni -e 'print unless /^\| `get_user` \| (?!\*\*|Yes|No)/' "$P/README.md"
expect_fail "a registered tool missing from the tool table" "FAIL \(d\).*|get_user is registered"

# (e)
P=$(fresh); perl -pi -e 's/^\| `send_message` \| \*\*No\*\*/| `send_message` | Yes/' "$P/README.md"
applied "$P/README.md" '| `send_message` | Yes'
expect_fail "send_message marked Yes" "send_message is marked Yes"
P=$(fresh); perl -0pi -e "s/\"allow\": \\[\n/\"allow\": [\n      \"${RULE}send_message\",\n/" "$P/README.md"
applied "$P/README.md" "\"${RULE}send_message\","
expect_fail "send_message in the allow example" "permissions.allow example holds ${RULE}send_message"
P=$(fresh); perl -pi -e "s/\"${RULE}archive_conversation_to_markdown\"/\"${RULE}get_user\"/" "$P/README.md"
expect_fail "archive tool missing from the ask example" "lacks ${RULE}archive_conversation_to_markdown"
P=$(fresh); perl -pi -e 's/mcp__plugin_che-slack-mcp_slack__send_message/mcp__plugin_che-slack-mcp_che-slack__send_message/' "$P/README.md"
expect_fail "rule written with another server name" "README names mcp__plugin_che-slack-mcp_che-slack__send_message"

# (f)
P=$(fresh); mkdir -p "$P/skills/send"
printf -- '---\nname: send\nallowed-tools:\n  - "%ssend_message"\n---\nSend.\n' "$RULE" > "$P/skills/send/SKILL.md"
expect_fail "a skill pre-approves send_message" "FAIL \(f\)"

# (g)
P=$(fresh); perl -pi -e 's/Always Allow/Always-allow/g' "$P/README.md"
expect_fail "README drops the Always Allow warning" "no longer mentions 'Always Allow'"

# (h)
P=$(fresh); printf '\nSee /Users/someone/notes.\n' >> "$P/README.md"
expect_fail "a home path in the README" "FAIL \(h\)"
P=$(fresh); printf '\ntoken: xoxc-1234567890abc\n' >> "$SCRATCH/tree/openspec/LANGUAGE.md"
expect_fail "a token-shaped string in LANGUAGE.md" "Slack token"

# (j)
P=$(fresh); perl -pi -e 's/install che-slack-mcp\@che-msg/install che-slack-mcp\@psychquant-claude-plugins/' "$P/README.md"
expect_fail "install line names another marketplace" "FAIL \(j\)"
P=$(fresh); perl -pi -e 's/#when-slack-does-not-start/#when-slack-will-not-start/' "$P/bin/che-slack-mcp-wrapper.sh"
applied "$P/bin/che-slack-mcp-wrapper.sh" '#when-slack-will-not-start'
expect_fail "docsUrl anchor matches no heading" "FAIL \(j\)"

# (k)
P=$(fresh); perl -pi -e 's/^(BINARY_NAME=.*)$/$1\nexport SLACK_TOKEN="\$(security find-generic-password -a che-slack-mcp -s SLACK_TOKEN -w)"/' "$P/bin/che-slack-mcp-wrapper.sh"
applied "$P/bin/che-slack-mcp-wrapper.sh" 'export SLACK_TOKEN'
expect_fail "wrapper exports a Keychain value" "FAIL \(k\)"

echo ""
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
