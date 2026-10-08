#!/bin/bash
# Structural regression test for the che-telegram-mcp plugin layout (#138).
#
# Guards the shape that `claude plugin validate` does not check:
#   (a)  bin/ holds only the MCP wrappers (*-wrapper.sh) — no test scripts.
#        Files in bin/ go on the Bash tool's PATH, so nothing else belongs there
#        (dotfiles such as .DS_Store are ignored). The wrappers themselves stay
#        in bin/: harness-devtools only finds them there (plugin-binary-meta.sh
#        scans bin/ and hooks/, plugin-deploy only bin/), and moving them out
#        silently disabled its pin detection and release gate (#138 verify
#        round 1).
#   (b)  every .mcp.json command is ${CLAUDE_PLUGIN_ROOT}/bin/<name>-wrapper.sh
#        and resolves to an executable file
#   (b2) every wrapper assigns DESIRED_VERSION exactly once, as a literal x.y.z.
#        devtools reads the LAST assignment, so a later or conditional override
#        makes the pin unreadable.
#   (c)  every ${CLAUDE_PLUGIN_ROOT} in a hook command sits inside double quotes
#   (d)  allowed-tools lists only this plugin's MCP tools (no Bash, Write, …),
#        with the real prefix, each documented in the README under ITS server
#   (e)  no commands/ — the slash entry points live in skills/
#   (f)  a skill may pre-approve only tools on an explicit read-only allowlist;
#        the login steps (auth_set_parameters/send_phone/send_code/send_password/
#        run) only in skills/auth. Everything else keeps its permission prompt —
#        sending, editing, deleting or forwarding messages, chat management,
#        logout, bot get_updates (an offset drops pending updates for good) and
#        dump_chat_to_markdown (writes, and overwrites, any path it is given).
#        An allowlist also fails closed for tools added later.
#   (g)  telegram-messaging exists and stays model-invocable — it is the
#        natural-language router. A glob edit over skills/*/SKILL.md once added
#        disable-model-invocation to it along with the four slash skills. The
#        key must be absent or the literal false: Claude Code also reads yes/on/
#        1 — and numbers such as 1.0 — as true, so anything else fails.
#   (h)  the four slash skills (auth, chats, search, send) set
#        disable-model-invocation to the literal, unquoted `true` — they run
#        only when the user types them. Claude Code before 2.1.218 recognises
#        only true, so yes/on/1/"true" fail here. (g) and (h) each fail in
#        their own safe direction.
#   (i)  no skill registers `hooks` (they stay registered for the rest of the
#        session, beyond the turn's grant) or has a !`command` / ```! block in
#        its body (run when the skill is invoked, before Claude reads it; one
#        that matches the skill's own allowed-tools runs with no prompt)
#   (fm) every skill's frontmatter stays inside the subset Claude Code and this
#        test read the same way (see below)
#
# Frontmatter is split off and screened by tests/lib/frontmatter_subset.py: the
# boundary is found the way Claude Code finds it, and a block outside the plain
# YAML subset in which PyYAML (used here) and Claude Code's Bun.YAML read the
# same thing fails (fm) and is NOT parsed — the checks that need its values
# report it as unverifiable. See that module for the cases (NEL, U+2028, open
# quotes, `...`, …) and the fuzz evidence. Inside the subset it is
# parsed with PyYAML (after stripping a UTF-8 BOM) — hand-written parsing missed
# blank lines, comments, quoted keys and BOMs in two successive verify rounds.
# (f) additionally scans the raw frontmatter text for tool names, independent
# of the parser.
#
# Every check FAILS CLOSED: if its parser cannot run (bad JSON, missing file,
# no python3, no PyYAML), the test fails. An empty "no problems found" output
# is only trusted when the parser exited 0.
#
# Usage:
#   bash tests/che-telegram-mcp/test-plugin-layout.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../../plugins/che-telegram-mcp" 2>/dev/null && pwd)"

FAILURES=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILURES=$((FAILURES + 1)); }

if [ -z "$PLUGIN_DIR" ]; then
    echo "FAIL plugin directory not found next to $SCRIPT_DIR"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL python3 not found — no check can run"
    exit 1
fi

echo "test-plugin-layout.sh (#138) — $PLUGIN_DIR"

