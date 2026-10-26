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
#        The plugin also has only the components a check here reviews
#        (PsychQuant/che-msg#54, mirroring tests/che-archive-lines): the root
#        holds exactly .claude-plugin, .mcp.json, CHANGELOG.md, README.md, bin,
#        hooks, lib and skills; .claude-plugin/ only plugin.json; lib/ only
#        the files the wrappers source (download.sh, #56; startup-error.sh,
#        #67); hooks/ only
#        check-mcp.sh and hooks.json, whose only hook is the SessionStart
#        command; skills/ exactly the seven skills, each with only SKILL.md
#        (archive-telegram-search also scripts/, holding only search_archive.py,
#        #80; a new skill must be added here and to (h) on purpose). plugin.json and the
#        repository marketplace entry carry metadata keys only (no hooks,
#        skills, mcpServers, …); the entry is the only one for this plugin and
#        its source is ./plugins/che-telegram-mcp.
#   (a2) every file a wrapper sources from lib/ ("$PLUGIN_ROOT/lib/<file>")
#        exists as a regular file. Both wrappers download through
#        lib/download.sh (PsychQuant/che-msg#56); without it they cannot start.
#   (b)  every .mcp.json command is ${CLAUDE_PLUGIN_ROOT}/bin/<name>-wrapper.sh
#        and resolves to an executable file
#        .mcp.json declares exactly telegram-all and telegram-bot, each with
#        only type, command and description (no env, args, … that no check
#        reviews; #54).
#   (b2) every wrapper assigns DESIRED_VERSION exactly once, as a literal x.y.z.
#        devtools reads the LAST assignment, so a later or conditional override
#        makes the pin unreadable.
#   (b3) every wrapper assigns SHA256_PIN_VERSION and SHA256_PIN exactly once
#        each, as literals: SHA256_PIN_VERSION equal to its DESIRED_VERSION
#        and SHA256_PIN 64 lowercase hex digits (PsychQuant/che-msg#50). A
#        wrapper without a pin for its DESIRED_VERSION, empty or left from
#        another version, downloads nothing; RELEASING.md sets the pin and the
#        version together.
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
#   (h)  the six slash skills (auth, chats, search, send, archive-telegram,
#        archive-telegram-search) set disable-model-invocation to the literal,
#        unquoted `true` — they run only when the user types them
#        (archive-telegram writes archives and an index, PsychQuant/che-msg#69;
#        archive-telegram-search brings archived message text into the
#        conversation, #80). Claude Code before 2.1.218 recognises
#        only true, so yes/on/1/"true" fail here. (g) and (h) each fail in
#        their own safe direction.
#   (i)  no skill registers `hooks` (they stay registered for the rest of the
#        session, beyond the turn's grant) or has a !`command` / ```! block in
#        its body (run when the skill is invoked, before Claude reads it; one
#        that matches the skill's own allowed-tools runs with no prompt)
#   (j)  the plugin sends users to the marketplace this repository publishes:
#        in every plugin file but the top-level CHANGELOG.md, in the repository
#        README and in marketplace.json, the former marketplace name appears
#        only in listed shapes; the README installs from and adds this
#        marketplace; and the telegram-all wrapper's docsUrl (a file in bin/
#        must have one) and its #anchor point at this README. The five rules
#        are in tests/lib/install_refs.py (PsychQuant/che-msg#42: five such
#        places still named the old marketplace after the move).
#   (k)  every `security add-generic-password` / `add-internet-password`
#        command in any plugin file (the top-level CHANGELOG.md excepted, as
#        for (j)) ends with a bare `-w`, so security prompts for the secret
#        instead of taking it as an argument, which would stay in the shell
#        history and show in the process list (PsychQuant/che-msg#51). `-p` and
#        `-X` (other ways to pass the value) and a value piped straight into
#        security fail too; a command that cannot be parsed is reported as
#        such. It guards against mistakes, not evasion: a pipe through `env`
#        or `xargs`, or a quoted command name, is not recognised.
#   (l)  the README's Pre-approved table (| Skill | Pre-approved | Not
#        pre-approved |) has one row per skill with a non-empty allowed-tools,
#        and each row's Pre-approved set equals that skill's allowed-tools (order
#        ignored; tools on telegram-bot are written bot:<tool>); a row for a
#        skill that does not exist fails; a tool the row lists as not
#        pre-approved must not be in allowed-tools. No table found fails
#        (PsychQuant/che-msg#86: the table is what users read, and nothing
#        compared it with the frontmatter).
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
import json, os, re, shlex, sys

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

