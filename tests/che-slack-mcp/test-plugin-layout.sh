#!/bin/bash
# Structural test for the che-slack-mcp plugin (PsychQuant/che-msg#99, task 6.1
# of add-che-slack-mcp). Guards what `claude plugin validate` does not check:
#
#   (a)  bin/ holds only executable *-wrapper.sh files (dotfiles ignored):
#        files in bin/ go on the Bash tool's PATH, and harness-devtools finds
#        the wrapper and its pin only there.
#   (b)  .mcp.json declares exactly one server, `slack`, whose command is
#        ${CLAUDE_PLUGIN_ROOT}/bin/che-slack-mcp-wrapper.sh, an executable file.
#        The server name is part of every permission rule the README gives
#        (mcp__plugin_che-slack-mcp_slack__<tool>); renaming it would leave
#        those rules matching nothing.
#   (b2) the wrapper assigns DESIRED_VERSION exactly once, as a literal x.y.z,
#        and it equals the version the server (CheSlackMCPServer.version) and
#        slack-all (CommandConfiguration version) report in che-slack-mcp/.
#   (c)  plugin.json is named che-slack-mcp with an x.y.z version, and
#        marketplace.json lists it with the same version and the source
#        ./plugins/che-slack-mcp.
#   (d)  the README's tool table lists exactly the tools the server registers
#        (every tool("<name>" in che-slack-mcp/Sources/CheSlackMCPCore).
#   (e)  the README's pre-approval table names every tool once, says "Yes"
#        only for tools on the read-only allowlist below, and says "No" for
#        send_message and archive_conversation_to_markdown (design: send_message
#        不列入免確認清單). In the README's JSON examples, permissions.allow
#        holds only allowlisted tools and permissions.ask holds both of those.
#        Every mcp__plugin_che-slack-mcp_… name anywhere in the README uses
#        the server name from .mcp.json and a registered tool.
#   (f)  no skill or command frontmatter mentions send_message or
#        archive_conversation_to_markdown (scanned as raw text, so no YAML
#        spelling hides a pre-approval). The plugin ships no skills today;
#        this keeps a future one from pre-approving either tool.
#   (g)  the README keeps the notes users need: how to get slack-all
#        (swift build), the import, status and remove commands, the two
#        pacing variables, "Always Allow", Enterprise Grid and Slack's API
#        Terms.
#   (h)  che-msg is a public repository: no plugin file, che-slack-mcp/README.md,
#        che-slack-mcp/CHANGELOG.md or openspec/LANGUAGE.md holds a local home
#        path, an e-mail address or a string shaped like a Slack token.
#   (j)  the plugin sends users to the marketplace this repository publishes
#        and the wrapper's docsUrl points at a README heading
#        (tests/lib/install_refs.py, with docs_url_required).
#   (k)  the wrapper's code (comments aside) calls no `security` and exports
#        nothing: CheSlackMCP reads the Keychain itself.
#
# Every check fails closed: if a file it needs is missing or its parser
# breaks, the test fails.
#
# Usage:
#   bash tests/che-slack-mcp/test-plugin-layout.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/che-slack-mcp"
LIB_DIR="$REPO_ROOT/tests/lib"

FAILURES=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILURES=$((FAILURES + 1)); }

if [ ! -d "$PLUGIN_DIR" ]; then
    echo "FAIL plugin directory not found: $PLUGIN_DIR"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL python3 not found — no check can run"
    exit 1
fi
if [ ! -f "$LIB_DIR/install_refs.py" ]; then
    echo "FAIL tests/lib/install_refs.py not found — check (j) cannot run"
    exit 1
fi

echo "test-plugin-layout.sh (che-slack-mcp) — $PLUGIN_DIR"

