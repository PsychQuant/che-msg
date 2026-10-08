"""What a plugin's docs tell users to type must name the marketplace it ships in.

The plugin layout tests call problems() as their check (j). Background: when
che-telegram-mcp and che-archive-lines moved from psychquant-claude-plugins to
the che-msg marketplace (PsychQuant/che-msg#42), five places still named the old
home — two README install commands, two `marketplace add` commands, a "Plugin
source" link and the telegram-all wrapper's docsUrl. `claude plugin validate`
checks none of them, and a stale one keeps working for exactly as long as the
old marketplace still lists the plugin.

Why the rules are this narrow. Rounds 1-4 of the #42 verify tested an earlier
version that parsed every GitHub URL and every `marketplace add` argument in the
docs. Each round found a new kind of text it read wrongly — a full stop, a query
string, a table cell, full-width punctuation, raw.githubusercontent.com, a second
command on one line — and most of them let a link to the old repository through.
These rules parse no URLs. The old marketplace is found by its name, wherever it
is and whatever surrounds it, and the few shapes in which the name may appear
are listed. Do not widen a rule back into "every URL" or "every argument"
without reading that history.

Text is read line by line; a line ending in a backslash is joined with the next
one, and a problem is reported at the line where the joined line starts. Before
rules 2-4 look at a line it is NFKC-normalised (full-width `／` becomes `/`) and
invisible format characters (Unicode category Cf, such as U+200B) are removed.

problems(plugin, plugin_dir, repo_root) returns one string per problem. These
five rules are the whole check; nothing else is checked:

  1. repo_root/.claude-plugin/marketplace.json exists, parses, has a non-empty
     `name` (M below) and lists `plugin`.
  2. Former names. In README.md and in every file in bin/, each occurrence of
     a name in FORMER, matched without regard to letter case, must have one of
     these three shapes. The list is closed: an occurrence that fits none of
     them is reported, however harmless it looks.
       a. it directly follows `@` (an install id) and the nearest `install` or
          `uninstall` before it on the line is `uninstall` — the migration
          steps name the old install id on purpose;
       b. it is directly followed by `/issues/<digit>` or `/pull/<digit>` — a
          link to the old repository's issue tracker, which is history;
       c. the character before it is not `/` or `@`, and what follows it does
          not start with `/` or `.git` — the name as a word, in prose, a
          heading or an anchor.
     So `<owner>/<former>` (a `marketplace add` argument, a clone URL, a link
     to the repository) and `<former>/<anything else>` (a link into the old
     repository on any host: blob, tree, raw, edit, blame, …) are reported.
  3. README.md install ids: every `<plugin>@X` — the plugin name matched
     without regard to case and not directly after an ASCII letter or digit,
     `.`, `-` or `@` — has X == M, unless the nearest `install`/`uninstall`
     before it on the line is `uninstall`. At least one `<plugin>@M` has
     `install` as its nearest such word. A `.` ending X is a full stop.
  4. README.md has a line where `marketplace add`, then whitespace, is
     followed by M or by something ending in `/M`, optionally with `.git`,
     and then whitespace, a backtick or the end of the line.
  5. bin/: wherever a file contains `docsUrl`, it is a JSON member
     `"docsUrl":"<url>"` (whitespace allowed around the colon), and <url> is
     exactly https://github.com/<R>/blob/main/plugins/<plugin>/README.md#<a>
     where <R> is the file's own GITHUB_REPO="…" value (the repository the
     wrapper downloads its binary from) and the last segment of <R> is M.
     <a>, percent-decoded, must be the anchor GitHub gives one of the headings
     of the plugin's README.md. Headings counted: ATX headings (`#`-`######`
     after at most three spaces) outside fenced code blocks and outside HTML
     comments that start a line. A fence closes only with the same character,
     at least as many, and nothing after it; a backtick opener whose info
     string has a backtick is not a fence. Headings inside block quotes are
     NOT counted — GitHub does give them anchors, so this can only make the
     check fail, never pass. The anchor of a heading: links and images reduced
     to their text, HTML tags removed, entities decoded, `` ` ``, `*` and
     emphasis `_` dropped, lowercased, only letters, marks, digits, spaces,
     `-` and `_` kept, spaces turned into `-`; a repeated slug gets -1, -2, …,
     skipping slugs already in use.

Not checked, by design (listed so that nobody reads them as passes):
  - links into this repository other than docsUrl values — their paths, `..`,
    whether the file exists, symlinks;
  - a `marketplace add` naming a third marketplace that is neither M nor in
    FORMER, or a former name given bare as its argument (a relative path,
    which fits shape 2c);
  - anchors anywhere except docsUrl values in bin/; setext headings;
  - whether the `main` branch named in a docsUrl exists on the remote;
  - install ids with whitespace around `@`;
  - CHANGELOG.md: its references to the old repository are history.

When a plugin moves again, add the marketplace it leaves to FORMER.
"""
import bisect
import html
import json
import os
import re
import unicodedata
import urllib.parse