# (a) only the components a check reviews (#54; same rule as che-archive-lines)
IGNORED = {".DS_Store"}
def listing(path):
    return sorted(set(os.listdir(path)) - IGNORED) if os.path.isdir(path) else None
SKILLS = ["archive-telegram", "archive-telegram-search", "auth", "chats", "search", "send", "telegram-messaging"]
expected = {
    "": [".claude-plugin", ".mcp.json", "CHANGELOG.md", "README.md", "bin", "hooks", "lib", "skills"],
    ".claude-plugin": ["plugin.json"],
    "bin": ["che-telegram-all-mcp-wrapper.sh", "che-telegram-bot-mcp-wrapper.sh"],
    "hooks": ["check-mcp.sh", "hooks.json"],
    "lib": ["download.sh", "startup-error.sh"],
    "skills": SKILLS,
}
for name in SKILLS:
    expected[f"skills/{name}"] = ["SKILL.md"]
expected["skills/archive-telegram-search"] = ["SKILL.md", "scripts"]
expected["skills/archive-telegram-search/scripts"] = ["search_archive.py"]
for rel, want in expected.items():
    got = listing(os.path.join(root, rel))
    if got != want:
        bad("a", f"{rel or '.'}/ contains {got}, expected exactly {want}")
hook_script = os.path.join(root, "hooks", "check-mcp.sh")
if os.path.lexists(hook_script) and not (os.path.isfile(hook_script) and os.access(hook_script, os.X_OK)):
    bad("a", "hooks/check-mcp.sh is not an executable file")
# Compared without quotes: (c) decides how ${CLAUDE_PLUGIN_ROOT} must be quoted.
HOOK_COMMAND = "${CLAUDE_PLUGIN_ROOT}/hooks/check-mcp.sh"
def load_json(path):
    """A parsed JSON file, or None after reporting under (a) why it is not checked."""
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError, RecursionError) as e:
        bad("a", f"{os.path.relpath(path, root)} cannot be read ({type(e).__name__}) — not checked")
        return None
def json_object(path, cfg, tag="a"):
    """cfg when it is a JSON object; otherwise report it (fail closed) and return None."""
    if cfg is not None and not isinstance(cfg, dict):
        bad(tag, f"{os.path.relpath(path, root)} is not a JSON object ({type(cfg).__name__}) — not checked")
        return None
    return cfg
hooks_path = os.path.join(root, "hooks", "hooks.json")
hooks_cfg = json_object(hooks_path, load_json(hooks_path)) if os.path.isfile(hooks_path) else None
if hooks_cfg is not None:
    if set(hooks_cfg) != {"hooks"}:
        bad("a", f"hooks/hooks.json has top-level keys {sorted(hooks_cfg)}, expected only ['hooks']")
    events = hooks_cfg.get("hooks", {})
    events = events if isinstance(events, dict) else {}
    if sorted(events) != ["SessionStart"]:
        bad("a", f"hooks/hooks.json declares events {sorted(events)}, expected only ['SessionStart']")
    groups = events.get("SessionStart", [])
    groups = groups if isinstance(groups, list) else []
    handlers = []
    for m in groups:
        if not isinstance(m, dict) or set(m) != {"hooks"} or not isinstance(m.get("hooks"), list):
            bad("a", f"hooks/hooks.json SessionStart entry {m!r} is not {{'hooks': [...]}}")
            continue
        handlers += m["hooks"]
    shapes_ok = all(isinstance(h, dict) and set(h) == {"type", "command"} and h.get("type") == "command"
                    for h in handlers)
    if not shapes_ok:
        bad("a", f"hooks/hooks.json SessionStart handlers {handlers} are not all {{'type': 'command', 'command': ...}}")
    commands = [h.get("command") for h in handlers if isinstance(h, dict)]
    if [str(c).replace('"', "") for c in commands] != [HOOK_COMMAND]:
        bad("a", f"hooks/hooks.json SessionStart runs {commands}, expected only [{HOOK_COMMAND!r}]")
