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
import json
import os
import re
import stat
import subprocess
import sys
from typing import Callable, NamedTuple, Optional

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
UNSAFE = re.compile(r"[\x7f-\x9f\xad\u061c\u200b-\u200f\u2028-\u202e\u2060-\u2064\u2066-\u2069"
                    r"\ufeff\ufff9-\ufffb\U000e0000-\U000e007f]")
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
# Every directory is opened once, without following a symbolic link, and everything below
# it is reached relative to that descriptor (dir_fd), so a directory swapped for a link
# after it was found is never followed. Paths are kept only for the git check.

class ChatDir(NamedTuple):
    chat_id: int
    fd: int
    path: str   # absolute, below the archive's real path; what the git check sees


class DayRef(NamedTuple):
    chat_id: int
    dir_fd: int
    name: str   # <YYYY-MM-DD>.md, opened relative to dir_fd
    path: str   # absolute; what the git check sees
    rel: str    # <chat_id>/<YYYY-MM-DD>.md
    date: str


def open_archive(path: str) -> tuple[str, int]:
    """(real path, descriptor) of the archive directory."""
    if not os.path.isabs(path):
        raise Refusal("archive_missing", "--archive must be an absolute path")
    real = os.path.realpath(path)
    try:
        return real, os.open(real, DIR_FLAGS)
    except OSError:
        raise Refusal("archive_missing", f"{real} is not a directory; nothing has been archived there yet")


def still_bound(path: str, fd: int) -> bool:
    """Whether `path` still names, without a link, the directory open as `fd`."""
    try:
        st, now = os.stat(path, follow_symlinks=False), os.fstat(fd)
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode) and (st.st_dev, st.st_ino) == (now.st_dev, now.st_ino)


def chat_dirs(archive: str, archive_fd: int, wanted: set[int]) -> tuple[list[ChatDir], list[dict], list[int]]:
    """(chat directories to search, skipped, requested chat ids with no directory)."""
    try:
        names = sorted(os.listdir(archive_fd))
    except OSError as e:
        raise Refusal("archive_missing", f"{archive} cannot be listed ({errno.errorcode.get(e.errno, e.errno)})")
    found, skipped, seen = [], [], set()
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
        if stat.S_ISLNK(mode):
            skipped.append({"file": name, "reason": "symlinked-chat-directory"})
            continue
        if not stat.S_ISDIR(mode):
            continue
        try:
            found.append(ChatDir(chat_id, os.open(name, DIR_FLAGS, dir_fd=archive_fd), os.path.join(archive, name)))
        except OSError as e:
            reason = "changed-during-search" if e.errno in (errno.ENOTDIR, errno.ELOOP) else "unreadable"
            skipped.append({"file": name, "reason": reason})
    return found, skipped, sorted(c for c in wanted if c not in seen)


def day_files(chat: ChatDir, since: Optional[str] = None,
              until: Optional[str] = None) -> tuple[list[DayRef], list[dict]]:
    """(day files of one chat directory by name, skipped)."""
    try:
        names = sorted(os.listdir(chat.fd))
    except OSError:
        return [], [{"file": str(chat.chat_id), "reason": "unreadable"}]
    refs, skipped = [], []
    for name in names:
        m = DAY_FILE.fullmatch(name)
        if not m or (since and m.group(1) < since) or (until and m.group(1) > until):
            continue
        rel = f"{chat.chat_id}/{name}"
        try:
            regular = stat.S_ISREG(os.stat(name, dir_fd=chat.fd, follow_symlinks=False).st_mode)
        except OSError:
            skipped.append({"file": rel, "reason": "unreadable"})
            continue
        if regular:
            refs.append(DayRef(chat.chat_id, chat.fd, name, os.path.join(chat.path, name), rel, m.group(1)))
        else:
            skipped.append({"file": rel, "reason": "not-regular-file"})
    return refs, skipped


def discover(archive: str, archive_fd: int, wanted: set[int], since: Optional[str] = None,
             until: Optional[str] = None) -> tuple[list[ChatDir], list[DayRef], list[dict], list[int]]:
    """Chat directories and their day files, checked by git, with the ones that changed since dropped."""
    chats, skipped, missing = chat_dirs(archive, archive_fd, wanted)
    refs = []
    for chat in chats:
        found, more = day_files(chat, since, until)
        refs += found
        skipped += more
    guard(archive, refs)
    if not still_bound(archive, archive_fd):
        raise Refusal("archive_missing", f"{archive} changed during the search; nothing was read")
    moved = {c.chat_id for c in chats if not still_bound(c.path, c.fd)}
    skipped += [{"file": str(c), "reason": "changed-during-search"} for c in sorted(moved)]
    return chats, [r for r in refs if r.chat_id not in moved], skipped, missing


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

def read_day(ref: DayRef) -> tuple[Optional[str], str]:
    """(body text, utc_offset) of a day file, or (None, reason) when it is not searched."""
    try:
        fd = os.open(ref.name, FILE_FLAGS, dir_fd=ref.dir_fd)
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


