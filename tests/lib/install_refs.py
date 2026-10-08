"""What a plugin's docs tell users to type must name the marketplace it ships in.

The plugin layout tests call problems() as their check (j). Background: when
che-telegram-mcp and che-archive-lines moved from psychquant-claude-plugins to
the che-msg marketplace (PsychQuant/che-msg#42), five places still named the old
home — two README install commands, two `marketplace add` commands, a "Plugin
source" link and the telegram-all wrapper's docsUrl. `claude plugin validate`
checks none of them, and a stale one keeps working for exactly as long as the
old marketplace still lists the plugin.

How text is read: lines ending in a backslash are joined with the next line.
URLs are not found with one big regex. Each line is split into tokens at
whitespace and at the characters markdown and tables put around a URL —
( ) [ ] < > " ' ` | { } — and every token containing `github.com/` is parsed
with urllib after trailing `, ; : ! ? * _ ~` and a sentence full stop are
removed (a `.` that ends a `.` or `..` path segment is kept). The repository
check and the path check therefore always look at the same URL. (Rounds 2 and 3
of the #42 verify each found a link that one regex saw and the other did not.)

problems(plugin, plugin_dir, repo_root) returns one string per problem. These
are the only rules; nothing else in the docs is checked:

  1. repo_root/.claude-plugin/marketplace.json exists, parses, and lists
     `plugin`. Its `name` is the marketplace name M used below.
  2. README.md: every `<plugin>@<x>` has x == M, unless the nearest `install`
     or `uninstall` before it on the same (joined) line is `uninstall` — the
     migration steps name the old install id on purpose. At least one
     `<plugin>@M` has `install` as its nearest such word. Options and quotes
     between the word and the id do not matter.
  3. README.md: every `marketplace add` names a marketplace whose last path
     segment (before any `#ref`, without `.git`) is M. Options starting with
     `-` are skipped, with the value after `--scope`/`-s`. An argument that
     starts with `$` cannot be checked and is reported. This relies on the
     repository being named after its marketplace, which holds for che-msg and
     for psychquant-claude-plugins.
  4. README.md and every file in bin/: every GitHub URL
     http(s)://[www.]github.com/<owner>/<repo>/(blob|tree)/<ref>/.../plugins/<plugin>
     names repo == M, whatever <ref> is. When <ref> is one path segment, the
     path must also, after resolving `.` and `..`, stay inside plugins/<plugin>/,
     exist with exactly that spelling (the check compares names, so it holds on
     a case-insensitive file system), and not resolve through a symlink to
     somewhere outside that directory.
  5. bin/ only: a `#anchor` on such a URL to a .md file (percent-encoding
     decoded) matches one of that file's headings, the way GitHub generates
     anchors: ATX headings, also inside block quotes, outside fenced code
     (closed only by the same character, at least as long as the opener; a
     backtick opener cannot contain a backtick) and outside HTML comments; the
     text has links and images reduced to their text, HTML tags removed,
     entities decoded and emphasis markers dropped; then lowercased, keeping
     letters, marks, digits, spaces, `-` and `_`, spaces turned into `-`;
     repeated slugs get -1, -2, … and skip slugs already in use. This is what
     the telegram-all wrapper's lock-refused docsUrl depends on.

Not checked, by design:
  - anchors in links from README.md (only bin/ anchors are checked);
  - setext headings, and heading text beyond the reductions listed in 5;
  - whether <ref> exists on the remote, and the path of a URL whose <ref>
    has more than one segment;
  - percent-encoded path segments (they are compared literally, so a link
    using them is reported as missing — fails closed);
  - spellings that differ in case or put whitespace around `@`
    (`Che-Telegram-MCP@x`, `plugin @x`);
  - CHANGELOG.md: its links to the old repository are history.
"""
import html
import json
import os
import posixpath
import re
import unicodedata
import urllib.parse