market = os.path.join(root, "..", "..", ".claude-plugin", "marketplace.json")
if not os.path.isfile(market):
    bad("a", "repo .claude-plugin/marketplace.json not found — cannot check the plugin's entry")
else:
    market_cfg = json_object(market, load_json(market))
    plugins_list = market_cfg.get("plugins", []) if market_cfg is not None else None
    # An entry is this plugin's by name or by source, so a second entry that loads
    # this directory under another name is counted too.
    entries = [e for e in plugins_list if isinstance(e, dict) and
               (e.get("name") == "che-telegram-mcp" or str(e.get("source", "")).rstrip("/") == "./plugins/che-telegram-mcp")] \
        if isinstance(plugins_list, list) else None
    if entries is None:
        pass
    elif len(entries) != 1:
        bad("a", f"marketplace.json has {len(entries)} entries for che-telegram-mcp (by name or source), expected 1")
    else:
        extra = set(entries[0]) - {"name", "version", "description", "author", "source", "category"}
        if extra:
            bad("a", f"marketplace entry declares {sorted(extra)} (Claude Code merges them into the plugin)")
        if entries[0].get("source") != "./plugins/che-telegram-mcp":
            bad("a", f"marketplace entry source is {entries[0].get('source')!r}, not ./plugins/che-telegram-mcp (the directory this test checks)")
manifest = os.path.join(root, ".claude-plugin", "plugin.json")
manifest_cfg = json_object(manifest, load_json(manifest)) if os.path.isfile(manifest) else None
if manifest_cfg is not None:
    extra = set(manifest_cfg) - {"name", "version", "description", "author",
                                 "homepage", "repository", "license", "keywords"}
    if extra:
        bad("a", f"plugin.json declares {sorted(extra)} (components or behaviour no check reviews)")

# ---------- (a2) files the wrappers source from lib/ ----------
if os.path.isdir(bindir):
    for name in sorted(os.listdir(bindir)):
        if not name.endswith("-wrapper.sh"):
            continue
        for line in open(os.path.join(bindir, name)).read().splitlines():
            if line.lstrip().startswith("#"):
                continue
            for rel in re.findall(r'source\s+"\$PLUGIN_ROOT/(lib/[^"]+)"', line):
                p = os.path.join(root, rel)
                if os.path.islink(p) or not os.path.isfile(p):
                    bad("a2", f"bin/{name} sources {rel}, which is not a regular file in the plugin")

# ---------- (b) / (b2) .mcp.json ----------
mcp_path = os.path.join(root, ".mcp.json")
cfg = json_object(mcp_path, load_json(mcp_path), "b") or {}
servers = cfg.get("mcpServers", cfg)
servers = servers if isinstance(servers, dict) else {}
if not servers:
    bad("b", ".mcp.json declares no servers")
if sorted(servers) != ["telegram-all", "telegram-bot"]:
    bad("b", f".mcp.json declares servers {sorted(servers)}, expected exactly ['telegram-all', 'telegram-bot']")
for name, spec in servers.items():
    extra = set(spec) - {"type", "command", "description"} if isinstance(spec, dict) else {"<not an object>"}
    if extra:
        bad("b", f".mcp.json: {name} declares {sorted(extra)} (only type, command and description are reviewed)")