def blocks(body: str) -> list[tuple[int, list[str]]]:
    """[(message id, block lines after the anchor)] in file order; a repeated id keeps its first block."""
    out, seen, current = [], set(), None
    for line in body.split("\n"):
        m = ANCHOR.fullmatch(line)
        mid = decimal(m.group(1)) if m else None
        if mid is not None:
            current = []
            if mid not in seen:
                seen.add(mid)
                out.append((mid, current))
        elif current is not None:
            current.append(line)
    return out


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
    writer's hasPrefix compares grapheme clusters, so <!-- plus a combining mark is not
    escaped). With no header there are no annotations and every line is text."""
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
    return text if text is None or len(text) <= limit else text[:limit] + ELLIPSIS


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
    """At most `width` characters of the text as shown (line breaks as LINE_MARK), around the
    first occurrence of `first_term` or from the start, with ELLIPSIS where it was cut. Only
    the part of the text around the hit is rendered, so a long message is not copied."""
    span = folded_span(text, folded, first_term) if first_term else None
    lo, hi = (max(0, span[0] - width), min(len(text), span[1] + width)) if span else (0, min(len(text), width + 1))
    shown = text[lo:hi].replace("\n", LINE_MARK)
    start = 0
    if span:
        widen = len(LINE_MARK) - 1
        s = span[0] - lo + widen * text.count("\n", lo, span[0])
        e = span[1] - lo + widen * text.count("\n", lo, span[1])
        start = s if e - s >= width else max(0, min(s - (width - (e - s)) // 2, len(shown) - width))
    end = min(start + width, len(shown))
    before, after = lo > 0 or start > 0, hi < len(text) or end < len(shown)
    return (ELLIPSIS if before else "") + shown[start:end] + (ELLIPSIS if after else "")


def record(ref: DayRef, offset: str, mid: int, parsed: tuple) -> dict:
    time, sender, _, notes, truncated = parsed
    return {"citation": f"telegram:{ref.chat_id}/{mid}", "chat_id": ref.chat_id, "message_id": mid,
            "date": ref.date, "time": time, "utc_offset": offset, "sender": cut(sender, SENDER_CAP),
            "file": ref.rel, "annotations": notes, "annotations_truncated": truncated}


def skipped_part(skipped: list[dict]) -> dict:
    return {"skipped": skipped[:SKIPPED_LISTED], "skipped_count": len(skipped)}


def close_all(archive_fd: int, chats: list[ChatDir]) -> None:
    for fd in [c.fd for c in chats] + [archive_fd]:
        try:
            os.close(fd)
        except OSError:
            pass


# ---------------------------------------------------------------- the two modes

def search(archive: str, archive_fd: int, args: argparse.Namespace) -> dict:
    chats, refs, skipped, missing = [], [], [], []
    try:
        chats, refs, skipped, missing = discover(archive, archive_fd, set(args.chat), args.since, args.until)
        terms = [t.casefold() for t in args.text]
        sender_term = args.sender.casefold() if args.sender else None
        hits, searched = [], 0
        for ref in refs:
            body, offset = read_day(ref)
            if body is None:
                skipped.append({"file": ref.rel, "reason": offset})
                continue
            searched += 1
            for mid, lines in blocks(body):
                parsed = message(lines)
                text, sender = parsed[2], parsed[1]
                folded = text.casefold()
                if all(t in folded for t in terms) and (sender_term is None or sender_term in (sender or "").casefold()):
                    hit = record(ref, offset, mid, parsed)
                    hit["snippet"] = snippet(text, folded, args.text[0] if args.text else None, args.snippet_chars)
                    hits.append(hit)
    finally:
        close_all(archive_fd, chats)
    hits.sort(key=lambda h: (h["date"], h["time"] or "", h["chat_id"], h["message_id"]), reverse=True)
    shown = hits[:args.max_results]
    return dict({"archive": archive, "searched_files": searched, "matched": len(hits), "shown": len(shown),
                 "truncated": len(hits) > len(shown), "results": shown, "missing_chats": missing},
                **skipped_part(skipped))


def cite(archive: str, archive_fd: int, args: argparse.Namespace) -> dict:
    wanted = list(dict.fromkeys(args.cite))
    chats, out = [], {}
    try:
        chats, refs, skipped, _ = discover(archive, archive_fd, {c for c, _ in wanted})
        pending = set(wanted)
        for ref in refs:
            if not any(c == ref.chat_id for c, _ in pending):
                continue
            body, offset = read_day(ref)
            if body is None:
                skipped.append({"file": ref.rel, "reason": offset})
                continue
            for mid, lines in blocks(body):
                if (ref.chat_id, mid) in pending:
                    parsed = message(lines)
                    text = parsed[2]
                    out[(ref.chat_id, mid)] = dict(record(ref, offset, mid, parsed),
                                                   text=text[:TEXT_CAP], text_truncated=len(text) > TEXT_CAP)
                    pending.discard((ref.chat_id, mid))
    finally:
        close_all(archive_fd, chats)
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
