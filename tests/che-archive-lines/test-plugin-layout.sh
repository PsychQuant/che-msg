#!/bin/bash
# Structural regression test for the che-archive-lines plugin layout (#139).
#
# Guards what `claude plugin validate` does not check:
#   (a)  the plugin contains only the reviewed components: .claude-plugin/
#        plugin.json (no hooks, mcpServers, lspServers, monitors or component
#        paths in it), skills/archive-lines/SKILL.md, scripts/line-save-chat.sh,
#        README.md and CHANGELOG.md. A hooks/ directory, .mcp.json, .lsp.json,
#        commands/, agents/, bin/ or a second skill could run commands that no
#        check below looks at (#139 verify round 3). The plugin's entry in the
#        repo's .claude-plugin/marketplace.json is checked too: Claude Code
#        merges an entry's hooks, skills, commands and agents into the plugin
#        (round 4).
#   (b)  EVERY mention of line-save-chat.sh in the skill body is the path
#        ${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh, and that script exists
#        and is executable. Claude Code substitutes ${CLAUDE_PLUGIN_ROOT} in skill
#        content; any other spelling (scripts/…, ./scripts/…, the unbraced
#        $CLAUDE_PLUGIN_ROOT) resolves against the user's project or not at all.
#   (c)  no $0 / ${0 / $(dirname in the body: in skill content $0 is the first
#        argument (save, test, …), so a path derived from it is cwd-relative.
#   (d)  no hard-coded per-machine path anywhere in the plugin: no home
#        directory, no cloud-sync folder (CloudStorage, Dropbox, iCloud's Mobile
#        Documents), no ~/.claude/plugins/<name>/ copy location. This repo is
#        public. Files are read as bytes and decoded as UTF-16 when they carry a
#        UTF-16 BOM, otherwise as UTF-8 with errors="replace", so no file is
#        skipped.
#   (e)  allowed-tools is exactly these three rules, in any order:
#          Bash(${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh save)
#          Bash(${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh test)
#          Bash(${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh help)
#        Claude Code matches a rule against each subcommand of a pipeline, so a
#        trailing `*` (…line-save-chat.sh *) also pre-approved calibrate, even
#        with `printf '\n\n' |` piped in front (#139 verify round 2). With exact
#        rules calibrate goes through the user's normal permission settings.
#        The frontmatter uses only the reviewed keys (name, description,
#        argument-hint, disable-model-invocation, allowed-tools): `hooks` stay
#        registered for the rest of the session, beyond the turn's grant, and
#        keys such as context, agent, model or shell change how the skill runs.
#        The body has no !`command` or ```! block: those run when the skill is
#        invoked, before Claude reads it, and one that matches the rules above
#        would click in LINE with no prompt as soon as the skill opens.
#   (f)  disable-model-invocation is the literal, unquoted `true` — only the user
#        starts GUI automation. Claude Code 2.1.218+ also accepts yes/on/1, but
#        earlier versions recognise only true, so the test accepts only true.
#   (n)  name: archive-lines — without a frontmatter name, a plugin skill has no
#        bare /archive-lines alias, and the README promises one.
#   (j)  the plugin sends users to the marketplace this repository publishes:
#        in every plugin file but the top-level CHANGELOG.md, in the repository
#        README and in marketplace.json, the former marketplace name appears
#        only in listed shapes; the README installs from and adds this
#        marketplace. The rules are in tests/lib/install_refs.py
#        (PsychQuant/che-msg#42: five such places still named the old
#        marketplace after the move).
#   (fm) the skill's frontmatter stays inside the subset Claude Code and this
#        test read the same way (tests/lib/frontmatter_subset.py).
#
# How the frontmatter is read: tests/lib/frontmatter_subset.py splits it off
# the way Claude Code does and lists why a block falls outside the plain YAML
# subset in which PyYAML (used here) and Claude Code's Bun.YAML read the same
# thing and Bun's first parse succeeds; (fm) fails on any such reason. See that
# module for the cases and the fuzz evidence (tests/frontmatter-subset-fuzz/).
# Every check FAILS CLOSED: if the parser cannot run, the test fails instead of
# passing.
#
# Usage:
#   bash tests/che-archive-lines/test-plugin-layout.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../../plugins/che-archive-lines" 2>/dev/null && pwd)"

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

echo "test-plugin-layout.sh (#139) — $PLUGIN_DIR"

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