for name, spec in servers.items():
    cmd = spec.get("command", "") if isinstance(spec, dict) else ""
    if not isinstance(cmd, str) or not re.fullmatch(r"\$\{CLAUDE_PLUGIN_ROOT\}/bin/[A-Za-z0-9._-]+-wrapper\.sh", cmd):
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
    # (b3) the sha256 pin belongs to DESIRED_VERSION, or there is none.
    base = os.path.basename(path)
    pins = {}
    for var, form in (("SHA256_PIN_VERSION", r"(|[0-9]+\.[0-9]+\.[0-9]+)"), ("SHA256_PIN", r"(|[0-9a-f]{64})")):
        found = [l for l in code if re.search(r"(^|[\s;&|(])" + var + "=", l)]
        lit = [m.group(1) for m in (re.match(r'^' + var + r'="' + form + r'"$', l) for l in found) if m]
        if len(found) != 1 or len(lit) != 1:
            bad("b3", f"{name}: {base} must assign {var} exactly once, as a literal "
                      + ("empty or x.y.z" if var == "SHA256_PIN_VERSION" else "empty or 64 lowercase hex digits")
                      + f" (found {len(found)} assignment(s), {len(lit)} such literal)")
        else:
            pins[var] = lit[0]
    if len(pins) == 2 and len(literal) == 1:
        desired = re.match(r'^\s*DESIRED_VERSION="([^"]*)"', literal[0]).group(1)
        pv, pin = pins["SHA256_PIN_VERSION"], pins["SHA256_PIN"]
        if not pv and not pin:
            bad("b3", f"{name}: {base} has no sha256 pin for its DESIRED_VERSION {desired}, so it would download nothing")
        elif bool(pv) != bool(pin):
            bad("b3", f"{name}: {base} sets only one of SHA256_PIN_VERSION and SHA256_PIN")
        elif pv and pv != desired:
            bad("b3", f"{name}: {base} pins a sha256 for v{pv}, but DESIRED_VERSION is {desired} "
                      f"(clear both when bumping DESIRED_VERSION; RELEASING.md sets them after the build)")

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

hook_events = (hooks_cfg or {}).get("hooks", {})
for event, matchers in (hook_events.items() if isinstance(hook_events, dict) else []):
    for m in (matchers if isinstance(matchers, list) else []):
        for h in (m.get("hooks", []) if isinstance(m, dict) and isinstance(m.get("hooks"), list) else []):
            cmd = h.get("command", "") if isinstance(h, dict) else ""
            cmd = cmd if isinstance(cmd, str) else ""
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
for name in ("auth", "chats", "search", "send", "archive-telegram", "archive-telegram-search"):
    if not os.path.isfile(os.path.join(root, "skills", name, "SKILL.md")):
        bad("h", f"skills/{name}/SKILL.md is missing")
    elif name in unreadable:
        bad("h", f"skills/{name}/SKILL.md frontmatter cannot be read — cannot check")
    elif name in meta and not literal_true(name):
        bad("h", f"skills/{name}/SKILL.md does not set disable-model-invocation to the literal true "
                 f"(found {meta_strings[name].get('disable-model-invocation')!r})")

# ---------- (j) install references name this marketplace ----------
import install_refs
# (k) Keychain commands take the secret from a prompt, never from an argument.
def keychain_command_files():
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            if rel != "CHANGELOG.md":
                yield rel
for rel in keychain_command_files():
    try:
        with open(os.path.join(root, rel), "rb") as fh:
            data = fh.read()
    except OSError as e:
        bad("k", f"{rel}: cannot be read ({e}) — not checked")
        continue
    # A file that never names the command (a .DS_Store, an image) has nothing to check;
    # one that does is read even if it is not valid UTF-8.
    if b"add-generic-password" not in data and b"add-internet-password" not in data:
        continue
    lines = data.decode("utf-8", errors="replace").splitlines()
    for n, line in enumerate(lines, 1):
        m = re.search(r"add-(generic|internet)-password", line)
        if not m:
            continue
        if re.search(r"\|\s*(sudo\s+)?(/usr/bin/)?security\s+add-(generic|internet)-password", line):
            bad("k", f"{rel}:{n}: a value is piped into security (let it prompt instead): {line.strip()}")
            continue
        # The command runs to the end of the line, or to the closing quote of
        # the echo that prints it (optionally followed by a redirection): try
        # the line as it is first, then without that closing quote.
        toks = None
        for cmd in (line[m.start():], re.sub(r'"\s*(>&\s*\d+)?\s*$', "", line[m.start():])):
            try:
                toks = shlex.split(cmd)
                break
            except ValueError:
                continue
        if toks is None:
            bad("k", f"{rel}:{n}: cannot be parsed, check it by hand: {line.strip()}")
            continue
        if any(t.startswith(("-p", "-X")) for t in toks):
            bad("k", f"{rel}:{n}: `-p` / `-X` pass the secret as an argument: {line.strip()}")
        elif not toks or toks[-1] != "-w" or toks.count("-w") != 1:
            bad("k", f"{rel}:{n}: `-w` is not the last argument (a secret after it stays in shell history): {line.strip()}")