_TOKEN_SPLIT = re.compile(r"[\s()\[\]<>\"'`|{}]+")
_GITHUB = re.compile(r"(?:https?://)?(?:www\.)?github\.com/", re.I)
_TRAIL = ",;:!?*_~"
_CMD = re.compile(r"\b(uninstall|install)\b", re.I)
_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_HEADING = re.compile(r"^ {0,3}(?:>\s?)*#{1,6}(?:\s+(.*?))?(?:\s+#+)?\s*$")


def _joined_lines(text: str) -> list[str]:
    out: list[str] = []
    buf = ""
    for line in text.splitlines():
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        out.append(buf + line)
        buf = ""
    if buf:
        out.append(buf)
    return out


def _strip_trailing(tok: str) -> str:
    while tok:
        if tok[-1] in _TRAIL:
            tok = tok[:-1]
        elif tok[-1] == "." and len(tok) > 1 and tok[-2] not in "./":
            tok = tok[:-1]
        else:
            break
    return tok


def _github_urls(line: str) -> list[str]:
    urls: list[str] = []
    for tok in _TOKEN_SPLIT.split(line):
        m = _GITHUB.search(tok)
        if not m:
            continue
        tok = _strip_trailing(tok[m.start():])
        if not tok.lower().startswith("http"):
            tok = "https://" + tok
        urls.append(tok)
    return urls


def _slug_text(raw: str) -> str:
    s = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", raw)      # images -> alt
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)          # links -> text
    s = re.sub(r"<[^>]+>", "", s)                            # HTML tags
    s = html.unescape(s)
    s = s.replace("`", "").replace("*", "")
    s = re.sub(r"(?<!\w)_+|_+(?!\w)", "", s)                # emphasis underscores
    s = s.strip().lower()
    kept = []
    for ch in s:
        cat = unicodedata.category(ch)
        if cat[0] in "LMN" or ch in " -_":
            kept.append(ch)
    return "".join(kept).replace(" ", "-")


def _headings(path: str) -> set[str]:
    """Anchors GitHub generates for the ATX headings of a markdown file."""
    used: dict[str, int] = {}
    fence: tuple[str, int] | None = None
    in_comment = False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if fence is not None:
                f = _FENCE.match(line)
                if f and f.group(1)[0] == fence[0] and len(f.group(1)) >= fence[1] and not f.group(2).strip():
                    fence = None
                continue
            if in_comment:
                if "-->" in line:
                    in_comment = False
                continue
            f = _FENCE.match(line)
            if f and not (f.group(1)[0] == "`" and "`" in f.group(2)):
                fence = (f.group(1)[0], len(f.group(1)))
                continue
            if line.lstrip().startswith("<!--") and "-->" not in line.split("<!--", 1)[1]:
                in_comment = True
                continue
            m = _HEADING.match(line)
            if not m:
                continue
            # github-slugger: the first use of a slug is bare; later ones get
            # -1, -2, … and skip any slug that is already taken.
            base = result = _slug_text(m.group(1) or "")
            while result in used:
                used[base] += 1
                result = f"{base}-{used[base]}"
            used[result] = 0
    return set(used)


def _exists_exact(root: str, rel: str) -> bool:
    cur = root
    for seg in rel.split("/"):
        try:
            names = os.listdir(cur)
        except OSError:
            return False
        if seg not in names:
            return False
        cur = os.path.join(cur, seg)
    return True