FORMER = ("psychquant-claude-plugins",)

_CMD = re.compile(r"(?<![A-Za-z])(uninstall|install)(?![A-Za-z])", re.I)
_HISTORY = re.compile(r"/(?:issues|pull)/\d", re.I)
_DOCS_URL = re.compile(r'"docsUrl"\s*:\s*"([^"]*)"')
_GITHUB_REPO = re.compile(r'^GITHUB_REPO="([^"]+)"', re.M)
_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_HEADING = re.compile(r"^ {0,3}#{1,6}(?:\s+(.*?))?(?:\s+#+)?\s*$")


def _joined_lines(text: str) -> list[tuple[int, str]]:
    """Backslash-continued lines joined; each keeps the number of its first line."""
    out: list[tuple[int, str]] = []
    buf, start = None, 0
    for n, line in enumerate(text.splitlines(), 1):
        if buf is None:
            buf, start = "", n
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        out.append((start, buf + line))
        buf = None
    if buf is not None:
        out.append((start, buf))
    return out


def _clean(line: str) -> str:
    norm = unicodedata.normalize("NFKC", line)
    return "".join(ch for ch in norm if unicodedata.category(ch) != "Cf")


class _Commands:
    """Where `install` / `uninstall` occur on one line."""

    def __init__(self, line: str):
        found = [(m.start(), m.group(1).lower()) for m in _CMD.finditer(line)]
        self._starts = [s for s, _ in found]
        self._words = [w for _, w in found]

    def nearest_before(self, pos: int) -> str | None:
        i = bisect.bisect_left(self._starts, pos)
        return self._words[i - 1] if i else None


def _former_names(label: str, n: int, line: str, cmds: _Commands) -> list[str]:
    found: list[str] = []
    for name in FORMER:
        for m in re.finditer(re.escape(name), line, re.I):
            before = line[m.start() - 1] if m.start() else ""
            after = line[m.end():]
            if before == "@":
                if cmds.nearest_before(m.start()) == "uninstall":
                    continue                                    # shape a
            elif _HISTORY.match(after):
                continue                                        # shape b
            elif before != "/" and not after.startswith("/") and not after.lower().startswith(".git"):
                continue                                        # shape c
            context = line[max(0, m.start() - 30):m.end() + 30].strip()
            found.append(f"{label}:{n} names the former marketplace {name!r} in a form "
                         f"other than prose, an issue link or an uninstall id: …{context}…")
    return found


def _install_ids(n: int, line: str, cmds: _Commands, plugin: str, mp: str) -> tuple[list[str], bool]:
    found: list[str] = []
    installs = False
    id_re = re.compile(r"(?<![A-Za-z0-9.@-])(?i:" + re.escape(plugin) + r")@([A-Za-z0-9._-]+)")
    for m in id_re.finditer(line):
        target = m.group(1).rstrip(".")
        nearest = cmds.nearest_before(m.start())
        if target == mp:
            installs = installs or nearest == "install"
        elif nearest != "uninstall":
            found.append(f"README.md:{n} names {plugin}@{target}, not {plugin}@{mp}")
    return found, installs


def _slug_text(raw: str) -> str:
    s = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", raw)      # images -> alt
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)          # links -> text
    s = re.sub(r"<[^>]+>", "", s)                            # HTML tags
    s = html.unescape(s)
    s = s.replace("`", "").replace("*", "")
    s = re.sub(r"(?<!\w)_+|_+(?!\w)", "", s)                # emphasis underscores
    s = s.strip().lower()
    kept = [ch for ch in s if unicodedata.category(ch)[0] in "LMN" or ch in " -_"]
    return "".join(kept).replace(" ", "-")


