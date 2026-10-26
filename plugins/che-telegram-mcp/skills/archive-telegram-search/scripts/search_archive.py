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
TEXT_CAP, SENDER_CAP, ANNOTATION_CAP = 4000, 64, 80
SKIPPED_LISTED, REFUSED_LISTED = 20, 5
MAX_FILE_BYTES = 32 * 1024 * 1024
INT64_MIN, INT64_MAX = -(2 ** 63), 2 ** 63 - 1

CHAT_ID = re.compile(r"0|-?[1-9][0-9]*")
DAY_FILE = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})\.md")
DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
ANCHOR = re.compile(r"<!-- msg:([0-9]+) -->")
HEADER = re.compile(r"\*\*([0-9]{2}:[0-9]{2}) (.*)\*\*：")
ESCAPED = re.compile(r"\\(?:<!--|\*\*[0-9]{1,2}:[0-9]{2})")
CITATION = re.compile(r"telegram:(0|-?[1-9][0-9]*)/([1-9][0-9]*)")
OFFSET = re.compile(r"[+-]([0-9]{2}):([0-9]{2})")
# json.dumps(ensure_ascii=False) leaves these raw; they are written as \uXXXX so that
# none reaches a terminal (C1 controls, DEL, line/paragraph separators, bidi controls).
UNSAFE = re.compile("[\x7f-\x9f\u061c\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]")
# Environment variables that make git look at another repository than the archive's.
REPO_SELECTING = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                  "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX")
EXIT = {"usage": 2, "not_ignored": 3, "git_failed": 3, "archive_missing": 4, "internal": 1}


class Refusal(Exception):
    def __init__(self, kind: str, message: str, **extra: object) -> None:
        super().__init__(message)
        self.kind, self.message, self.extra = kind, message, extra


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        raise Refusal("usage", message)


# ---------------------------------------------------------------- arguments

def bounded(lo: int, hi: int) -> Callable[[str], int]:
    def parse(text: str) -> int:
        if not re.fullmatch(r"[0-9]+", text) or not lo <= int(text) <= hi:
            raise argparse.ArgumentTypeError(f"must be an integer from {lo} to {hi}")
        return int(text)
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
    if not CHAT_ID.fullmatch(text) or not INT64_MIN <= int(text) <= INT64_MAX:
        raise argparse.ArgumentTypeError("must be a decimal chat id without leading zeros")
    return int(text)


def citation(text: str) -> tuple[int, int]:
    m = CITATION.fullmatch(text)
    if not m or not INT64_MIN <= int(m.group(1)) <= INT64_MAX or int(m.group(2)) > INT64_MAX:
        raise argparse.ArgumentTypeError("must be telegram:<chat_id>/<message_id>, decimal, without leading zeros")
    return int(m.group(1)), int(m.group(2))


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


def resolve_archive(path: str) -> str:
    if not os.path.isabs(path):
        raise Refusal("archive_missing", "--archive must be an absolute path")
    real = os.path.realpath(path)
    if not os.path.isdir(real):
        raise Refusal("archive_missing", f"{real} is not a directory; nothing has been archived there yet")
    return real


# ---------------------------------------------------------------- finding day files

class DayRef(NamedTuple):
    chat_id: int
    path: str   # absolute, below the archive's real path
    rel: str    # <chat_id>/<YYYY-MM-DD>.md
    date: str


def chat_dirs(archive: str, wanted: set[int]) -> tuple[list[tuple[int, str]], list[dict], list[int]]:
    """([(chat_id, path)], skipped, missing chat ids) for the chat directories to search."""
    try:
        names = sorted(os.listdir(archive))
    except OSError as e:
        raise Refusal("archive_missing", f"{archive} cannot be listed ({errno.errorcode.get(e.errno, e.errno)})")
    found, skipped, seen = [], [], set()
    for name in names:
        if not CHAT_ID.fullmatch(name) or (wanted and int(name) not in wanted):
            continue
        st = os.lstat(os.path.join(archive, name))
        seen.add(int(name))
        if stat.S_ISLNK(st.st_mode):
            skipped.append({"file": name, "reason": "symlinked-chat-directory"})
        elif stat.S_ISDIR(st.st_mode):
            found.append((int(name), os.path.join(archive, name)))
    return found, skipped, sorted(c for c in wanted if c not in seen)