def _within(path: str, base: str) -> bool:
    real = os.path.realpath(path)
    return real == base or real.startswith(base + os.sep)


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

    plugin_real = os.path.realpath(plugin_dir)
    readme = os.path.join(plugin_dir, "README.md")
    if not _within(readme, plugin_real):
        return found + ["README.md is a symlink that resolves outside the plugin — install references unverified"]
    try:
        with open(readme, encoding="utf-8") as fh:
            lines = _joined_lines(fh.read())
    except (OSError, UnicodeDecodeError) as exc:
        # Fail closed, but only this check: a README that is not UTF-8 must not
        # crash the shared parser and hide the other checks' results.
        return found + [f"README.md unreadable as UTF-8 ({exc.__class__.__name__}) — install references unverified"]

    install_re = re.compile(r"(?<![\w.@-])" + re.escape(plugin) + r"@([A-Za-z0-9._-]+)")
    has_install = False
    for n, line in enumerate(lines, 1):
        for m in install_re.finditer(line):
            target = m.group(1).rstrip(".")
            words = _CMD.findall(line[:m.start()])
            nearest = words[-1].lower() if words else None
            if target == mp:
                if nearest == "install":
                    has_install = True
            elif nearest != "uninstall":
                found.append(f"README.md:{n} names {plugin}@{target}, not {plugin}@{mp}")
        for m in re.finditer(r"\bmarketplace\s+add\b(.*)", line):
            toks = m.group(1).split()
            arg, i = None, 0
            while i < len(toks):
                t, prev = toks[i], None
                while t != prev:                    # `x`. and (x), in either order
                    prev, t = t, _strip_trailing(t.strip("`'\"<>()[]*"))
                if t in ("--scope", "-s"):
                    i += 2
                    continue
                if t.startswith("-") or not t:
                    i += 1
                    continue
                arg = t
                break
            if arg is None:
                continue
            if arg.startswith("$"):
                found.append(f"README.md:{n} adds marketplace {arg!r}, which cannot be checked")
                continue
            arg = arg.split("#", 1)[0].rstrip("/")
            last = arg.rsplit("/", 1)[-1]
            if last.endswith(".git"):
                last = last[:-4]
            if last != mp:
                found.append(f"README.md:{n} adds marketplace {arg!r}, which is not {mp!r}")
    if not has_install:
        found.append(f"README.md never says `install {plugin}@{mp}`")

    home = f"plugins/{plugin}"
    home_real = os.path.realpath(os.path.join(repo_root, home))
    files = [("README.md", readme, False)]
    bindir = os.path.join(plugin_dir, "bin")
    if os.path.isdir(bindir):
        for f in sorted(os.listdir(bindir)):
            p = os.path.join(bindir, f)
            if f.startswith(".") or not os.path.isfile(p):
                continue
            if not _within(p, plugin_real):
                found.append(f"bin/{f} is a symlink that resolves outside the plugin — not checked")
                continue
            files.append((f"bin/{f}", p, True))
    for label, path, check_anchor in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for line in _joined_lines(text):
            for url in _github_urls(line):
                parsed = urllib.parse.urlsplit(url)
                seg = parsed.path.split("/")
                if len(seg) < 6 or seg[3] not in ("blob", "tree"):
                    continue
                rest = seg[4:]
                k = next((i for i in range(1, len(rest) - 1) if rest[i] == "plugins" and rest[i + 1] == plugin), None)
                if k is None:
                    continue
                repo = seg[2]
                where = f"{label}: {url}"
                if repo != mp:
                    found.append(f"{where} points at repository {repo!r}, not {mp!r}")
                    continue
                if k != 1:
                    continue                        # multi-segment ref: path not checked
                rel = "/".join(rest[k:]).rstrip("/")
                norm = posixpath.normpath(rel)
                if norm != home and not norm.startswith(home + "/"):
                    found.append(f"{where} — {rel} resolves to {norm}, outside {home}/")
                    continue
                target = os.path.join(repo_root, norm)
                if not _exists_exact(repo_root, norm):
                    found.append(f"{where} — {norm} does not exist in this repository (names compared exactly)")
                    continue
                if not _within(target, home_real):
                    found.append(f"{where} — {norm} is a symlink that resolves outside {home}/")
                    continue
                anchor = parsed.fragment
                if check_anchor and anchor and norm.endswith(".md"):
                    try:
                        heads = _headings(target)
                    except (OSError, UnicodeDecodeError) as exc:
                        found.append(f"{where} — {norm} unreadable as UTF-8 ({exc.__class__.__name__}), anchor unverified")
                        continue
                    if urllib.parse.unquote(anchor) not in heads:
                        found.append(f"{where} — {norm} has no heading with anchor #{anchor}")
    return found
