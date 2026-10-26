"""Read-only search over the Telegram chat archive that /archive-telegram writes
(PsychQuant/che-msg#80; openspec capability telegram-archive-search).

Run as `python3 -I search_archive.py --archive=<absolute dir> ...` (see --help).
Reads only <archive>/<chat_id>/YYYY-MM-DD.md, writes nothing, starts no TDLib,
and prints one JSON object on standard output, errors included. Standard library
only; runs on Python 3.9 (the Command Line Tools' /usr/bin/python3).
"""
from __future__ import annotations

import argparse
import datetime
import errno
import heapq
import json
import os
import re
import stat
import subprocess
import sys
from typing import Callable, Iterator, NamedTuple, Optional

MAX_RESULTS_DEFAULT, MAX_RESULTS_LIMIT = 20, 100
SNIPPET_DEFAULT, SNIPPET_MIN, SNIPPET_MAX = 80, 20, 200
MAX_CITES = 10
MAX_TERMS, MAX_TERM_CHARS = 10, 200
TEXT_CAP, SENDER_CAP = 4000, 64
ANNOTATION_COUNT, ANNOTATION_CAP = 5, 48
SKIPPED_LISTED, REFUSED_LISTED = 20, 5
MAX_FILE_BYTES = 32 * 1024 * 1024
INT64_MIN, INT64_MAX = -(2 ** 63), 2 ** 63 - 1
LINE_MARK = " " + chr(0x23CE) + " "   # how a line break shows in a snippet
ELLIPSIS = chr(0x2026)

CHAT_ID = re.compile(r"0|-?[1-9][0-9]*")
DAY_FILE = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})\.md")
DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
ANCHOR = re.compile(r"<!-- msg:([0-9]+) -->")
HEADER = re.compile(r"\*\*([0-9]{2}:[0-9]{2}) (.*)\*\*\uff1a")
ESCAPED = re.compile(r"\\(?:<!--|\*\*[0-9]{1,2}:[0-9]{2})")
CITATION = re.compile(r"telegram:(0|-?[1-9][0-9]*)/([1-9][0-9]*)")
OFFSET = re.compile(r"[+-]([0-9]{2}):([0-9]{2})")
# json.dumps(ensure_ascii=False) leaves these raw. They are written as \uXXXX so that none
# reaches a terminal or hides in what the model reads: C1 controls and DEL, the soft hyphen,
# zero-width and joiner characters, bidi marks and controls, line/paragraph separators,
# invisible operators, the BOM, interlinear annotation controls and the tag characters.
# Also the variation selectors U+FE00-FE0E and U+E0100-E01EF and the fillers that render as
# nothing (U+034F, U+115F, U+1160, U+180E, U+3164, U+FFA0, U+FFFC). U+FE0F stays raw: it
# selects the emoji form after a symbol such as U+2764, and a run of it carries no more than
# its length.
UNSAFE = re.compile(r"[\x7f-\x9f\xad\u034f\u061c\u115f\u1160\u180e\u200b-\u200f\u2028-\u202e"
                    r"\u2060-\u2064\u2066-\u2069\u3164\ufe00-\ufe0e\ufeff\uffa0\ufff9-\ufffc"
                    r"\U000e0000-\U000e007f\U000e0100-\U000e01ef]")
# git sees only these, so no GIT_* variable from the caller (GIT_DIR, GIT_CEILING_DIRECTORIES,
# GIT_CONFIG_COUNT/KEY/VALUE, GIT_CONFIG_PARAMETERS, GIT_CONFIG_GLOBAL, ...) changes the answer:
# the repository's own rules plus the system and global config, as git reads them in a plain shell.
GIT_ENV_KEPT = ("PATH", "HOME", "XDG_CONFIG_HOME")
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
FILE_FLAGS = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
EXIT = {"usage": 2, "not_ignored": 3, "git_failed": 3, "archive_missing": 4, "internal": 1}