SCRIPT_PATH = "${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh"
ALLOWED_RULES = {f"Bash({SCRIPT_PATH} {verb})" for verb in ("save", "test", "help")}
FM_KEYS = {"name", "description", "argument-hint", "disable-model-invocation", "allowed-tools"}

IGNORED = {".DS_Store"}

def listing(path):
    return sorted(set(os.listdir(path)) - IGNORED) if os.path.isdir(path) else None

# ---------- (a) only the reviewed components ----------
expected = {
    "": [".claude-plugin", "CHANGELOG.md", "README.md", "scripts", "skills"],
    ".claude-plugin": ["plugin.json"],
    "skills": ["archive-lines"],
    "skills/archive-lines": ["SKILL.md"],
    "scripts": ["line-save-chat.sh"],
}
for rel, want in expected.items():
    got = listing(os.path.join(root, rel))
    if got != want:
        bad("a", f"{rel or '.'}/ contains {got}, expected exactly {want}")
market = os.path.join(root, "..", "..", ".claude-plugin", "marketplace.json")
if not os.path.isfile(market):
    bad("a", "repo .claude-plugin/marketplace.json not found — cannot check the plugin's entry")
else:
    entries = [e for e in json.load(open(market)).get("plugins", []) if e.get("name") == "che-archive-lines"]
    if len(entries) != 1:
        bad("a", f"marketplace.json has {len(entries)} che-archive-lines entries, expected 1")
    else:
        extra = set(entries[0]) - {"name", "version", "description", "author", "source", "category"}
        if extra:
            bad("a", f"marketplace entry declares {sorted(extra)} (Claude Code merges them into the plugin)")
        if entries[0].get("source") != "./plugins/che-archive-lines":
            bad("a", f"marketplace entry source is {entries[0].get('source')!r}, not ./plugins/che-archive-lines (the directory this test checks)")
manifest = os.path.join(root, ".claude-plugin", "plugin.json")
if os.path.isfile(manifest):
    extra = set(json.load(open(manifest))) - {"name", "version", "description", "author",
                                              "homepage", "repository", "license", "keywords"}
    if extra:
        bad("a", f"plugin.json declares {sorted(extra)} (components or behaviour no check reviews)")

# ---------- skill ----------
# A missing skill must not make the checks that read it look clean: (fm) (c)
# (e) (f) (n) are reported as failures ("cannot check"), never as passes. (d)
# scans the whole plugin and runs regardless.
skill = os.path.join(root, "skills", "archive-lines", "SKILL.md")
script = os.path.join(root, "scripts", "line-save-chat.sh")
fm, fm_raw, body = None, None, None
if not os.path.isfile(skill):
    bad("b", "skills/archive-lines/SKILL.md is missing")
    for tag in ("fm", "c", "e", "f", "n"):
        bad(tag, "skills/archive-lines/SKILL.md is missing — cannot check")
else:
    text = open(skill, encoding="utf-8-sig", newline="").read()
    block, body = fs.split(text)
    if block is None:
        bad("fm", "skills/archive-lines/SKILL.md has no frontmatter Claude Code can read")
        for tag in ("e", "f", "n"):
            bad(tag, "no readable frontmatter — cannot check")
    elif fs.subset_problems(block):
        # Outside the subset PyYAML's reading cannot be trusted, so it is not
        # used: (e) (f) (n) are reported as unverifiable, never as passes.
        for problem in fs.subset_problems(block):
            bad("fm", f"frontmatter {problem}")
        for tag in ("e", "f", "n"):
            bad(tag, "frontmatter outside the subset Claude Code and this test read alike — cannot check")
    else:
        fm = yaml.safe_load(block) or {}
        # BaseLoader builds no Python objects: every scalar stays a string, so
        # (f) can tell a literal true from yes/on/1/"true".
        fm_raw = yaml.load(block, Loader=yaml.BaseLoader) or {}
        if not isinstance(fm, dict) or not isinstance(fm_raw, dict):
            raise SystemExit("frontmatter is not a mapping")

# ---------- (b) ----------
if body is not None:
    for mt in re.finditer(r"line-save-chat\.sh", body):
        start = mt.start() - len("${CLAUDE_PLUGIN_ROOT}/scripts/")
        if start < 0 or body[start:mt.end()] != SCRIPT_PATH:
            line = body[:mt.start()].count("\n") + 1
            bad("b", f"skill body line {line} names the script without ${{CLAUDE_PLUGIN_ROOT}}/scripts/: "
                     + body.splitlines()[line - 1].strip())
    if SCRIPT_PATH not in body:
        bad("b", "skill body never runs " + SCRIPT_PATH)