def _anchors(path: str) -> set[str]:
    """Anchors GitHub generates for the headings rule 5 counts."""
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
                in_comment = "-->" not in line
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


def _docs_urls(label: str, text: str, plugin: str, mp: str, readme: str) -> list[str]:
    urls = _DOCS_URL.findall(text)
    if text.count("docsUrl") != len(urls):
        return [f"{label} mentions docsUrl outside a \"docsUrl\":\"<url>\" member — not checked"]
    if not urls:
        return []
    repo = _GITHUB_REPO.search(text)
    if not repo:
        return [f"{label} has a docsUrl but no GITHUB_REPO=\"…\" line to check it against"]
    if repo.group(1).rsplit("/", 1)[-1] != mp:
        return [f"{label}: GITHUB_REPO={repo.group(1)!r} is not the {mp!r} repository"]
    prefix = f"https://github.com/{repo.group(1)}/blob/main/plugins/{plugin}/README.md#"
    found: list[str] = []
    for url in urls:
        if not url.startswith(prefix) or len(url) == len(prefix):
            found.append(f"{label}: docsUrl {url} is not {prefix}<anchor>")
            continue
        anchor = urllib.parse.unquote(url[len(prefix):])
        try:
            anchors = _anchors(readme)
        except (OSError, UnicodeDecodeError) as exc:
            found.append(f"{label}: docsUrl anchor unverified — README.md unreadable ({exc.__class__.__name__})")
            continue
        if anchor not in anchors:
            found.append(f"{label}: docsUrl anchor #{anchor} matches no heading of README.md")
    return found


def problems(plugin: str, plugin_dir: str, repo_root: str) -> list[str]:
    found: list[str] = []
    market = os.path.join(repo_root, ".claude-plugin", "marketplace.json")
    try:
        with open(market, encoding="utf-8") as fh:
            data = json.load(fh)
        mp = data["name"]
        listed = [e for e in data.get("plugins", []) if e.get("name") == plugin]
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        return [f"cannot read the marketplace name from .claude-plugin/marketplace.json ({exc.__class__.__name__}) — install references unverified"]
    if not isinstance(mp, str) or not mp:
        return ["marketplace.json has no usable name — install references unverified"]
    if not listed:
        found.append(f"marketplace {mp!r} does not list {plugin}")

    readme = os.path.join(plugin_dir, "README.md")
    try:
        with open(readme, encoding="utf-8") as fh:
            docs = [("README.md", fh.read())]
    except (OSError, UnicodeDecodeError) as exc:
        # Fail closed, but only this check: a README that is not UTF-8 must not
        # crash the shared parser and hide the other checks' results.
        return found + [f"README.md unreadable as UTF-8 ({exc.__class__.__name__}) — install references unverified"]
    bindir = os.path.join(plugin_dir, "bin")
    if os.path.isdir(bindir):
        for f in sorted(os.listdir(bindir)):
            p = os.path.join(bindir, f)
            if not f.startswith(".") and os.path.isfile(p):
                with open(p, encoding="utf-8", errors="replace") as fh:
                    docs.append((f"bin/{f}", fh.read()))

    add_re = re.compile(r"(?i:\bmarketplace\s+add)\s+(?:\S*/)?" + re.escape(mp) + r"(?:\.git)?(?=[\s`]|$)")
    has_install = has_add = False
    for label, text in docs:
        for n, raw in _joined_lines(text):
            line = _clean(raw)
            cmds = _Commands(line)
            found += _former_names(label, n, line, cmds)
            if label == "README.md":
                bad, installs = _install_ids(n, line, cmds, plugin, mp)
                found += bad
                has_install = has_install or installs
                has_add = has_add or bool(add_re.search(line))
    if not has_install:
        found.append(f"README.md never says `install {plugin}@{mp}`")
    if not has_add:
        found.append(f"README.md never says `marketplace add …/{mp}`")
    for label, text in docs[1:]:
        found += _docs_urls(label, text, plugin, mp, readme)
    return found
