"""What a plugin's docs tell users to type must name the marketplace it ships in.

The plugin layout tests call problems() as their check (j). Background: when
che-telegram-mcp and che-archive-lines moved from psychquant-claude-plugins to
the che-msg marketplace (PsychQuant/che-msg#42), five places still named the old
home — two README install commands, two `marketplace add` commands, a "Plugin
source" link and the telegram-all wrapper's docsUrl. `claude plugin validate`
checks none of them, and a stale one keeps working for exactly as long as the
old marketplace still lists the plugin.

problems(plugin, plugin_dir, repo_root) returns one string per problem. These
are the only rules; nothing else in the docs is checked:

  1. repo_root/.claude-plugin/marketplace.json exists, parses, and lists
     `plugin`. Its `name` is the marketplace name M used below.
  2. README.md: every `<plugin>@<x>` has x == M, unless the shell command that
     contains it (the stretch of the line between `;`, `&&`, `||` or `|`) runs
     `uninstall` before it — the migration steps name the old install id on
     purpose. At least one `install <plugin>@M` appears.
  3. README.md: every `marketplace add <arg>` has an argument whose last path
     segment (before any `#ref`) is M. This relies on the repository being named
     after its marketplace, which holds for che-msg and for
     psychquant-claude-plugins; without that convention a stale
     `marketplace add <old repo>` could not be caught at all.
  4. README.md and every file in bin/: each GitHub URL of the form
     https://github.com/<owner>/<repo>/(blob|tree)/<ref>/plugins/<plugin>...
     has repo == M and a path that, after resolving `.` and `..`, stays inside
     plugins/<plugin>/ and exists under repo_root; a `#anchor` on a .md path
     must match one of that file's headings. Headings inside fenced code blocks
     do not count (a `# comment` in a bash block is not a heading). Anchors
     follow GitHub's rule: lowercase, drop everything except letters (Unicode
     included), digits, spaces, `-` and `_`, turn spaces into `-`, and add `-1`,
     `-2`, … to repeated headings.

Sentence punctuation (`.`, `,`, `;`, `:`) right after an install id, a
`marketplace add` argument or a URL path is not part of it.

Not checked, by design: whether `<ref>` exists on the remote (the path is
checked against this working tree), and spellings that differ in case or put
whitespace around `@` (`Che-Telegram-MCP@x`, `plugin @x`). CHANGELOG.md is not
checked either: its links to the old repository are history.
"""
import json
import os
import posixpath
import re

_TRAIL = ".,;:"
_SEPARATOR = re.compile(r";|&&|\|\|?")
_FENCE = re.compile(r"^\s*(```|~~~)")


def _slug(heading: str) -> str:
    s = heading.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")


def _headings(path: str) -> set[str]:
    out: set[str] = set()
    seen: dict[str, int] = {}
    in_fence = False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if _FENCE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            m = re.match(r"^#{1,6}\s+(.*?)(?:\s+#+)?\s*$", line)
            if not m:
                continue
            base = _slug(m.group(1))
            n = seen.get(base, 0)
            seen[base] = n + 1
            out.add(base if n == 0 else f"{base}-{n}")
    return out


def _command_before(line: str, pos: int) -> str:
    """The text of the shell command that contains `pos`, up to `pos`."""
    start = 0
    for sep in _SEPARATOR.finditer(line, 0, pos):
        start = sep.end()
    return line[start:pos]


def problems(plugin: str, plugin_dir: str, repo_root: str) -> list[str]:
    found: list[str] = []
    market = os.path.join(repo_root, ".claude-plugin", "marketplace.json")
    try:
        with open(market, encoding="utf-8") as fh:
            data = json.load(fh)
        mp = data["name"]
        listed = [e for e in data.get("plugins", []) if e.get("name") == plugin]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return [f"cannot read the marketplace name from .claude-plugin/marketplace.json ({exc.__class__.__name__}) — install references unverified"]
    if not isinstance(mp, str) or not mp:
        return ["marketplace.json has no usable name — install references unverified"]
    if not listed:
        found.append(f"marketplace {mp!r} does not list {plugin}")

    readme = os.path.join(plugin_dir, "README.md")
    try:
        with open(readme, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        # Fail closed, but only this check: a README that is not UTF-8 must not
        # crash the shared parser and hide the other checks' results.
        return found + [f"README.md unreadable as UTF-8 ({exc.__class__.__name__}) — install references unverified"]

    install_re = re.compile(re.escape(plugin) + r"@([A-Za-z0-9._-]+)")
    has_install = False
    for n, line in enumerate(lines, 1):
        for m in install_re.finditer(line):
            target = m.group(1).rstrip(_TRAIL)
            command = _command_before(line, m.start())
            if target == mp:
                if re.search(r"\binstall\s+$", command) and not re.search(r"\buninstall\s+$", command):
                    has_install = True
            elif not re.search(r"\buninstall\b", command):
                found.append(f"README.md:{n} names {plugin}@{target}, not {plugin}@{mp}")
        for m in re.finditer(r"marketplace add\s+(\S+)", line):
            arg = m.group(1).strip("`'\"").split("#", 1)[0].rstrip(_TRAIL).rstrip("/")
            last = arg.rsplit("/", 1)[-1]
            if last.endswith(".git"):
                last = last[:-4]
            if last != mp:
                found.append(f"README.md:{n} adds marketplace {arg!r}, which is not {mp!r}")
    if not has_install:
        found.append(f"README.md never says `install {plugin}@{mp}`")

    url_re = re.compile(
        r"https://github\.com/([^/\s]+)/([^/\s]+)/(?:blob|tree)/([^/\s]+)/"
        r"(plugins/" + re.escape(plugin) + r"(?:/[^\s\"'()<>#`]*)?)(?:#([\w-]+))?")
    home = f"plugins/{plugin}"
    files = [("README.md", readme)]
    bindir = os.path.join(plugin_dir, "bin")
    if os.path.isdir(bindir):
        files += [(f"bin/{f}", os.path.join(bindir, f)) for f in sorted(os.listdir(bindir))
                  if not f.startswith(".") and os.path.isfile(os.path.join(bindir, f))]
    for label, path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for m in url_re.finditer(text):
            repo, anchor = m.group(2), m.group(5)
            rel = m.group(4).rstrip(_TRAIL).rstrip("/")
            where = f"{label}: {m.group(0)}"
            if repo != mp:
                found.append(f"{where} points at repository {repo!r}, not {mp!r}")
                continue
            norm = posixpath.normpath(rel)
            if norm != home and not norm.startswith(home + "/"):
                found.append(f"{where} — {rel} resolves to {norm}, outside {home}/")
                continue
            target = os.path.join(repo_root, norm)
            if not os.path.exists(target):
                found.append(f"{where} — {norm} does not exist in this repository")
            elif anchor and norm.endswith(".md"):
                try:
                    heads = _headings(target)
                except (OSError, UnicodeDecodeError) as exc:
                    found.append(f"{where} — {norm} unreadable as UTF-8 ({exc.__class__.__name__}), anchor unverified")
                    continue
                if anchor not in heads:
                    found.append(f"{where} — {norm} has no heading with anchor #{anchor}")
    return found