if not (os.path.isfile(script) and os.access(script, os.X_OK)):
    bad("b", "scripts/line-save-chat.sh is missing or not executable")

# ---------- (c) ----------
if body is not None:
    if re.search(r"\$\{?0", body):
        bad("c", "skill uses $0 — in skill content $0 is the first argument, not a path")
    if re.search(r"\$\(dirname", body):
        bad("c", "skill derives a path with $(dirname …)")
    if re.search(r"\$CLAUDE_PLUGIN_ROOT", body):
        bad("c", "skill uses unbraced $CLAUDE_PLUGIN_ROOT — only ${CLAUDE_PLUGIN_ROOT} is substituted")

# ---------- (d) every file in the plugin ----------
patterns = [
    (r"/Users/[^/\s`'\"]+/", "a home-directory absolute path"),
    (r"/home/[^/\s`'\"]+/", "a home-directory absolute path"),
    (r"CloudStorage/", "a cloud-sync folder path"),
    (r"Dropbox/", "a cloud-sync folder path"),
    (r"Mobile Documents/", "an iCloud Drive path"),
    (r"~/\.claude/plugins/che-archive-lines", "the obsolete ~/.claude/plugins/<name> install location"),
]
for dirpath, _, files in os.walk(root):
    for fname in files:
        p = os.path.join(dirpath, fname)
        rel = os.path.relpath(p, root)
        try:
            data = open(p, "rb").read()
            if data.startswith((b"\xff\xfe", b"\xfe\xff")):
                content = data.decode("utf-16", errors="replace")
            else:
                content = data.decode("utf-8", errors="replace")
        except OSError as e:
            bad("d", f"{rel} cannot be read — cannot check ({e})")
            continue
        for pat, what in patterns:
            if re.search(pat, content):
                bad("d", f"{rel} contains {what}")

if fm is not None:
    # ---------- (e) ----------
    raw = fm.get("allowed-tools")
    if raw is None:
        tools = []
    elif isinstance(raw, str):
        # space- or comma-separated; a rule's parentheses may contain spaces
        tools = re.findall(r"[^\s,()]+(?:\([^)]*\))?", raw)
    elif isinstance(raw, list):
        tools = [str(t).strip() for t in raw]
    else:
        raise SystemExit(f"allowed-tools has unsupported type {type(raw).__name__}")
    if sorted(tools) != sorted(ALLOWED_RULES):
        bad("e", f"allowed-tools must be exactly {sorted(ALLOWED_RULES)}; found {tools}")
    extra_keys = set(fm) | set(fm_raw)
    extra_keys = {str(k) for k in extra_keys} - FM_KEYS
    if extra_keys:
        bad("e", f"frontmatter sets keys outside the reviewed set: {sorted(extra_keys)}")
if body is not None and re.search(r"!`|```!", body):
    bad("e", "skill body has a !`command` or ```! block (runs when the skill is invoked)")

if fm is not None:
    # ---------- (f) ----------
    key = "disable-model-invocation"
    if not (fm.get(key) is True and str(fm_raw.get(key, "")).strip().lower() == "true"):
        bad("f", f"{key} is not the unquoted literal true (found {fm_raw.get(key)!r})")

    # ---------- (n) ----------
    if fm.get("name") != "archive-lines":
        bad("n", f"name must be archive-lines (found {fm.get('name')!r})")

# ---------- (j) install references name this marketplace ----------
import install_refs
for msg in install_refs.problems("che-archive-lines", root, os.path.join(root, "..", "..")):
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

report a  "only the reviewed components (no hooks, MCP/LSP servers, commands, agents, other skills)"
report fm "the skill has frontmatter Claude Code reads the same way"
report b  "every script path in the skill is \${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh"
report c  "no \$0, \$(dirname) or unbraced \$CLAUDE_PLUGIN_ROOT"
report d  "no hard-coded per-machine path in the plugin"
report e  "pre-approves only save/test/help; no other keys, hooks or !\`command\` blocks"
report f  "disable-model-invocation: true"
report n  "name: archive-lines"
report j  "the plugin and the repository README name the marketplace this repository publishes"

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed"
    exit 1
fi
echo "all checks passed"