# (l) The README's pre-approved table says the same as each skill's allowed-tools (#86).
TABLE_HEADER = "| Skill | Pre-approved | Not pre-approved |"
readme_lines = readme.splitlines()
start = next((i for i, l in enumerate(readme_lines) if l.strip() == TABLE_HEADER), None)
if start is None:
    bad("l", f"README has no pre-approved table (header {TABLE_HEADER!r}) — cannot check")
else:
    TOOL = r"(?:bot:)?[a-z][a-z0-9_]*"
    rows = {}
    k = start + 1
    if k >= len(readme_lines) or not re.fullmatch(r"\|[-:\s|]+\|", readme_lines[k].strip()):
        bad("l", f"README pre-approved table has no separator row after its header (line {start + 2})")
    k += 1
    while k < len(readme_lines) and readme_lines[k].lstrip().startswith("|"):
        line = readme_lines[k]
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        m = re.fullmatch(r"`([a-z0-9-]+)`", cells[0]) if len(cells) == 3 else None
        if not m:
            bad("l", f"README line {k + 1}: not a row of `skill` | tools | tools: {line.strip()}")
        else:
            pre_cell, not_cell = cells[1], cells[2]
            pre = set() if pre_cell in ("—", "-") else set(re.findall(f"`({TOOL})`", pre_cell))
            if pre_cell not in ("—", "-") and not pre:
                bad("l", f"README line {k + 1}: Pre-approved cell lists no `tool`: {pre_cell}")
            elif pre_cell not in ("—", "-") and re.sub(r"[,\s]", "", re.sub(f"`{TOOL}`", "", pre_cell)):
                bad("l", f"README line {k + 1}: Pre-approved cell has text that is not a `tool` (comma-separated, "
                         f"in backticks): {pre_cell}")
            if m.group(1) in rows:
                bad("l", f"README pre-approved table has two rows for {m.group(1)}")
            rows[m.group(1)] = (pre, set(re.findall(f"\\*\\*`({TOOL})`\\*\\*", not_cell)))
        k += 1
    have = {}
    for path, skill in skill_files:
        if skill in meta:
            names = set()
            for t in tool_list(meta[skill].get("allowed-tools")):
                mt = prefix.match(t)
                if mt:
                    names.add(mt.group(2) if mt.group(1) == "all" else f"bot:{mt.group(2)}")
            if names:
                have[skill] = names
    skill_names = {skill for _, skill in skill_files}
    for skill in sorted(set(have) | set(rows) | (unreadable & skill_names)):
        if skill in unreadable:
            bad("l", f"skills/{skill}: frontmatter cannot be read — cannot compare it with its table row")
        elif skill not in skill_names:
            bad("l", f"README pre-approved table has a row for {skill}, which is not a skill")
        elif skill not in rows:
            bad("l", f"README pre-approved table has no row for {skill}, which pre-approves {sorted(have[skill])}")
        elif skill not in have:
            bad("l", f"README pre-approved table has a row for {skill}, which pre-approves no tools")
        else:
            pre, not_pre = rows[skill]
            mine = have.get(skill, set())
            if pre != mine:
                bad("l", f"{skill}: the README pre-approves {sorted(pre)}, its allowed-tools has {sorted(mine)}")
            if not_pre & mine:
                bad("l", f"{skill}: allowed-tools has {sorted(not_pre & mine)}, which the README lists as not pre-approved")

for msg in install_refs.problems("che-telegram-mcp", root, os.path.join(root, "..", ".."), docs_url_required=True):
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

report a  "only reviewed components: bin/ wrappers, hooks/, lib/, skills/, metadata-only manifests"
report a2 "every file a wrapper sources from lib/ exists"
report b  ".mcp.json commands are \${CLAUDE_PLUGIN_ROOT}/bin/*-wrapper.sh and executable"
report b2 "every wrapper assigns DESIRED_VERSION exactly once, as a literal"
report b3 "every wrapper pins a sha256 for its DESIRED_VERSION"
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
report h  "auth/chats/search/send/archive-telegram/archive-telegram-search set disable-model-invocation: true"
report i  "no skill sets hooks or runs !\`command\` blocks"
report j  "the plugin and the repository README name the marketplace this repository publishes"
report k  "Keychain commands end with a bare -w (the secret is prompted for, not passed)"
report l  "the README's pre-approved table matches each skill's allowed-tools"

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed"
    exit 1
fi
echo "all checks passed"