# One python pass does all parsing and prints one line per problem, tagged by
# check letter. Exit status != 0 means the parse itself broke.
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" 2>/dev/null && pwd)"
if [ -z "$LIB_DIR" ] || [ ! -f "$LIB_DIR/frontmatter_subset.py" ]; then
    echo "FAIL tests/lib/frontmatter_subset.py not found — no frontmatter check can run"
    exit 1
fi

OUT=$(python3 - "$PLUGIN_DIR" "$LIB_DIR" <<'EOF'
import json, os, re, sys

try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML is required (pip install pyyaml) — frontmatter checks cannot run without a real YAML parser")

root = sys.argv[1]
sys.path.insert(0, sys.argv[2])
import frontmatter_subset as fs
problems = []
def bad(tag, msg): problems.append(f"{tag} {msg}")

# Tools a skill may pre-approve. Everything else the README documents is
# side-effecting or irreversible and must keep its permission prompt:
# send/edit/delete/forward messages, chat management, logout, bot
# get_updates (an offset confirms and drops pending updates for good) and
# dump_chat_to_markdown (writes any path it is given, overwriting).
READ_ONLY = {
    "all": {"auth_status", "get_me", "get_chats", "get_chat", "get_chat_history",
            "search_chats", "search_messages", "get_chat_members", "get_contacts", "get_user"},
    "bot": {"get_me", "get_chat", "get_chat_administrators", "get_chat_member_count",
            "get_chat_member", "get_my_commands"},
}
# Login steps: each send triggers Telegram-side effects (a login code, flood
# limits). Only the auth skill may pre-approve them.
AUTH_STEPS = {"auth_set_parameters", "auth_send_phone", "auth_send_code",
              "auth_send_password", "auth_run"}

# ---------- (a) bin/ contents ----------
bindir = os.path.join(root, "bin")
if os.path.isdir(bindir):
    for name in sorted(os.listdir(bindir)):
        if name.startswith("."):          # Finder metadata etc. — not shipped, not on PATH as a command
            continue
        p = os.path.join(bindir, name)
        if not name.endswith("-wrapper.sh"):
            bad("a", f"bin/{name} is not an MCP wrapper (only *-wrapper.sh belongs on PATH)")
        elif not os.access(p, os.X_OK):
            bad("a", f"bin/{name} is not executable")

# ---------- (b) / (b2) .mcp.json ----------
cfg = json.load(open(os.path.join(root, ".mcp.json")))
servers = cfg.get("mcpServers", cfg)
if not servers:
    bad("b", ".mcp.json declares no servers")
for name, spec in servers.items():
    cmd = spec.get("command", "")
    if not re.fullmatch(r"\$\{CLAUDE_PLUGIN_ROOT\}/bin/[A-Za-z0-9._-]+-wrapper\.sh", cmd):
        bad("b", f"{name}: command is not ${{CLAUDE_PLUGIN_ROOT}}/bin/<name>-wrapper.sh: {cmd}")
        continue
    path = cmd.replace("${CLAUDE_PLUGIN_ROOT}", root)
    if not (os.path.isfile(path) and os.access(path, os.X_OK)):
        bad("b", f"{name}: {path} is not an executable file")
        continue
    # devtools reads the LAST assignment, so a later or conditional override
    # makes the pin unreadable. Require exactly one assignment, and a literal.
    code = [l for l in open(path).read().splitlines() if not l.lstrip().startswith("#")]
    assigns = [l for l in code if re.search(r"(^|[\s;&|(])DESIRED_VERSION=", l)]
    literal = [l for l in assigns if re.match(r'^\s*DESIRED_VERSION="[0-9]+\.[0-9]+\.[0-9]+"\s*$', l)]
    if len(assigns) != 1 or len(literal) != 1:
        bad("b2", f"{name}: {os.path.basename(path)} must assign DESIRED_VERSION exactly once, as a literal x.y.z "
                  f"(found {len(assigns)} assignment(s), {len(literal)} literal)")

# ---------- (c) hook quoting ----------
def inside_double_quotes(s, i):
    n, k = 0, 0
    while k < i:
        if s[k] == "\\":
            k += 2
            continue
        if s[k] == '"':
            n += 1
        k += 1
    return n % 2 == 1

hooks = json.load(open(os.path.join(root, "hooks", "hooks.json")))
for event, matchers in hooks.get("hooks", {}).items():
    for m in matchers:
        for h in m.get("hooks", []):
            cmd = h.get("command", "")
            for mt in re.finditer(r"\$\{CLAUDE_PLUGIN_ROOT\}", cmd):
                if not inside_double_quotes(cmd, mt.start()):
                    bad("c", f"{event}: unquoted ${{CLAUDE_PLUGIN_ROOT}} in: {cmd}")

# ---------- README: tools per server ----------
readme = open(os.path.join(root, "README.md")).read()
def section_tools(header_pat):
    m = re.search(header_pat + r".*?\n(.*?)(?=\n### |\n## |\Z)", readme, re.S)
    return set(re.findall(r"`([a-z][a-z0-9_]*)`", m.group(1))) if m else None
documented = {
    "all": section_tools(r"(?m)^### `telegram-all`"),
    "bot": section_tools(r"(?m)^### `telegram-bot`"),
}
for srv, tools in documented.items():
    if not tools:
        raise SystemExit(f"README has no tool list for telegram-{srv} — cannot check (d)/(f)")

# ---------- frontmatter (real YAML parser) ----------
def frontmatter(path):
    """Return (dict, raw_text, strings_dict, body, fm_problems). dict and
    strings_dict are None when there is no frontmatter or it is outside the
    subset (fm_problems says why). Strips a UTF-8 BOM; newlines are NOT translated
    (newline=""), so a lone CR stays a CR, as it does for Claude Code.
    strings_dict is the same block read with BaseLoader (builds no Python
    objects; every scalar stays a string), so (g) and (h) can tell a literal
    true/false from yes/on/1/"true"."""
    text = open(path, encoding="utf-8-sig", newline="").read()
    raw, body = fs.split(text)
    if raw is None:
        return None, None, None, body, ["no frontmatter Claude Code can read (must start with ---)"]
    fm_problems = fs.subset_problems(raw)
    if fm_problems:
        return None, raw, None, body, fm_problems
    data = yaml.safe_load(raw) or {}
    strings = yaml.load(raw, Loader=yaml.BaseLoader) or {}
    if not isinstance(data, dict) or not isinstance(strings, dict):
        raise SystemExit(f"{path}: frontmatter is not a mapping")
    return data, raw, strings, body, []

def tool_list(value):
    if value is None:
        return []
    if isinstance(value, str):
        return [t for t in re.split(r"[,\s]+", value) if t]
    if isinstance(value, list):
        return [str(t) for t in value]
    raise SystemExit(f"allowed-tools has unsupported type {type(value).__name__}")

def router_invocable(skill, key="disable-model-invocation"):
    """(g): absent, or the literal false, in BOTH views — BaseLoader keeps a
    merge key (<<) as a literal key, safe_load expands it like Claude Code."""
    data, strings = meta[skill], meta_strings[skill]
    if key not in data and key not in strings:
        return True
    return data.get(key) is False and str(strings.get(key, "")).strip().lower() == "false"

def literal_true(skill, key="disable-model-invocation"):
    """Only the unquoted literal true — used by (h)."""
    data, strings = meta[skill], meta_strings[skill]
    return data.get(key) is True and str(strings.get(key, "")).strip().lower() == "true"

prefix = re.compile(r"^mcp__plugin_che-telegram-mcp_telegram-(all|bot)__([a-z0-9_]+)$")

def check_tool(rel, skill, srv, tool):
    if tool in READ_ONLY[srv]:
        return
    if tool in AUTH_STEPS and srv == "all" and skill == "auth":
        return
    bad("f", f"{rel}: pre-approves {tool} (not in the read-only allowlist"
             + ("" if tool not in AUTH_STEPS else "; auth steps are allowed only in skills/auth") + ")")

skill_files = []
cmd_dir = os.path.join(root, "commands")
if os.path.isdir(cmd_dir):
    skill_files += [(os.path.join(cmd_dir, f), f[:-3]) for f in sorted(os.listdir(cmd_dir)) if f.endswith(".md")]
sk = os.path.join(root, "skills")
if os.path.isdir(sk):
    for d in sorted(os.listdir(sk)):
        p = os.path.join(sk, d, "SKILL.md")
        if os.path.isfile(p):
            skill_files.append((p, d))

meta, meta_strings, unreadable = {}, {}, set()
for path, skill in skill_files:
    rel = os.path.relpath(path, root)
    data, raw, strings, body, fm_problems = frontmatter(path)
    # (i) parser-independent part: blocks in the body
    if re.search(r"!`|```!", body):
        bad("i", f"{rel}: body has a !`command` or ```! block (runs when the skill is invoked, before Claude reads it)")
    seen = set()
    if data is None:
        for problem in fm_problems:
            bad("fm", f"{rel}: frontmatter {problem}")
        unreadable.add(skill)
        bad("d", f"{rel}: frontmatter cannot be read the way Claude Code reads it — cannot check allowed-tools")
        bad("i", f"{rel}: frontmatter cannot be read the way Claude Code reads it — cannot check for hooks")
    else:
        meta[skill], meta_strings[skill] = data, strings
        if "hooks" in data:
            bad("i", f"{rel}: frontmatter sets hooks (they stay registered for the rest of the session)")
    for t in tool_list(data.get("allowed-tools")) if data is not None else []:
        m = prefix.match(t)
        if not m:
            bad("d", f"{rel}: allowed-tools may list only this plugin's MCP tools; found {t}")
            continue
        srv, tool = m.group(1), m.group(2)
        seen.add((srv, tool))
        if tool not in documented[srv]:
            bad("d", f"{rel}: {tool} is not documented under telegram-{srv} in README")
        check_tool(rel, skill, srv, tool)
    # Independent of the parser: every tool named anywhere in the frontmatter
    # text must also pass (f). A spelling the parser reads differently cannot
    # hide a pre-approval this way.
    for srv, tool in re.findall(r"telegram-(all|bot)__([a-z0-9_]+)", raw or ""):
        if (srv, tool) not in seen:
            seen.add((srv, tool))
            check_tool(rel, skill, srv, tool)

# ---------- (g) router ----------
if not os.path.isfile(os.path.join(root, "skills", "telegram-messaging", "SKILL.md")):
    bad("g", "skills/telegram-messaging/SKILL.md is missing")
elif "telegram-messaging" in unreadable:
    bad("g", "skills/telegram-messaging/SKILL.md frontmatter cannot be read — cannot check")
elif "telegram-messaging" in meta and not router_invocable("telegram-messaging"):
    bad("g", "skills/telegram-messaging/SKILL.md sets disable-model-invocation")

# ---------- (h) slash skills ----------
for name in ("auth", "chats", "search", "send"):
    if not os.path.isfile(os.path.join(root, "skills", name, "SKILL.md")):
        bad("h", f"skills/{name}/SKILL.md is missing")
    elif name in unreadable:
        bad("h", f"skills/{name}/SKILL.md frontmatter cannot be read — cannot check")
    elif name in meta and not literal_true(name):
        bad("h", f"skills/{name}/SKILL.md does not set disable-model-invocation to the literal true "
                 f"(found {meta_strings[name].get('disable-model-invocation')!r})")

print("\n".join(problems))
EOF
)
RC=$?

