r"""What a plugin's docs tell users to type must name the marketplace it ships in.

The plugin layout tests call problems() as their check (j). Background: when
che-telegram-mcp and che-archive-lines moved from psychquant-claude-plugins to
the che-msg marketplace (PsychQuant/che-msg#42), five places still named the old
home — two README install commands, two `marketplace add` commands, a "Plugin
source" link and the telegram-all wrapper's docsUrl. `claude plugin validate`
checks none of them, and a stale one keeps working for exactly as long as the
old marketplace still lists the plugin.

What it guards against: references to the old marketplace left behind by
mistake — a stale install line, a link nobody updated, a GITHUB_REPO copied
from the old wrapper. It does not guard against deliberate evasion: anyone who
can edit these files can edit this test. Spellings that only someone trying to
slip past the check would write are listed under "Not checked".

Why the rules are this narrow. Rounds 1-4 of the #42 verify tested an earlier
version that parsed every GitHub URL and every `marketplace add` argument in the
docs. Each round found a new kind of text it read wrongly — a full stop, a query
string, a table cell, full-width punctuation, raw.githubusercontent.com, a second
command on one line — and most of them let a link to the old repository through.
These rules parse no URLs. The old marketplace is found by its name, wherever it
is and whatever surrounds it, and the few shapes in which the name may appear
are listed. Do not widen a rule back into "every URL" or "every argument"
without reading that history.

Files read. "Plugin files" are every file under plugin_dir, recursively and
dotfiles included, except the README.md and CHANGELOG.md at its top (a
CHANGELOG.md deeper down is read). A file is read only if it is a regular file
(a symlink to a file is followed) of at most MAX_BYTES; any other file, a
symlink to a directory and a directory that cannot be listed are reported as
not checked, so the check fails closed. The plugin README must be UTF-8, since
rules 3 and 4 read it; other files are decoded with replacement characters,
which keeps the ASCII names in FORMER findable in any ASCII-compatible
encoding.

Lines end at LF, CR or CRLF and nowhere else. A line ending in a backslash is
joined with the next one, and a problem is reported at the line where the
joined line starts. Before rules 2-4 look at a line it is NFKC-normalised
(full-width `／` becomes `/`) and invisible format characters (Unicode category
Cf, such as U+200B) are removed.

problems(plugin, plugin_dir, repo_root, docs_url_required=False) returns one
string per problem. These five rules are the whole check; nothing else is
checked:

  1. repo_root/.claude-plugin/marketplace.json exists, parses, has a non-empty
     `name` (M below) and lists `plugin`.
  2. Former names. In the plugin README, in every plugin file, in
     repo_root/README.md and in repo_root/.claude-plugin/marketplace.json
     (where a plugin's `source` could point back), each occurrence of a name in FORMER, matched without
     regard to letter case, must have one of these three shapes. The list is
     closed: an occurrence that fits none of them is reported, however
     harmless it looks.
       a. it directly follows `@` (an install id) and the nearest `install` or
          `uninstall` before it on the line is `uninstall` — the migration
          steps name the old install id on purpose;
       b. it is directly followed by `/issues/<digits>` or `/pull/<digits>`,
          and the character after the digits is not a letter, digit, `_` or
          `/` — a link to an issue or pull request of the old repository,
          which is history. The `Owner/repo#N` shorthand is not accepted: it
          cannot be told apart from a link to the old front page with a
          numeric anchor, so it is reported and should be written as a link;
       c. the character before it is not `/` or `@`, and what follows it does
          not start with `/` or `.git` — the name as a word, in prose, a
          heading or an anchor. It is also what a former name given bare as
          a command argument looks like (`marketplace remove
          psychquant-claude-plugins`), so that passes too.
     So `<owner>/<former>` (a `marketplace add` argument, a clone URL, a
     GITHUB_REPO value, a link to the repository) and `<former>/<anything
     else>` (a link into the old repository on any host: blob, tree, raw,
     edit, blame, …) are reported. FORMER is global: an install id of ANY
     plugin from a former marketplace is reported unless it follows
     `uninstall`; name such a plugin in prose instead.
  3. Plugin README install ids: every `<plugin>@X` — the plugin name matched
     without regard to case and not directly after an ASCII letter or digit,
     `.`, `-` or `@` — has X == M, unless the nearest `install`/`uninstall`
     before it on the line is `uninstall`. At least one `<plugin>@M` has
     `install` as its nearest such word. A `.` ending X is a full stop.
  4. The plugin README has a line where `marketplace add` is followed by any
     options and then by an argument. `--scope` and `-s` always take the next
     token as their value (so `--scope <repo>` leaves no argument); any other
     token starting with `-` is an option on its own. The argument must end
     in `<c>/M`, optionally with `.git`, where <c> is any character but `/`,
     and be followed by whitespace, a backtick or the end of the line.
  5. docsUrl, in plugin files only (the README and CHANGELOG describe it in
     prose). Every JSON member `"docsUrl":"<url>"` (whitespace allowed around
     the colon) in a plugin file must have a <url> that is
     exactly https://github.com/<R>/blob/main/plugins/<plugin>/README.md#<a>
     where <R> is the same file's GITHUB_REPO="…" value (the repository the
     wrapper downloads its binary from) and the last segment of <R> is M.
     In bin/, every occurrence of the word `docsUrl` must be such a member
     (elsewhere a skill may mention it in prose). With docs_url_required, a
     file in bin/ must have one, so the rule cannot silently check nothing. <a>, percent-decoded, must be the anchor
     GitHub gives one of the headings of the plugin's README.md. Headings
     counted: ATX headings (`#`-`######` after at most three spaces, then a
     space, a tab or the end of the line) of at most HEADING_MAX characters, outside fenced code blocks and outside HTML
     comments that start a line. A fence closes only with the same character,
     at least as many, and nothing after it; a backtick opener whose info
     string has a backtick is not a fence. Headings inside block quotes, and
     longer lines, are NOT counted — this can only make the check fail, never
     pass. The anchor of a heading: links and images reduced to their text,
     HTML tags removed, entities decoded, `` ` ``, `*` and emphasis `_`
     dropped, lowercased, only letters, marks, digits, spaces, `-` and `_`
     kept, spaces turned into `-`; a repeated slug gets -1, -2, …, skipping
     slugs already in use.

Not checked, by design (listed so that nobody reads them as passes):
  - repository files outside plugin_dir other than its README.md (CLAUDE.md,
    tests/, openspec/, other plugins);
  - spellings written to evade the check: a file in an encoding that is not
    ASCII-compatible (UTF-16, UTF-32), a former name percent-encoded or split
    across a backslash continuation, dot segments after an issue number
    (`/issues/1./../..`);
  - prose: shape 2c cannot tell a mention of a former marketplace from a
    sentence telling users to use it ("pick psychquant-claude-plugins in
    /plugin"); that is for a human reviewer;
  - a separator written another way before or after a former name (`\`,
    `%2F`, an HTML entity);
  - links into this repository other than docsUrl values — their paths, `..`,
    whether the file exists;
  - the owner part of a docsUrl, GITHUB_REPO or `marketplace add` argument,
    and a `marketplace add` naming a third marketplace that is neither M nor
    in FORMER;
  - anchors anywhere except docsUrl values; setext headings; a `#` line
    inside a raw HTML block (`<div>` … `</div>`) is counted as a heading
    although GitHub gives it no anchor;
  - whether the `main` branch named in a docsUrl exists on the remote;
  - install ids with whitespace around `@`;
  - the plugin's top-level CHANGELOG.md: its references to the old
    repository are history;
  - total work: MAX_BYTES bounds each file, not their number.

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
MAX_BYTES = 2 * 1024 * 1024
HEADING_MAX = 1000

_CMD = re.compile(r"(?<![A-Za-z])(uninstall|install)(?![A-Za-z])", re.I)
_HISTORY = re.compile(r"/(?:issues|pull)/\d+(?![\w/])", re.I)
_DOCS_URL = re.compile(r'"docsUrl"\s*:\s*"([^"]*)"')
_GITHUB_REPO = re.compile(r'^GITHUB_REPO="([^"]+)"', re.M)
_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")


def _read(path: str) -> tuple[bytes | None, str | None]:
    """Contents of a regular file of at most MAX_BYTES, or (None, why not)."""
    if not os.path.isfile(path):
        return None, "is not a regular file"
    try:
        with open(path, "rb") as fh:
            data = fh.read(MAX_BYTES + 1)
    except OSError as exc:
        return None, f"is unreadable ({exc.__class__.__name__})"
    if len(data) > MAX_BYTES:
        return None, f"is larger than {MAX_BYTES} bytes"
    return data, None


def _plugin_files(plugin_dir: str) -> tuple[list[tuple[str, str]], list[str]]:
    """(label, path) of every file under plugin_dir but its top README and
    CHANGELOG, and a problem for every directory that is not walked."""
    out: list[tuple[str, str]] = []
    bad: list[str] = []

    def rel(path: str) -> str:
        return os.path.relpath(path, plugin_dir).replace(os.sep, "/")

    def unlisted(exc: OSError) -> None:
        bad.append(f"{rel(exc.filename or plugin_dir)} cannot be listed ({exc.__class__.__name__}) — not checked")

    for root, dirs, files in os.walk(plugin_dir, onerror=unlisted):
        for d in sorted(dirs):
            if os.path.islink(os.path.join(root, d)):
                bad.append(f"{rel(os.path.join(root, d))} is a symlink to a directory — not checked")
        dirs[:] = sorted(d for d in dirs if not os.path.islink(os.path.join(root, d)))
        for f in sorted(files):
            path = os.path.join(root, f)
            if rel(path) not in ("README.md", "CHANGELOG.md"):
                out.append((rel(path), path))
    return out, bad


def _joined_lines(text: str) -> list[tuple[int, str]]:
    """Backslash-continued lines joined; each keeps the number of its first line."""
    out: list[tuple[int, str]] = []
    buf, start = None, 0
    for n, line in enumerate(text.replace("\r\n", "\n").replace("\r", "\n").split("\n"), 1):
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
            s, e = m.start(), m.end()
            before = line[s - 1] if s else ""
            if before == "@":
                if cmds.nearest_before(s) == "uninstall":
                    continue                                    # shape a
            elif _HISTORY.match(line, e):
                continue                                        # shape b
            elif before != "/" and not line.startswith("/", e) and line[e:e + 4].lower() != ".git":
                continue                                        # shape c
            context = line[max(0, s - 30):e + 30].strip()
            found.append(f"{label}:{n} names the former marketplace {name!r} in a form other than "
                         f"prose, an /issues/<n> or /pull/<n> link, or an uninstall id: …{context}…")
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


def _heading_text(line: str) -> str | None:
    """Text of an ATX heading, or None. Linear in the line, unlike a regex."""
    indent = len(line) - len(line.lstrip(" "))
    if indent > 3:
        return None
    rest = line[indent:]
    level = len(rest) - len(rest.lstrip("#"))
    if not 1 <= level <= 6 or (len(rest) > level and rest[level] not in " \t"):
        return None
    text = rest[level:].strip(" \t")
    closing = text.rstrip("#")
    if not closing:
        return ""
    if len(closing) < len(text) and closing[-1] in " \t":
        return closing.rstrip(" \t")
    return text


def _slug_text(raw: str) -> str:
    # Each pattern stops at the next bracket or paren it cannot match, which
    # keeps it linear on runs such as `[[[[` (round 6 of #42 measured the
    # earlier patterns at 8 ms per 1000-character line).
    s = re.sub(r"!\[([^\[\]]*)\]\([^()]*\)", r"\1", raw)  # images -> alt
    s = re.sub(r"\[([^\[\]]*)\]\([^()]*\)", r"\1", s)     # links -> text
    s = re.sub(r"<[^<>]+>", "", s)                            # HTML tags
    s = html.unescape(s)
    s = s.replace("`", "").replace("*", "")

    def emphasis(m: re.Match) -> str:                         # `_` not inside a word
        a = s[m.start() - 1] if m.start() else ""
        b = s[m.end()] if m.end() < len(s) else ""
        return m.group() if (a.isalnum() and b.isalnum()) else ""

    s = re.sub(r"_+", emphasis, s)
    s = s.strip().lower()
    kept = [ch for ch in s if unicodedata.category(ch)[0] in "LMN" or ch in " -_"]
    return "".join(kept).replace(" ", "-")


def _anchors(readme_text: str) -> set[str]:
    """Anchors GitHub generates for the headings rule 5 counts."""
    used: dict[str, int] = {}
    fence: tuple[str, int] | None = None
    in_comment = False
    for line in readme_text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
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
        if len(line) > HEADING_MAX:
            continue                    # not counted (fails closed)
        text = _heading_text(line)
        if text is None:
            continue
        # github-slugger: the first use of a slug is bare; later ones get
        # -1, -2, … and skip any slug that is already taken.
        base = result = _slug_text(text)
        while result in used:
            used[base] += 1
            result = f"{base}-{used[base]}"
        used[result] = 0
    return set(used)


def _docs_urls(label: str, text: str, plugin: str, mp: str, anchors: set[str]) -> list[str]:
    urls = _DOCS_URL.findall(text)
    if label.startswith("bin/") and text.count("docsUrl") != len(urls):
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
        elif urllib.parse.unquote(url[len(prefix):]) not in anchors:
            found.append(f"{label}: docsUrl anchor #{url[len(prefix):]} matches no heading of README.md")
    return found


def _marketplace(repo_root: str, plugin: str) -> tuple[str | None, str, list[str]]:
    """(M, the file's text, problems); M is None when rules 2-5 cannot run."""
    data, why = _read(os.path.join(repo_root, ".claude-plugin", "marketplace.json"))
    if data is None:
        return None, "", [f".claude-plugin/marketplace.json {why} — install references unverified"]
    try:
        text = data.decode("utf-8")
        parsed = json.loads(text)
        mp = parsed["name"]
        listed = [e for e in parsed.get("plugins", []) if e.get("name") == plugin]
    except (ValueError, KeyError, TypeError, AttributeError, RecursionError) as exc:
        return None, "", [f"cannot read the marketplace name from .claude-plugin/marketplace.json ({exc.__class__.__name__}) — install references unverified"]
    if not isinstance(mp, str) or not mp:
        return None, "", ["marketplace.json has no usable name — install references unverified"]
    return mp, text, [] if listed else [f"marketplace {mp!r} does not list {plugin}"]


def problems(plugin: str, plugin_dir: str, repo_root: str, docs_url_required: bool = False) -> list[str]:
    mp, market_text, found = _marketplace(repo_root, plugin)
    if mp is None:
        return found

    data, why = _read(os.path.join(plugin_dir, "README.md"))
    try:
        readme = data.decode("utf-8") if data is not None else None
    except UnicodeDecodeError:
        readme, why = None, "is not UTF-8"
    if readme is None:
        # Fail closed, but only this check: an unreadable README must not
        # crash the shared parser and hide the other checks' results.
        return found + [f"README.md {why} — install references unverified"]

    docs = [("README.md", readme)]
    plugin_texts: list[tuple[str, str]] = []
    files, unwalked = _plugin_files(plugin_dir)
    found += unwalked
    for label, path in files:
        data, why = _read(path)
        if data is None:
            found.append(f"{label} {why} — not checked")
        else:
            plugin_texts.append((label, data.decode("utf-8", errors="replace")))
    docs += plugin_texts
    data, why = _read(os.path.join(repo_root, "README.md"))
    if data is None:
        found.append(f"the repository's README.md {why} — not checked")
    else:
        docs.append(("repository README.md", data.decode("utf-8", errors="replace")))
    docs.append((".claude-plugin/marketplace.json", market_text))

    # `--scope`/`-s` always take a value; the generic option branch excludes
    # them, so the regex cannot backtrack into reading a value as the argument.
    add_re = re.compile(r"(?i:\bmarketplace\s+add)"
                        r"(?:\s+(?:--scope|-s)\s+\S+|\s+-(?!-scope(?!\S)|s(?!\S))\S+)*"
                        r"\s+\S*[^\s/]/" + re.escape(mp) + r"(?:\.git)?(?=[\s`]|$)")
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

    anchors = _anchors(readme)
    for label, text in plugin_texts:
        found += _docs_urls(label, text, plugin, mp, anchors)
    if docs_url_required and not any(_DOCS_URL.search(t) for l, t in plugin_texts if l.startswith("bin/")):
        found.append("no file in bin/ has a docsUrl, so rule 5 cannot check the wrapper's")
    return found