def day_files(chat_id: int, path: str, since: Optional[str] = None,
              until: Optional[str] = None) -> tuple[list[DayRef], list[dict]]:
    """([DayRef], skipped) for the day files of one chat directory, by name."""
    try:
        names = sorted(os.listdir(path))
    except OSError:
        return [], [{"file": str(chat_id), "reason": "unreadable"}]
    refs, skipped = [], []
    for name in names:
        m = DAY_FILE.fullmatch(name)
        if not m or (since and m.group(1) < since) or (until and m.group(1) > until):
            continue
        rel, full = f"{chat_id}/{name}", os.path.join(path, name)
        try:
            regular = stat.S_ISREG(os.lstat(full).st_mode)
        except OSError:
            skipped.append({"file": rel, "reason": "unreadable"})
            continue
        if regular:
            refs.append(DayRef(chat_id, full, rel, m.group(1)))
        else:
            skipped.append({"file": rel, "reason": "not-regular-file"})
    return refs, skipped


# ---------------------------------------------------------------- git-ignore guard

def run_git(args: list[str], stdin: Optional[bytes] = None) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in REPO_SELECTING}
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
        fd = os.open(ref.path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
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
    m = OFFSET.fullmatch(offset)
    if not CHAT_ID.fullmatch(chat) or not date or not m or int(m.group(2)) > 59 \
            or int(m.group(1)) * 60 + int(m.group(2)) > 18 * 60:
        return None, "bad-frontmatter"
    if int(chat) != ref.chat_id:
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
        if m and int(m.group(1)) <= INT64_MAX:
            current = []
            if int(m.group(1)) not in seen:
                seen.add(int(m.group(1)))
                out.append((int(m.group(1)), current))
        elif current is not None:
            current.append(line)
    return out


def annotation(line: str) -> str:
    inner = line[4:-3] if line.endswith("-->") else line[4:]
    return cut(inner.strip(), ANNOTATION_CAP)


def message(lines: list[str]) -> tuple[Optional[str], Optional[str], str, list[str]]:
    """(time, sender, text, annotations) of one block."""
    notes = [annotation(l) for l in lines if l.startswith("<!--")]
    rest = [l for l in lines if not l.startswith("<!--")]
    time = sender = None
    m = HEADER.fullmatch(rest[0]) if rest else None
    if m:
        time, sender, rest = m.group(1), m.group(2), rest[1:]
    while rest and rest[-1] == "":
        rest.pop()
    return time, sender, "\n".join(l[1:] if ESCAPED.match(l) else l for l in rest), notes


# ---------------------------------------------------------------- output pieces

def cut(text: Optional[str], limit: int) -> Optional[str]:
    return text if text is None or len(text) <= limit else text[:limit] + "…"


def folded_span(text: str, needle: str) -> Optional[tuple[int, int]]:
    """(start, end) in `text` of the first case-folded occurrence of `needle`, or None."""
    folded, index = [], []
    for i, ch in enumerate(text):
        f = ch.casefold()
        folded.append(f)
        index.extend([i] * len(f))
    k = "".join(folded).find(needle.casefold())
    return None if k < 0 else (index[k], index[k + len(needle.casefold()) - 1] + 1)


def snippet(text: str, first_term: Optional[str], width: int) -> str:
    start, end = 0, min(len(text), width)
    span = folded_span(text, first_term) if first_term and len(text) > width else None
    if span:
        s, e = span
        start = s if e - s > width else max(0, min(s - (width - (e - s)) // 2, len(text) - width))
        end = start + width
    return ("…" if start > 0 else "") + text[start:end].replace("\n", " ⏎ ") + ("…" if end < len(text) else "")


def record(ref: DayRef, offset: str, mid: int, time: Optional[str], sender: Optional[str],
           notes: list[str]) -> dict:
    return {"citation": f"telegram:{ref.chat_id}/{mid}", "chat_id": ref.chat_id, "message_id": mid,
            "date": ref.date, "time": time, "utc_offset": offset, "sender": cut(sender, SENDER_CAP),
            "file": ref.rel, "annotations": notes}


def skipped_part(skipped: list[dict]) -> dict:
    return {"skipped": skipped[:SKIPPED_LISTED], "skipped_count": len(skipped)}


# ---------------------------------------------------------------- the two modes

def search(archive: str, args: argparse.Namespace) -> dict:
    chats, skipped, missing = chat_dirs(archive, set(args.chat))
    refs = []
    for chat_id, path in chats:
        found, more = day_files(chat_id, path, args.since, args.until)
        refs += found
        skipped += more
    guard(archive, refs)
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
            time, sender, text, notes = message(lines)
            folded = text.casefold()
            if all(t in folded for t in terms) and (sender_term is None or sender_term in (sender or "").casefold()):
                hit = record(ref, offset, mid, time, sender, notes)
                hit["snippet"] = snippet(text, args.text[0] if args.text else None, args.snippet_chars)
                hits.append(hit)
    hits.sort(key=lambda h: (h["date"], h["time"] or "", h["chat_id"], h["message_id"]), reverse=True)
    shown = hits[:args.max_results]
    return dict({"archive": archive, "searched_files": searched, "matched": len(hits), "shown": len(shown),
                 "truncated": len(hits) > len(shown), "results": shown, "missing_chats": missing},
                **skipped_part(skipped))


def cite(archive: str, args: argparse.Namespace) -> dict:
    wanted = list(dict.fromkeys(args.cite))
    chats, skipped, _ = chat_dirs(archive, {c for c, _ in wanted})
    refs = []
    for chat_id, path in chats:
        found, more = day_files(chat_id, path)
        refs += found
        skipped += more
    guard(archive, refs)
    pending, out = set(wanted), {}
    for ref in refs:
        if not any(c == ref.chat_id for c, _ in pending):
            continue
        body, offset = read_day(ref)
        if body is None:
            skipped.append({"file": ref.rel, "reason": offset})
            continue
        for mid, lines in blocks(body):
            if (ref.chat_id, mid) in pending:
                time, sender, text, notes = message(lines)
                out[(ref.chat_id, mid)] = dict(record(ref, offset, mid, time, sender, notes),
                                               text=text[:TEXT_CAP], text_truncated=len(text) > TEXT_CAP)
                pending.discard((ref.chat_id, mid))
    return dict({"archive": archive, "blocks": [out[k] for k in wanted if k in out],
                 "not_found": [f"telegram:{c}/{m}" for c, m in wanted if (c, m) not in out]},
                **skipped_part(skipped))


def emit(obj: dict) -> None:
    text = UNSAFE.sub(lambda m: "\\u%04x" % ord(m.group()), json.dumps(obj, ensure_ascii=False))
    sys.stdout.buffer.write(text.encode("utf-8", "backslashreplace") + b"\n")
    sys.stdout.flush()


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        archive = resolve_archive(args.archive)
        emit(cite(archive, args) if args.cite else search(archive, args))
        return 0
    except Refusal as r:
        emit({"error": dict({"type": r.kind, "message": r.message}, **r.extra)})
        return EXIT[r.kind]
    except Exception as e:  # report, never a traceback that could carry file text
        emit({"error": {"type": "internal", "message": f"{type(e).__name__} while searching the archive"}})
        return EXIT["internal"]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
