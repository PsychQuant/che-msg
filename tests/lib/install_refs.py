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
  2. README.md: every `<plugin>@<x>` has x == M, except one written directly
     after `uninstall` (`uninstall <plugin>@<x>`, whitespace only in between) —
     the migration steps name the old install id on purpose. At least one
     `install <plugin>@M` appears.
  3. README.md: every `marketplace add <arg>` has an argument whose last path
     segment (before any `#ref`) is M. This relies on the repository being named
     after its marketplace, which holds for che-msg and for
     psychquant-claude-plugins; without that convention a stale
     `marketplace add <old repo>` could not be caught at all.
  4. README.md and every file in bin/: every GitHub URL
     https://github.com/<owner>/<repo>/(blob|tree)/<ref>/.../plugins/<plugin>
     names repo == M, whatever <ref> is. When <ref> is a single path segment,
     the rest of the URL is also checked: the path, after resolving `.` and
     `..`, stays inside plugins/<plugin>/, exists under repo_root, and does not
     resolve through a symlink to somewhere outside that directory; and a
     `#anchor` on a .md path (percent-encoding decoded) matches one of that
     file's ATX headings. Headings inside fenced code blocks do not count; a
     fence closes only on the same character, at least as long as the opener.
     Anchors follow GitHub: lowercase, keep letters (Unicode included), digits,
     spaces, `-` and `_`, turn spaces into `-`, and give repeated headings
     `-1`, `-2`, … suffixes that skip any slug already in use.

A full stop right after an install id or a `marketplace add` argument is not
part of it.

Not checked, by design — write the docs so they do not need these:
  - an `uninstall` written anywhere other than directly before the id: a table
    cell, a backslash-continued command, prose. Those are reported, so write
    the uninstall command on one line.
  - a bare URL followed by a full stop: the stop is read as part of the path.
    Put URLs in a markdown link, `<…>` or backticks.
  - whether <ref> exists on the remote (paths are checked against this working
    tree), and the path of a URL whose <ref> contains `/`.
  - setext headings, and spellings that differ in case or put whitespace
    around `@` (`Che-Telegram-MCP@x`, `plugin @x`).
  - CHANGELOG.md: its links to the old repository are history.
"""
import json
import os
import posixpath
import re
import urllib.parse

_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_HEADING = re.compile(r"^ {0,3}#{1,6}\s+(.*?)(?:\s+#+)?\s*$")


def _slug(heading: str) -> str:
    s = heading.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")


def _headings(path: str) -> set[str]:
    """Anchors GitHub generates for the ATX headings outside code fences."""
    used: dict[str, int] = {}
    fence: tuple[str, int] | None = None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            f = _FENCE.match(line)
            if fence is None:
                if f:
                    fence = (f.group(1)[0], len(f.group(1)))
                    continue
            else:
                if f and f.group(1)[0] == fence[0] and len(f.group(1)) >= fence[1] and not f.group(2).strip():
                    fence = None
                continue
            m = _HEADING.match(line)
            if not m:
                continue
            # github-slugger: the first use of a slug is bare; later ones get
            # -1, -2, … and skip any slug that is already taken.
            base = result = _slug(m.group(1))
            while result in used:
                used[base] += 1
                result = f"{base}-{used[base]}"
            used[result] = 0
    return set(used)


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
            target = m.group(1).rstrip(".")
            before = line[:m.start()]
            if target == mp:
                if re.search(r"\binstall\s+$", before):
                    has_install = True
            elif not re.search(r"\buninstall\s+$", before):
                found.append(f"README.md:{n} names {plugin}@{target}, not {plugin}@{mp}")
        for m in re.finditer(r"marketplace add\s+[`'\"]?([A-Za-z0-9._/:@-]+)", line):
            arg = m.group(1).rstrip(".").rstrip("/")
            last = arg.rsplit("/", 1)[-1]
            if last.endswith(".git"):
                last = last[:-4]
            if last != mp:
                found.append(f"README.md:{n} adds marketplace {arg!r}, which is not {mp!r}")
    if not has_install:
        found.append(f"README.md never says `install {plugin}@{mp}`")

    tail = r"(?=[/#\s\"'()<>`]|$)"
    any_ref_re = re.compile(
        r"https://github\.com/[^/\s]+/([^/\s]+)/(?:blob|tree)/\S*?/plugins/" + re.escape(plugin) + tail)
    path_re = re.compile(
        r"https://github\.com/[^/\s]+/([^/\s]+)/(?:blob|tree)/[^/\s]+/"
        r"(plugins/" + re.escape(plugin) + r"(?:/[^\s\"'()<>#`]*)?)(?:#([\w%-]+))?")
    home = f"plugins/{plugin}"
    home_real = os.path.realpath(os.path.join(repo_root, home))
    files = [("README.md", readme)]
    bindir = os.path.join(plugin_dir, "bin")
    if os.path.isdir(bindir):
        files += [(f"bin/{f}", os.path.join(bindir, f)) for f in sorted(os.listdir(bindir))
                  if not f.startswith(".") and os.path.isfile(os.path.join(bindir, f))]
    for label, path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for m in any_ref_re.finditer(text):
            if m.group(1) != mp:
                found.append(f"{label}: {m.group(0)} points at repository {m.group(1)!r}, not {mp!r}")
        for m in path_re.finditer(text):
            if m.group(1) != mp:
                continue                      # already reported above
            rel, anchor = m.group(2).rstrip("/"), m.group(3)
            where = f"{label}: {m.group(0)}"
            norm = posixpath.normpath(rel)
            if norm != home and not norm.startswith(home + "/"):
                found.append(f"{where} — {rel} resolves to {norm}, outside {home}/")
                continue
            target = os.path.join(repo_root, norm)
            if not os.path.exists(target):
                found.append(f"{where} — {norm} does not exist in this repository")
                continue
            real = os.path.realpath(target)
            if real != home_real and not real.startswith(home_real + os.sep):
                found.append(f"{where} — {norm} is a symlink that resolves outside {home}/")
                continue
            if anchor and norm.endswith(".md"):
                try:
                    heads = _headings(target)
                except (OSError, UnicodeDecodeError) as exc:
                    found.append(f"{where} — {norm} unreadable as UTF-8 ({exc.__class__.__name__}), anchor unverified")
                    continue
                if urllib.parse.unquote(anchor) not in heads:
                    found.append(f"{where} — {norm} has no heading with anchor #{anchor}")
    return found