class Refusal(Exception):
    def __init__(self, kind: str, message: str, **extra: object) -> None:
        super().__init__(message)
        self.kind, self.message, self.extra = kind, message, extra


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        raise Refusal("usage", message)


# ---------------------------------------------------------------- arguments

def decimal(text: str) -> Optional[int]:
    """The Int64 value of a decimal string (leading zeros allowed, as Swift's Int64(_:) reads
    them), or None. int() never sees more than 19 significant digits: Python 3.11 and later
    refuse to convert a string of more than 4300 digits."""
    negative = text.startswith("-")
    digits = text[1:] if negative else text
    if not digits or not digits.isascii() or not digits.isdigit():
        return None
    significant = digits.lstrip("0") or "0"
    if len(significant) > 19:
        return None
    value = -int(significant) if negative else int(significant)
    return value if INT64_MIN <= value <= INT64_MAX else None


def bounded(lo: int, hi: int) -> Callable[[str], int]:
    def parse(text: str) -> int:
        value = decimal(text) if re.fullmatch(r"[0-9]+", text) else None
        if value is None or not lo <= value <= hi:
            raise argparse.ArgumentTypeError(f"must be an integer from {lo} to {hi}")
        return value
    return parse


def day(text: str) -> str:
    try:
        if DATE.fullmatch(text):
            return datetime.date.fromisoformat(text).isoformat()
    except ValueError:
        pass
    raise argparse.ArgumentTypeError("must be a date YYYY-MM-DD")


def term(text: str) -> str:
    if not text.strip() or len(text) > MAX_TERM_CHARS:
        raise argparse.ArgumentTypeError(f"must not be blank or longer than {MAX_TERM_CHARS} characters")
    return text


def int64(text: str) -> int:
    value = decimal(text) if CHAT_ID.fullmatch(text) else None
    if value is None:
        raise argparse.ArgumentTypeError("must be a decimal chat id without leading zeros")
    return value


def citation(text: str) -> tuple[int, int]:
    m = CITATION.fullmatch(text)
    chat, mid = (decimal(m.group(1)), decimal(m.group(2))) if m else (None, None)
    if chat is None or mid is None:
        raise argparse.ArgumentTypeError("must be telegram:<chat_id>/<message_id>, decimal, without leading zeros")
    return chat, mid


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = Parser(prog="search_archive.py", allow_abbrev=False,
               description="Search the /archive-telegram day files, or resolve citations. Output is one JSON object.")
    p.add_argument("--archive", required=True, help="absolute path of the archive directory (output_dir)")
    p.add_argument("--text", type=term, action="append", default=[], help="term that must occur (repeat: all must)")
    p.add_argument("--sender", type=term, help="substring of the sender as written")
    p.add_argument("--since", type=day, help="first day, YYYY-MM-DD, inclusive")
    p.add_argument("--until", type=day, help="last day, YYYY-MM-DD, inclusive")
    p.add_argument("--chat", type=int64, action="append", default=[], help="chat id (repeat for several)")
    p.add_argument("--max-results", type=bounded(1, MAX_RESULTS_LIMIT), default=MAX_RESULTS_DEFAULT)
    p.add_argument("--snippet-chars", type=bounded(SNIPPET_MIN, SNIPPET_MAX), default=SNIPPET_DEFAULT)
    p.add_argument("--cite", type=citation, action="append", default=[], help="telegram:<chat_id>/<message_id>")
    args = p.parse_args(argv)
    filters = args.text or args.sender or args.since or args.until or args.chat
    if args.cite and filters:
        raise Refusal("usage", "--cite does not combine with search filters")
    if not args.cite and not filters:
        raise Refusal("usage", "give at least one of --text, --sender, --since, --until, --chat, or --cite")
    if len(args.text) > MAX_TERMS or len(args.cite) > MAX_CITES:
        raise Refusal("usage", f"at most {MAX_TERMS} --text terms and {MAX_CITES} --cite citations per call")
    if args.since and args.until and args.since > args.until:
        raise Refusal("usage", "--since is after --until")
    return args