if [ "$RC" -ne 0 ]; then
    echo "FAIL parser crashed (exit $RC) — every check below is UNVERIFIED, not passed:"
    printf '%s\n' "$OUT" | sed 's/^/    /'
    exit 1
fi

report() {  # $1 = tag, $2 = description when clean
    local lines
    lines=$(printf '%s\n' "$OUT" | sed -n "s/^$1 //p")
    if [ -n "$lines" ]; then
        fail "($1) $2"$'\n'"$(printf '%s\n' "$lines" | sed 's/^/    /')"
    else
        pass "($1) $2"
    fi
}

report a  "bin/ holds only executable *-wrapper.sh files"
report b  ".mcp.json commands are \${CLAUDE_PLUGIN_ROOT}/bin/*-wrapper.sh and executable"
report b2 "every wrapper assigns DESIRED_VERSION exactly once, as a literal"
report c  "hook commands quote \${CLAUDE_PLUGIN_ROOT}"
report fm "every skill has frontmatter Claude Code reads the same way"
report d  "allowed-tools list only this plugin's documented MCP tools"
if [ -e "$PLUGIN_DIR/commands" ]; then
    fail "(e) commands/ exists: $(ls "$PLUGIN_DIR/commands" | tr '\n' ' ')"
else
    pass "(e) no commands/"
fi
report f  "skills pre-approve only allowlisted read-only tools (auth steps only in auth)"
report g  "telegram-messaging exists and stays model-invocable"
report h  "auth/chats/search/send set disable-model-invocation: true"
report i  "no skill sets hooks or runs !\`command\` blocks"

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed"
    exit 1
fi
echo "all checks passed"