OUT=$(python3 - "$PLUGIN_DIR" "$REPO_ROOT" "$LIB_DIR" <<'EOF'
import glob, json, os, re, sys

root, repo, lib = sys.argv[1:4]
sys.path.insert(0, lib)
problems = []
def bad(tag, msg): problems.append(f"{tag} {msg}")

PLUGIN = "che-slack-mcp"
SERVER = "slack"
WRAPPER = "che-slack-mcp-wrapper.sh"
# Tools that only read: from Slack, or the Keychain index. Everything else
# keeps its permission prompt — send_message posts as the user, and
# archive_conversation_to_markdown writes other people's messages to disk.
READ_ONLY = {"list_workspaces", "auth_status", "list_conversations", "get_conversation_history",
             "get_thread_replies", "get_user", "search_messages"}
NEVER_PREAPPROVED = {"send_message", "archive_conversation_to_markdown"}

def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()

# ---------- server sources: registered tools and reported versions ----------
core = os.path.join(repo, "che-slack-mcp", "Sources", "CheSlackMCPCore")
sources = sorted(glob.glob(os.path.join(core, "*.swift")))
if not sources:
    raise SystemExit(f"no Swift sources under {core}")
registered = set()
for path in sources:
    registered |= set(re.findall(r'\btool\("([a-z_]+)"', read(path)))
if not registered:
    raise SystemExit("found no tool(\"<name>\" registration in che-slack-mcp/Sources/CheSlackMCPCore")
server_version = re.findall(r'static let version = "([0-9.]+)"', read(os.path.join(core, "Server.swift")))
cli_version = re.findall(r'version: "([0-9.]+)"',
                         read(os.path.join(repo, "che-slack-mcp", "Sources", "slack-all", "main.swift")))
if len(server_version) != 1 or len(cli_version) != 1:
    raise SystemExit(f"cannot read one server and one slack-all version (found {server_version}, {cli_version})")

# ---------- (a) bin/ ----------
bindir = os.path.join(root, "bin")
if not os.path.isdir(bindir):
    bad("a", "bin/ is missing")
else:
    for name in sorted(os.listdir(bindir)):
        if name.startswith("."):
            continue
        p = os.path.join(bindir, name)
        if not name.endswith("-wrapper.sh"):
            bad("a", f"bin/{name} is not an MCP wrapper (only *-wrapper.sh belongs on PATH)")
        elif not os.access(p, os.X_OK):
            bad("a", f"bin/{name} is not executable")

# ---------- (b) / (b2) / (k) .mcp.json and the wrapper ----------
cfg = json.load(open(os.path.join(root, ".mcp.json")))
servers = cfg.get("mcpServers", cfg)
if not isinstance(servers, dict) or list(servers) != [SERVER]:
    bad("b", f".mcp.json must declare exactly one server, {SERVER!r}; found {list(servers) if isinstance(servers, dict) else servers!r}")
wrapper_path = os.path.join(root, "bin", WRAPPER)
spec = servers.get(SERVER, {}) if isinstance(servers, dict) else {}
if spec.get("command") != "${CLAUDE_PLUGIN_ROOT}/bin/" + WRAPPER:
    bad("b", f"{SERVER}: command is not ${{CLAUDE_PLUGIN_ROOT}}/bin/{WRAPPER}: {spec.get('command')!r}")
if not (os.path.isfile(wrapper_path) and os.access(wrapper_path, os.X_OK)):
    bad("b", f"bin/{WRAPPER} is not an executable file")
else:
    code = [l for l in read(wrapper_path).splitlines() if not l.lstrip().startswith("#")]
    assigns = [l for l in code if re.search(r"(^|[\s;&|(])DESIRED_VERSION=", l)]
    literal = [re.match(r'^\s*DESIRED_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"\s*$', l) for l in assigns]
    literal = [m.group(1) for m in literal if m]
    if len(assigns) != 1 or len(literal) != 1:
        bad("b2", f"{WRAPPER} must assign DESIRED_VERSION exactly once, as a literal x.y.z "
                  f"(found {len(assigns)} assignment(s), {len(literal)} literal)")
    elif not (literal[0] == server_version[0] == cli_version[0]):
        bad("b2", f"DESIRED_VERSION {literal[0]} differs from the version the server ({server_version[0]}) "
                  f"or slack-all ({cli_version[0]}) reports")
    for n, line in enumerate(read(wrapper_path).splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        if re.search(r"(^|[\s;&|(`$])(/usr/bin/)?security(\s|$)", line):
            bad("k", f"{WRAPPER}:{n} calls security: {line.strip()}")
        if re.search(r"(^|[\s;&|(])export(\s|$)", line):
            bad("k", f"{WRAPPER}:{n} exports a variable: {line.strip()}")

# ---------- (c) plugin.json and marketplace.json ----------
manifest = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json")))
version = manifest.get("version", "")
if manifest.get("name") != PLUGIN:
    bad("c", f"plugin.json name is {manifest.get('name')!r}, not {PLUGIN!r}")
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(version)):
    bad("c", f"plugin.json version {version!r} is not x.y.z")
market = json.load(open(os.path.join(repo, ".claude-plugin", "marketplace.json")))
entries = [e for e in market.get("plugins", []) if e.get("name") == PLUGIN]
if len(entries) != 1:
    bad("c", f"marketplace.json lists {PLUGIN} {len(entries)} time(s)")
else:
    if entries[0].get("version") != version:
        bad("c", f"marketplace.json says {PLUGIN} {entries[0].get('version')!r}, plugin.json says {version!r}")
    if entries[0].get("source") != "./plugins/" + PLUGIN:
        bad("c", f"marketplace.json source is {entries[0].get('source')!r}")

# ---------- README sections ----------
readme = read(os.path.join(root, "README.md"))
def section(title):
    m = re.search(r"(?m)^## " + re.escape(title) + r"[^\n]*\n(.*?)(?=^## |\Z)", readme, re.S)
    if not m:
        raise SystemExit(f"README has no '## {title}' section — cannot check")
    return m.group(1)
def first_column(text):
    return re.findall(r"(?m)^\|\s*`([a-z_]+)`\s*\|([^\n]*)$", text)

# ---------- (d) tool table ----------
documented = [name for name, _ in first_column(section("Tools"))]
if not documented:
    raise SystemExit("README '## Tools' has no table rows — cannot check (d)")
for name in sorted(registered - set(documented)):
    bad("d", f"{name} is registered by the server but not in the README's tool table")
for name in sorted(set(documented) - registered):
    bad("d", f"{name} is in the README's tool table but the server registers no such tool")
for name in sorted({n for n in documented if documented.count(n) > 1}):
    bad("d", f"{name} appears more than once in the README's tool table")

# ---------- (e) pre-approval table, JSON examples, rule names ----------
rows = first_column(section("Permissions"))
if not rows:
    raise SystemExit("README '## Permissions' has no table rows — cannot check (e)")
seen = {}
for name, rest in rows:
    cells = [c.strip() for c in rest.split("|")]
    answer = re.sub(r"[*_`]", "", cells[0]).strip().split()[0].lower() if cells and cells[0].strip() else ""
    seen.setdefault(name, []).append(answer)
for name in sorted(registered):
    answers = seen.get(name, [])
    if len(answers) != 1:
        bad("e", f"{name} appears {len(answers)} time(s) in the pre-approval table (expected once)")
        continue
    if answers[0] not in ("yes", "no"):
        bad("e", f"{name}: pre-approval column must start with Yes or No, found {answers[0]!r}")
    elif answers[0] == "yes" and name not in READ_ONLY:
        bad("e", f"{name} is marked Yes but is not on the read-only allowlist")
    elif name in NEVER_PREAPPROVED and answers[0] != "no":
        bad("e", f"{name} must be marked No")
for name in sorted(set(seen) - registered):
    bad("e", f"{name} in the pre-approval table is not a registered tool")

prefix = f"mcp__plugin_{PLUGIN}_{SERVER}__"
for m in re.finditer(r"mcp__plugin_[A-Za-z0-9_-]*?__[a-z_]*|mcp__plugin_[A-Za-z0-9_-]+", readme):
    name = m.group(0)
    if name.startswith(prefix) and name[len(prefix):] in registered:
        continue
    if name == prefix[:-2]:          # the whole-server rule
        continue
    bad("e", f"README names {name}, which is not {prefix}<registered tool> or the whole-server rule {prefix[:-2]}")

blocks = re.findall(r"(?ms)^```json\n(.*?)^```", readme)
allow, ask = [], []
for block in blocks:
    try:
        data = json.loads(block)
    except ValueError as exc:
        bad("e", f"a ```json block in the README does not parse ({exc})")
        continue
    perms = data.get("permissions", {}) if isinstance(data, dict) else {}
    allow += perms.get("allow", [])
    ask += perms.get("ask", [])
for rule in allow:
    if not (rule.startswith(prefix) and rule[len(prefix):] in READ_ONLY):
        bad("e", f"the README's permissions.allow example holds {rule}, which is not a read-only tool")
for tool in sorted(NEVER_PREAPPROVED):
    if prefix + tool not in ask:
        bad("e", f"the README's permissions.ask example lacks {prefix}{tool}")

# ---------- (f) skills and commands ----------
for path in sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md")) + glob.glob(os.path.join(root, "commands", "*.md"))):
    text = read(path).lstrip("﻿")
    m = re.match(r"---\r?\n(.*?)\r?\n---", text, re.S)
    raw = m.group(1) if m else text
    for tool in sorted(NEVER_PREAPPROVED):
        if tool in raw:
            bad("f", f"{os.path.relpath(path, root)}: frontmatter mentions {tool}")

# ---------- (g) notes the README must keep ----------
for phrase in ("swift build -c release", "slack-all auth import", "slack-all auth import --from-desktop",
               "slack-all auth status", "slack-all auth remove", "SLACK_MCP_MIN_INTERVAL_MS",
               "SLACK_MCP_MAX_CONCURRENCY", "Always Allow", "Enterprise Grid", "API Terms"):
    if phrase not in readme:
        bad("g", f"README no longer mentions {phrase!r}")

# ---------- (h) public-repository hygiene ----------
public = [os.path.join(dp, f) for dp, _, fs in os.walk(root) for f in fs]
public += [os.path.join(repo, "che-slack-mcp", "README.md"), os.path.join(repo, "che-slack-mcp", "CHANGELOG.md"),
           os.path.join(repo, "openspec", "LANGUAGE.md")]
for path in public:
    rel = os.path.relpath(path, repo)
    if not os.path.isfile(path):
        bad("h", f"{rel} is missing")
        continue
    text = open(path, encoding="utf-8", errors="replace").read()
    for pattern, what in ((r"/Users/[^/\s]+", "a local home path"),
                          (r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}", "an e-mail address"),
                          (r"xox[a-z]-[A-Za-z0-9]{6,}", "a string shaped like a Slack token")):
        for m in re.finditer(pattern, text):
            bad("h", f"{rel} holds {what}: {m.group(0)[:40]}")

# ---------- (j) install references ----------
import install_refs
for msg in install_refs.problems(PLUGIN, root, repo, docs_url_required=True):
    bad("j", msg)

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
report b  ".mcp.json declares only the slack server, started by bin/che-slack-mcp-wrapper.sh"
report b2 "the wrapper pins DESIRED_VERSION once, equal to the server's and slack-all's version"
report c  "plugin.json and marketplace.json agree on name, version and source"
report d  "the README's tool table lists exactly the registered tools"
report e  "send_message and archive_conversation_to_markdown are never pre-approved; rule names match .mcp.json"
report f  "no skill or command pre-approves send_message or archive_conversation_to_markdown"
report g  "the README keeps the install, import and risk notes"
report h  "no home path, e-mail address or Slack token in the public files"
report j  "the plugin and the repository README name the marketplace this repository publishes"
report k  "the wrapper calls no security and exports nothing"

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed"
    exit 1
fi
echo "all checks passed"