# ---------------------------------------------------------------- finding day files
# Every directory is opened without following a symbolic link, and everything below it is
# reached relative to that descriptor (dir_fd). Discovery opens each chat directory briefly,
# records its identity (device and inode) and its day files, and closes it. After the git
# check each chat is opened again, accepted only when it is the same directory and its path
# still names it, read and closed. So a directory swapped for a link or for another directory
# is never read, and only a few descriptors are open whatever the number of chats.

class DayRef(NamedTuple):
    chat_id: int
    name: str   # <YYYY-MM-DD>.md, opened relative to its chat directory
    path: str   # absolute; what the git check sees
    rel: str    # <chat_id>/<YYYY-MM-DD>.md
    date: str


class ChatDir(NamedTuple):
    chat_id: int
    name: str
    path: str                    # absolute, below the archive's real path
    identity: tuple[int, int]    # (st_dev, st_ino) when it was listed
    days: list[DayRef]


def identity(st: os.stat_result) -> tuple[int, int]:
    return st.st_dev, st.st_ino


def open_dir(name: str, dir_fd: Optional[int]) -> int:
    """A directory descriptor; `name` is relative to `dir_fd`, or absolute when it is None."""
    return os.open(name, DIR_FLAGS, dir_fd=dir_fd)


def open_archive(path: str) -> tuple[str, int]:
    """(real path, descriptor) of the archive directory."""
    if not os.path.isabs(path):
        raise Refusal("archive_missing", "--archive must be an absolute path")
    real = os.path.realpath(path)
    if not os.path.isdir(real):
        raise Refusal("archive_missing", f"{real} is not a directory; nothing has been archived there yet")
    try:
        return real, open_dir(real, None)
    except OSError as e:
        raise Refusal("archive_missing", f"{real} cannot be listed ({errno.errorcode.get(e.errno, e.errno)})")


def names_dir(path: str, ident: tuple[int, int]) -> bool:
    """Whether `path` names, without a link, the directory whose identity is `ident`."""
    try:
        st = os.stat(path, follow_symlinks=False)
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode) and identity(st) == ident


def list_days(chat_id: int, fd: int, path: str, since: Optional[str],
              until: Optional[str]) -> tuple[list[DayRef], list[dict]]:
    """(day files of one open chat directory by name, skipped)."""
    names = sorted(os.listdir(fd))
    days, skipped = [], []
    for name in names:
        m = DAY_FILE.fullmatch(name)
        if not m or (since and m.group(1) < since) or (until and m.group(1) > until):
            continue
        rel = f"{chat_id}/{name}"
        try:
            regular = stat.S_ISREG(os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode)
        except OSError:
            skipped.append({"file": rel, "reason": "unreadable"})
            continue
        if regular:
            days.append(DayRef(chat_id, name, os.path.join(path, name), rel, m.group(1)))
        else:
            skipped.append({"file": rel, "reason": "not-regular-file"})
    return days, skipped


def chat_dirs(archive: str, archive_fd: int, wanted: set[int], since: Optional[str],
              until: Optional[str]) -> tuple[list[ChatDir], list[dict], list[int]]:
    """(chat directories with their day files, skipped, requested chat ids with no entry)."""
    try:
        names = sorted(os.listdir(archive_fd))
    except OSError as e:
        raise Refusal("archive_missing", f"{archive} cannot be listed ({errno.errorcode.get(e.errno, e.errno)})")
    chats, skipped, seen = [], [], set()
    for name in names:
        chat_id = decimal(name) if CHAT_ID.fullmatch(name) else None
        if chat_id is None or (wanted and chat_id not in wanted):
            continue
        seen.add(chat_id)
        try:
            mode = os.stat(name, dir_fd=archive_fd, follow_symlinks=False).st_mode
        except OSError:
            skipped.append({"file": name, "reason": "unreadable"})
            continue
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            if stat.S_ISLNK(mode) or wanted:
                skipped.append({"file": name, "reason": "symlinked-chat-directory" if stat.S_ISLNK(mode) else "not-a-directory"})
            continue
        try:
            fd = open_dir(name, archive_fd)
        except OSError as e:
            reason = "changed-during-search" if e.errno in (errno.ENOTDIR, errno.ELOOP) else "unreadable"
            skipped.append({"file": name, "reason": reason})
            continue
        path = os.path.join(archive, name)
        try:
            ident = identity(os.fstat(fd))
            days, more = list_days(chat_id, fd, path, since, until)
        except OSError:
            skipped.append({"file": name, "reason": "unreadable"})
            continue
        finally:
            os.close(fd)
        skipped += more
        chats.append(ChatDir(chat_id, name, path, ident, days))
    return chats, skipped, sorted(c for c in wanted if c not in seen)


