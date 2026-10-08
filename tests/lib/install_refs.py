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
  2. README.md: every `<plugin>@<x>` has x == M, except on a line that
     uninstalls — the migration steps name the old install id on purpose. At
     least one `install <plugin>@M` appears.
  3. README.md: every `marketplace add <arg>` has an argument whose last path
     segment (before any `#ref`) is M. This relies on the repository being named
     after its marketplace, which holds for che-msg and for
     psychquant-claude-plugins; without that convention a stale
     `marketplace add <old repo>` could not be caught at all.
  4. README.md and every file in bin/: each GitHub URL of the form
     https://github.com/<owner>/<repo>/(blob|tree)/<ref>/plugins/<plugin>...
     has repo == M and a path that exists under repo_root, and a `#anchor` on a
     .md path matches one of that file's headings (GitHub's slug rule, ASCII
     subset: lowercase, drop everything but letters, digits, spaces, `-` and
     `_`, spaces to `-`).

CHANGELOG.md is not checked: its links to the old repository are history.
"""
import json
import os
import re


def _slug(heading: str) -> str:
    s = heading.strip().lower()
    s = re.sub(r"[^a-z0-9 _-]", "", s)
    return s.replace(" ", "-")


def _headings(path: str) -> set[str]:
    out = set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
            if m:
                out.add(_slug(m.group(1)))
    return out


def problems(plugin: str, plugin_dir: str, repo_root: str) -> list[str]:
    found = []
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
    except OSError:
        return found + ["README.md unreadable — install references unverified"]

    install_re = re.compile(re.escape(plugin) + r"@([A-Za-z0-9._-]+)")
    has_install = False
    for n, line in enumerate(lines, 1):
        for m in install_re.finditer(line):
            if m.group(1) == mp:
                if re.search(r"\binstall\s+" + re.escape(f"{plugin}@{mp}") + r"\b", line):
                    has_install = True
            elif not re.search(r"\buninstall\b", line):
                found.append(f"README.md:{n} names {plugin}@{m.group(1)}, not {plugin}@{mp}")
        for m in re.finditer(r"marketplace add\s+(\S+)", line):
            arg = m.group(1).strip("`'\"").split("#", 1)[0].rstrip("/")
            last = arg.rsplit("/", 1)[-1]
            if last.endswith(".git"):
                last = last[:-4]
            if last != mp:
                found.append(f"README.md:{n} adds marketplace {arg!r}, which is not {mp!r}")
    if not has_install:
        found.append(f"README.md never says `install {plugin}@{mp}`")

    url_re = re.compile(
        r"https://github\.com/([^/\s]+)/([^/\s]+)/(?:blob|tree)/([^/\s]+)/"
        r"(plugins/" + re.escape(plugin) + r"(?:/[^\s\"'()<>#`]*)?)(?:#([A-Za-z0-9_-]+))?")
    files = [("README.md", readme)]
    bindir = os.path.join(plugin_dir, "bin")
    if os.path.isdir(bindir):
        files += [(f"bin/{f}", os.path.join(bindir, f)) for f in sorted(os.listdir(bindir))
                  if not f.startswith(".") and os.path.isfile(os.path.join(bindir, f))]
    for label, path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for m in url_re.finditer(text):
            repo, rel, anchor = m.group(2), m.group(4).rstrip("/"), m.group(5)
            where = f"{label}: {m.group(0)}"
            if repo != mp:
                found.append(f"{where} points at repository {repo!r}, not {mp!r}")
                continue
            target = os.path.join(repo_root, rel)
            if not os.path.exists(target):
                found.append(f"{where} — {rel} does not exist in this repository")
            elif anchor and rel.endswith(".md") and anchor not in _headings(target):
                found.append(f"{where} — {rel} has no heading with anchor #{anchor}")
    return found