def discover(archive: str, archive_fd: int, wanted: set[int], since: Optional[str] = None,
             until: Optional[str] = None) -> tuple[list[ChatDir], list[dict], list[int]]:
    """Chat directories and their day files, all checked by git before any is read."""
    chats, skipped, missing = chat_dirs(archive, archive_fd, wanted, since, until)
    guard(archive, [d for c in chats for d in c.days])
    if not names_dir(archive, identity(os.fstat(archive_fd))):
        raise Refusal("archive_missing", f"{archive} changed during the search; nothing was read")
    return chats, skipped, missing


def reopen(archive_fd: int, chat: ChatDir) -> Optional[int]:
    """The chat directory again, when it is the one that was listed and its path still names it."""
    try:
        fd = open_dir(chat.name, archive_fd)
    except OSError:
        return None
    if identity(os.fstat(fd)) == chat.identity and names_dir(chat.path, chat.identity):
        return fd
    os.close(fd)
    return None


def each_day(archive_fd: int, chats: list[ChatDir], skipped: list[dict],
             wants: Callable[[int], bool] = lambda chat_id: True) -> Iterator[tuple[DayRef, str, str]]:
    """(day file, body, utc_offset) for every readable day file, one chat directory open at a time."""
    for chat in chats:
        if not chat.days or not wants(chat.chat_id):
            continue
        fd = reopen(archive_fd, chat)
        if fd is None:
            skipped.append({"file": str(chat.chat_id), "reason": "changed-during-search"})
            continue
        try:
            for ref in chat.days:
                if not wants(chat.chat_id):
                    break
                body, offset = read_day(ref, fd)
                if body is None:
                    skipped.append({"file": ref.rel, "reason": offset})
                    continue
                yield ref, body, offset
        finally:
            os.close(fd)


# ---------------------------------------------------------------- git-ignore guard

def run_git(args: list[str], stdin: Optional[bytes] = None) -> subprocess.CompletedProcess:
    env = {k: os.environ[k] for k in GIT_ENV_KEPT if k in os.environ}
    env["LC_ALL"] = "C"
    try:
        return subprocess.run(["git"] + args, input=stdin, capture_output=True, env=env, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Refusal("git_failed", f"git could not be run ({type(e).__name__}); the archive was not read")


def first_line(raw: bytes) -> str:
    return (raw.decode("utf-8", "replace").strip().splitlines() or [""])[0][:200]


def guard(archive: str, refs: list[DayRef]) -> None:
    """Refuses unless every day file in refs is ignored by git, or the archive is in no work tree."""
    if not refs:
        return
    top = run_git(["-C", archive, "rev-parse", "--show-toplevel"])
    if top.returncode != 0:
        if b"not a git repository" in top.stderr:
            return
        raise Refusal("git_failed", f"git failed: {first_line(top.stderr)}; the archive was not read")
    root = os.fsdecode(top.stdout.rstrip(b"\n"))
    answer = run_git(["-C", root, "check-ignore", "--stdin", "-z"],
                     stdin=b"".join(os.fsencode(r.path) + b"\0" for r in refs))
    if answer.returncode not in (0, 1):
        raise Refusal("git_failed", f"git check-ignore failed: {first_line(answer.stderr)}; the archive was not read")
    ignored = {os.fsdecode(p) for p in answer.stdout.split(b"\0") if p}
    exposed = [r.rel for r in refs if r.path not in ignored]
    if exposed:
        raise Refusal("not_ignored", f"{len(exposed)} day file(s) are in the git repository at {root} and not "
                      "ignored (or already committed); add output_dir to that repository's .gitignore. "
                      "Nothing was read.", files=exposed[:REFUSED_LISTED], count=len(exposed))


# ---------------------------------------------------------------- reading a day file

def read_day(ref: DayRef, dir_fd: int) -> tuple[Optional[str], str]:
    """(body text, utc_offset) of a day file, or (None, reason) when it is not searched."""
    try:
        fd = os.open(ref.name, FILE_FLAGS, dir_fd=dir_fd)
    except OSError as e:
        return None, "not-regular-file" if e.errno in (errno.ELOOP, errno.ENXIO) else "unreadable"
    with os.fdopen(fd, "rb") as fh:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None, "not-regular-file"
        data = fh.read(MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        return None, "too-large"
    if b"\r" in data:
        return None, "carriage-return"
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None, "not-utf8"
    return frontmatter(text, ref)


def frontmatter(text: str, ref: DayRef) -> tuple[Optional[str], str]:
    """(body, utc_offset) after the frontmatter, or (None, reason) when it does not belong here."""
    end = text.find("\n---\n", 3)
    if not text.startswith("---\n") or end < 0:
        return None, "bad-frontmatter"
    fields = {}
    for line in text[4:end].split("\n"):
        key, sep, value = line.partition(": ")
        if sep and key not in fields:
            fields[key] = value.strip('" ')
    chat, date, offset = fields.get("chat_id", ""), fields.get("date", ""), fields.get("utc_offset", "")
    chat_id = decimal(chat) if CHAT_ID.fullmatch(chat) else None
    m = OFFSET.fullmatch(offset)
    if chat_id is None or not date or not m or int(m.group(2)) > 59 \
            or int(m.group(1)) * 60 + int(m.group(2)) > 18 * 60:
        return None, "bad-frontmatter"
    if chat_id != ref.chat_id:
        return None, "chat-id-mismatch"
    if date != ref.date:
        return None, "date-mismatch"
    body = text[end + 5:]
    return (body[1:] if body.startswith("\n") else body), offset


def blocks(body: str) -> Iterator[tuple[int, list[str]]]:
    """(message id, block lines after the anchor) in file order; a repeated id keeps its first block."""
    seen, mid, current = set(), 0, None
    for line in body.split("\n"):
        m = ANCHOR.fullmatch(line)
        new = decimal(m.group(1)) if m else None
        if new is None:
            if current is not None:
                current.append(line)
            continue
        if current is not None:
            yield mid, current
        mid, current = (new, []) if new not in seen else (0, None)
        seen.add(new)
    if current is not None:
        yield mid, current


def annotations(lines: list[str]) -> tuple[list[str], bool]:
    """At most ANNOTATION_COUNT annotations of at most ANNOTATION_CAP characters, and whether any was cut."""
    out, truncated = [], len(lines) > ANNOTATION_COUNT
    for line in lines[:ANNOTATION_COUNT]:
        inner = (line[4:-3] if line.endswith("-->") else line[4:]).strip()
        out.append(cut(inner, ANNOTATION_CAP))
        truncated = truncated or len(inner) > ANNOTATION_CAP
    return out, truncated


def message(lines: list[str]) -> tuple[Optional[str], Optional[str], str, list[str], bool]:
    """(time, sender, text, annotations, annotations cut) of one block.

    Annotations are the lines beginning with <!-- between the anchor and the header (where
    #72's marker sits) and nowhere else: a body line can begin with <!-- unescaped (the
    writer's hasPrefix compared grapheme clusters before a13427c, so <!-- plus a combining
    mark was not escaped). With no header there are no annotations and every line is text."""
    k = 0
    while k < len(lines) and lines[k].startswith("<!--"):
        k += 1
    m = HEADER.fullmatch(lines[k]) if k < len(lines) else None
    time = sender = None
    notes, rest = [], lines
    if m:
        time, sender, notes, rest = m.group(1), m.group(2), lines[:k], lines[k + 1:]
    rest = list(rest)
    while rest and rest[-1] == "":
        rest.pop()
    found, truncated = annotations(notes)
    return time, sender, "\n".join(l[1:] if ESCAPED.match(l) else l for l in rest), found, truncated


# ---------------------------------------------------------------- output pieces

def cut(text: Optional[str], limit: int) -> Optional[str]:
    """`text` in at most `limit` characters, ELLIPSIS included."""
    return text if text is None or len(text) <= limit else text[:limit - 1] + ELLIPSIS


def original_index(text: str, folded_pos: int) -> int:
    """Index in `text` of the character whose case fold covers position `folded_pos` of
    text.casefold(). Folds chunk by chunk (folding is per character), so no per-character
    list is built for a long message."""
    chunk, i, seen = 65536, 0, 0
    while i < len(text):
        piece = len(text[i:i + chunk].casefold())
        if seen + piece > folded_pos:
            break
        seen += piece
        i += chunk
    for j in range(i, min(i + chunk, len(text))):
        seen += len(text[j].casefold())
        if seen > folded_pos:
            return j
    return len(text)


def folded_span(text: str, folded: str, needle: str) -> Optional[tuple[int, int]]:
    """(start, end) in `text` of the first case-folded occurrence of `needle`, or None."""
    n = needle.casefold()
    k = folded.find(n)
    if k < 0 or not n:
        return None
    if len(folded) == len(text):   # no character folds to more than one: positions agree
        return k, k + len(n)
    return original_index(text, k), original_index(text, k + len(n) - 1) + 1


def snippet(text: str, folded: str, first_term: Optional[str], width: int) -> str:
    """At most `width` characters of the text as shown (line breaks as LINE_MARK), ELLIPSIS
    included, around the first occurrence of `first_term` or from the start. Positions are in
    the rendering; only the part of the text around the hit is rendered."""
    widen = len(LINE_MARK) - 1
    total = len(text) + widen * text.count("\n")
    if total <= width:
        return text.replace("\n", LINE_MARK)
    span = folded_span(text, folded, first_term) if first_term else None
    if span is None:
        lo, hi, start, w = 0, min(len(text), width + 1), 0, width - 1
    else:
        s = span[0] + widen * text.count("\n", 0, span[0])
        e = span[1] + widen * text.count("\n", 0, span[1])
        w = width - 2   # room for an ellipsis on each side
        start = s if e - s >= w else max(0, min(s - (w - (e - s)) // 2, total - w))
        if start == 0:
            w = width - 1
        elif start + w >= total:
            w = width - 1
            start = total - w
        lo, hi = max(0, span[0] - width), min(len(text), span[1] + width + 1)
    offset = lo + widen * text.count("\n", 0, lo)
    shown = text[lo:hi].replace("\n", LINE_MARK)[start - offset:start - offset + w]
    return (ELLIPSIS if start > 0 else "") + shown + (ELLIPSIS if start + w < total else "")


def record(ref: DayRef, offset: str, mid: int, parsed: tuple) -> dict:
    time, sender, _, notes, truncated = parsed
    return {"citation": f"telegram:{ref.chat_id}/{mid}", "chat_id": ref.chat_id, "message_id": mid,
            "date": ref.date, "time": time, "utc_offset": offset, "sender": cut(sender, SENDER_CAP),
            "file": ref.rel, "annotations": notes, "annotations_truncated": truncated}


def skipped_part(skipped: list[dict]) -> dict:
    return {"skipped": skipped[:SKIPPED_LISTED], "skipped_count": len(skipped)}


# ---------------------------------------------------------------- the two modes

def search(archive: str, archive_fd: int, args: argparse.Namespace) -> dict:
    """Only the `max_results` newest matches are kept (a heap), however many match."""
    try:
        chats, skipped, missing = discover(archive, archive_fd, set(args.chat), args.since, args.until)
        terms = [t.casefold() for t in args.text]
        sender_term = args.sender.casefold() if args.sender else None
        kept, matched, searched, order = [], 0, 0, 0
        for ref, body, offset in each_day(archive_fd, chats, skipped):
            searched += 1
            for mid, lines in blocks(body):
                parsed = message(lines)
                text, sender = parsed[2], parsed[1]
                folded = text.casefold()
                if not all(t in folded for t in terms) or (sender_term is not None
                                                            and sender_term not in (sender or "").casefold()):
                    continue
                matched += 1
                key = (ref.date, parsed[0] or "", ref.chat_id, mid)
                if len(kept) >= args.max_results and key <= kept[0][0]:
                    continue
                hit = record(ref, offset, mid, parsed)
                hit["snippet"] = snippet(text, folded, args.text[0] if args.text else None, args.snippet_chars)
                item, order = (key, order, hit), order + 1
                if len(kept) < args.max_results:
                    heapq.heappush(kept, item)
                else:
                    heapq.heapreplace(kept, item)
    finally:
        os.close(archive_fd)
    shown = [hit for _, _, hit in sorted(kept, reverse=True)]
    return dict({"archive": archive, "searched_files": searched, "matched": matched, "shown": len(shown),
                 "truncated": matched > len(shown), "results": shown, "missing_chats": missing},
                **skipped_part(skipped))


def cite(archive: str, archive_fd: int, args: argparse.Namespace) -> dict:
    wanted = list(dict.fromkeys(args.cite))
    out = {}
    try:
        chats, skipped, _ = discover(archive, archive_fd, {c for c, _ in wanted})
        pending = set(wanted)
        days = each_day(archive_fd, chats, skipped, lambda chat_id: any(c == chat_id for c, _ in pending))
        try:
            for ref, body, offset in days:
                for mid, lines in blocks(body):
                    if (ref.chat_id, mid) in pending:
                        parsed = message(lines)
                        text = parsed[2]
                        out[(ref.chat_id, mid)] = dict(record(ref, offset, mid, parsed),
                                                       text=text[:TEXT_CAP], text_truncated=len(text) > TEXT_CAP)
                        pending.discard((ref.chat_id, mid))
        finally:
            days.close()
    finally:
        os.close(archive_fd)
    return dict({"archive": archive, "blocks": [out[k] for k in wanted if k in out],
                 "not_found": [f"telegram:{c}/{m}" for c, m in wanted if (c, m) not in out]},
                **skipped_part(skipped))


def json_escape(m: re.Match) -> str:
    code = ord(m.group())
    if code > 0xFFFF:   # JSON writes a character outside the BMP as a UTF-16 surrogate pair
        code -= 0x10000
        return "\\u%04x\\u%04x" % (0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF))
    return "\\u%04x" % code


def emit(obj: dict) -> None:
    text = UNSAFE.sub(json_escape, json.dumps(obj, ensure_ascii=False))
    sys.stdout.buffer.write(text.encode("utf-8", "backslashreplace") + b"\n")
    sys.stdout.flush()


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        archive, archive_fd = open_archive(args.archive)
        emit(cite(archive, archive_fd, args) if args.cite else search(archive, archive_fd, args))
        return 0
    except Refusal as r:
        emit({"error": dict({"type": r.kind, "message": r.message}, **r.extra)})
        return EXIT[r.kind]
    except Exception as e:  # report, never a traceback that could carry file text
        emit({"error": {"type": "internal", "message": f"{type(e).__name__} while searching the archive"}})
        return EXIT["internal"]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
