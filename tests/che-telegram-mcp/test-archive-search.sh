#!/bin/bash
# Tests for the archive-telegram-search script (PsychQuant/che-msg#80).
#
# Runs plugins/che-telegram-mcp/skills/archive-telegram-search/scripts/search_archive.py
# the way the skill does (`python3 -I <script> ...`) against synthetic day files in
# a scratch directory: the spec's example day file, #72's marker line and other
# HTML comment lines, multi-line bodies, escaped lines, a non-matching file, CR,
# FIFO and symlink day files, a symlinked chat directory, frontmatter mismatches,
# duplicate and out-of-range anchors, filters, caps, snippets, case folding,
# bidirectional characters, citations, the git-ignore guard and read-only use.
# No real archive is read; every message here is made up.
#
# Each case runs once per interpreter: `python3` and, when it exists and differs,
# /usr/bin/python3 (Command Line Tools ship 3.9, the oldest the script supports).
#
# Usage:
#   bash tests/che-telegram-mcp/test-archive-search.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEARCH="$SCRIPT_DIR/../../plugins/che-telegram-mcp/skills/archive-telegram-search/scripts/search_archive.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL python3 not found — no case can run"
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "FAIL git not found — the guard cases cannot run"
    exit 1
fi

INTERPRETERS=("$(command -v python3)")
if [ -x /usr/bin/python3 ] && [ "$(/usr/bin/python3 -c 'import sys; print(sys.version)' 2>/dev/null)" != \
        "$(python3 -c 'import sys; print(sys.version)')" ]; then
    INTERPRETERS+=(/usr/bin/python3)
fi

echo "test-archive-search.sh (#80) — $SEARCH"

TOTAL_FAIL=0
TOTAL_PASS=0
for PY in "${INTERPRETERS[@]}"; do
    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/archive-search-XXXXXX") || { echo "FAIL mktemp"; exit 1; }
    OUT=$(python3 - "$PY" "$SEARCH" "$SCRATCH" <<'EOF'
import json, os, subprocess, sys

PY, SEARCH, SCRATCH = sys.argv[1], sys.argv[2], os.path.realpath(sys.argv[3])
passed = failed = 0
current = ""

def check(cond, what):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print(f"FAIL [{current}] {what}")

def env():
    e = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    # Discovery stops below the scratch directory, so "outside a repository" does
    # not depend on where TMPDIR happens to be.
    e["GIT_CEILING_DIRECTORIES"] = SCRATCH
    return e

def run(args, extra_env=None, cwd=None, timeout=20):
    e = env()
    e.update(extra_env or {})
    p = subprocess.run([PY, "-I", SEARCH] + args, capture_output=True, timeout=timeout,
                       cwd=cwd or SCRATCH, env=e)
    try:
        data = json.loads(p.stdout.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        data = None
    return p.returncode, p.stdout, data, p.stderr

FM = '---\nchat_id: {chat}\ndate: {date}\nutc_offset: "{off}"\n---\n\n'

def blk(mid, time, sender, *body, notes=()):
    lines = [f"<!-- msg:{mid} -->"] + [f"<!-- {n} -->" for n in notes] + [f"**{time} {sender}**："] + list(body)
    return "\n".join(lines) + "\n\n"

def write(path, text, mode="w"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode, encoding="utf-8", newline="") as fh:
        fh.write(text)

n_archives = 0
def archive():
    global n_archives
    n_archives += 1
    root = os.path.join(SCRATCH, f"a{n_archives}", "telegram")
    os.makedirs(root)
    return root

def day(root, chat, date, *blocks, off="+08:00", front=None):
    text = (front if front is not None else FM.format(chat=chat, date=date, off=off)) + "".join(blocks)
    write(os.path.join(root, str(chat), f"{date}.md"), text)

# The example day file of telegram-chat-archive "Day file format", verbatim.
SPEC_EXAMPLE = """---
chat_id: 777
date: 2026-10-11
utc_offset: "+08:00"
---

<!-- msg:5242880 -->
**09:05 Alex**：
hello

<!-- msg:5243904 -->
**09:07 我**：
[photo](media/5243904/) menu

"""

def cites(data, key="results"):
    return [r["citation"] for r in (data or {}).get(key, [])]

def case(name):
    global current
    current = name

# ---------------------------------------------------------------- reader contract
def git(*args, cwd):
    subprocess.run(["git"] + list(args), cwd=cwd, check=True, capture_output=True, env=env())

def repo_archive(name, ignore):
    repo = os.path.join(SCRATCH, name)
    os.makedirs(repo)
    git("init", "-q", cwd=repo)
    if ignore is not None:
        write(os.path.join(repo, ".gitignore"), ignore)
    root = os.path.join(repo, "archives", "telegram")
    day(root, 777, "2026-10-11", blk(5242880, "09:05", "Alex", "hello"))
    return repo, root

def _case_0():
    case("spec example: text message")
    A = archive()
    write(os.path.join(A, "777", "2026-10-11.md"), SPEC_EXAMPLE)
    rc, raw, d, err = run(["--archive", A, "--text", "hello"])
    check(rc == 0 and d is not None, f"exit 0 with JSON (rc={rc}, stderr={err[:200]!r})")
    if d:
        check(cites(d) == ["telegram:777/5242880"], f"one result telegram:777/5242880, got {cites(d)}")
        r = d["results"][0] if d["results"] else {}
        check(r.get("chat_id") == 777 and r.get("message_id") == 5242880, f"ids: {r}")
        check(r.get("date") == "2026-10-11" and r.get("time") == "09:05", f"date/time: {r}")
        check(r.get("sender") == "Alex" and r.get("utc_offset") == "+08:00", f"sender/offset: {r}")
        check(r.get("snippet") == "hello", f"snippet: {r.get('snippet')!r}")
        check(r.get("file") == "777/2026-10-11.md", f"file: {r.get('file')!r}")
        check(r.get("annotations") == [], f"annotations: {r.get('annotations')!r}")
        check(d.get("archive") == A and d.get("searched_files") == 1, f"archive/searched_files: {d.get('archive')}, {d.get('searched_files')}")
        check(d.get("matched") == 1 and d.get("shown") == 1 and d.get("truncated") is False, "matched/shown/truncated")
        check(d.get("skipped") == [] and d.get("skipped_count") == 0 and d.get("missing_chats") == [], "nothing skipped")

def _case_1():
    case("spec example: media caption is searchable")
    A = archive()
    write(os.path.join(A, "777", "2026-10-11.md"), SPEC_EXAMPLE)
    rc, raw, d, err = run(["--archive", A, "--text", "MENU"])
    check(rc == 0 and cites(d) == ["telegram:777/5243904"], f"caption match, got {cites(d)}")
    if d and d["results"]:
        check(d["results"][0]["snippet"] == "[photo](media/5243904/) menu", f"media snippet: {d['results'][0]['snippet']!r}")
        check(d["results"][0]["sender"] == "我", "outgoing sender 我")

def _case_2():
    case("#72 marker line after the anchor")
    A = archive()
    day(A, 777, "2026-10-12", blk(9, "10:00", "User 1001", "hi", notes=["provisional: local-cache"]))
    rc, raw, d, err = run(["--archive", A, "--text", "hi"])
    check(rc == 0 and cites(d) == ["telegram:777/9"], f"found by text, got {cites(d)}")
    if d and d["results"]:
        r = d["results"][0]
        check(r["time"] == "10:00" and r["sender"] == "User 1001", f"header after the marker: {r}")
        check(r["snippet"] == "hi", f"marker is not text: {r['snippet']!r}")
        check(r["annotations"] == ["provisional: local-cache"], f"annotation: {r['annotations']!r}")
    rc, raw, d, err = run(["--archive", A, "--text", "provisional"])
    check(rc == 0 and d is not None and d["matched"] == 0, "marker text is not searched")

def _case_3():
    case("other HTML comment lines are annotations, wherever they are")
    A = archive()
    text = ("<!-- msg:20 -->\n**11:00 Kim**：\nfirst line\n<!-- note by hand -->\nsecond line\n\n")
    day(A, 777, "2026-10-13", text)
    rc, raw, d, err = run(["--archive", A, "--cite", "telegram:777/20"])
    check(rc == 0 and d is not None and len(d.get("blocks", [])) == 1, f"block found (rc={rc}, {d})")
    if d and d.get("blocks"):
        b = d["blocks"][0]
        check(b["text"] == "first line\nsecond line", f"comment line left out of text: {b['text']!r}")
        check(b["annotations"] == ["note by hand"], f"annotation: {b['annotations']!r}")
    rc, raw, d, err = run(["--archive", A, "--text", "by hand"])
    check(rc == 0 and d is not None and d["matched"] == 0, "comment text is not searched")

def _case_4():
    case("multi-line body: snippet joins lines, citation returns the whole text")
    A = archive()
    day(A, 777, "2026-10-14", blk(30, "12:00", "Alex", "agenda", "1. budget draft", "2. venue"))
    rc, raw, d, err = run(["--archive", A, "--text", "budget"])
    check(rc == 0 and cites(d) == ["telegram:777/30"], f"term on line 2 found, got {cites(d)}")
    if d and d["results"]:
        check(d["results"][0]["snippet"] == "agenda ⏎ 1. budget draft ⏎ 2. venue", f"snippet: {d['results'][0]['snippet']!r}")
    rc, raw, d, err = run(["--archive", A, "--cite", "telegram:777/30"])
    if d and d.get("blocks"):
        check(d["blocks"][0]["text"] == "agenda\n1. budget draft\n2. venue", f"text: {d['blocks'][0]['text']!r}")
        check(d["blocks"][0]["text_truncated"] is False, "not truncated")
    else:
        check(False, f"cite returned {d}")
    rc, raw, d, err = run(["--archive", A, "--text", "budget", "--text", "venue"])
    check(rc == 0 and cites(d) == ["telegram:777/30"], "two terms on different lines (AND)")
    rc, raw, d, err = run(["--archive", A, "--text", "budget", "--text", "missing"])
    check(rc == 0 and d is not None and d["matched"] == 0, "AND: one term missing")

def _case_82():
    case("#82 bodies: poll options, sticker emoji, location")
    A = archive()
    day(A, 777, "2026-10-26", blk(31, "13:00", "Alex", "[poll] Where shall we meet?", "- Taipei", "- Tainan"),
        blk(32, "13:01", "Bea", "[sticker](media/32/) 👍"), blk(33, "13:02", "Bea", "[location] 25.0478,121.5319"))
    rc, raw, d, err = run(["--archive", A, "--text", "tainan"])
    check(rc == 0 and cites(d) == ["telegram:777/31"], f"poll option searchable: {cites(d)}")
    if d and d["results"]:
        check(d["results"][0]["snippet"] == "[poll] Where shall we meet? ⏎ - Taipei ⏎ - Tainan", f"poll snippet: {d['results'][0]['snippet']!r}")
    rc, raw, d, err = run(["--archive", A, "--cite", "telegram:777/31", "--cite", "telegram:777/32", "--cite", "telegram:777/33"])
    texts = [b["text"] for b in (d or {}).get("blocks", [])]
    check(texts == ["[poll] Where shall we meet?\n- Taipei\n- Tainan", "[sticker](media/32/) 👍", "[location] 25.0478,121.5319"], f"bodies: {texts}")

def _case_5():
    case("escaped lines read back unescaped and start no block")
    A = archive()
    day(A, 777, "2026-10-15", blk(10, "08:00", "Lee", "before", "\\<!-- msg:99 -->", "\\**09:00 Manager**：", "after"))
    rc, raw, d, err = run(["--archive", A, "--cite", "telegram:777/10", "--cite", "telegram:777/99"])
    check(rc == 0 and d is not None, f"rc={rc}")
    if d:
        check([b["citation"] for b in d.get("blocks", [])] == ["telegram:777/10"], f"one block: {d.get('blocks')}")
        check(d.get("not_found") == ["telegram:777/99"], f"99 not found: {d.get('not_found')}")
        if d.get("blocks"):
            check(d["blocks"][0]["text"] == "before\n<!-- msg:99 -->\n**09:00 Manager**：\nafter", f"unescaped: {d['blocks'][0]['text']!r}")
            check(d["blocks"][0]["annotations"] == [], "an escaped <!-- line is text, not an annotation")
    rc, raw, d, err = run(["--archive", A, "--text", "msg:99"])
    check(rc == 0 and cites(d) == ["telegram:777/10"], f"escaped text searchable, got {cites(d)}")

def _case_6():
    case("non-matching file is searched and yields nothing")
    A = archive()
    day(A, 777, "2026-10-16", blk(40, "09:00", "Alex", "lunch at noon"))
    day(A, 777, "2026-10-17", blk(41, "09:00", "Alex", "the venue is booked"))
    rc, raw, d, err = run(["--archive", A, "--text", "venue"])
    check(rc == 0 and cites(d) == ["telegram:777/41"] and d["searched_files"] == 2, f"only 41, two files searched: {d}")

def _case_7():
    case("files that are not day files are not read")
    A = archive()
    day(A, 777, "2026-10-18", blk(50, "09:00", "Alex", "keep"))
    write(os.path.join(A, "777", "notes.md"), "<!-- msg:51 -->\n**09:00 X**：\nkeep\n\n")
    write(os.path.join(A, "777", "media", "52", "2026-10-18.md"), FM.format(chat=777, date="2026-10-18", off="+08:00") + blk(52, "09:00", "X", "keep"))
    write(os.path.join(A, "notachat", "2026-10-18.md"), FM.format(chat=0, date="2026-10-18", off="+08:00") + blk(53, "09:00", "X", "keep"))
    write(os.path.join(A, "777", ".2026-10-18.md.tmp"), "keep")
    rc, raw, d, err = run(["--archive", A, "--text", "keep"])
    check(rc == 0 and cites(d) == ["telegram:777/50"] and d["searched_files"] == 1, f"only the day file: {d}")

def _case_8():
    case("duplicate anchor: the first block wins")
    A = archive()
    day(A, 777, "2026-10-19", blk(60, "09:00", "Alex", "original"), blk(60, "09:01", "Alex", "duplicate"))
    rc, raw, d, err = run(["--archive", A, "--cite", "telegram:777/60"])
    check(rc == 0 and d and len(d["blocks"]) == 1 and d["blocks"][0]["text"] == "original", f"first kept: {d}")
    rc, raw, d, err = run(["--archive", A, "--text", "duplicate"])
    check(rc == 0 and d is not None and d["matched"] == 0, "the later duplicate is ignored")

def _case_9():
    case("anchor out of the Int64 range starts no block")
    A = archive()
    day(A, 777, "2026-10-20", blk(70, "09:00", "Alex", "head"), "<!-- msg:9223372036854775808 -->\n**09:01 Bob**：\ntail word\n\n")
    rc, raw, d, err = run(["--archive", A, "--text", "tail word"])
    check(rc == 0 and cites(d) == ["telegram:777/70"], f"overflow line belongs to block 70: {cites(d)}")
    rc, raw, d, err = run(["--archive", A, "--cite", "telegram:777/9223372036854775808"])
    check(rc == 2 and d and d.get("error", {}).get("type") == "usage", f"overflow citation is a usage error: rc={rc} {d}")

def _case_10():
    case("text before the first anchor is ignored")
    A = archive()
    day(A, 777, "2026-10-21", "stray preamble words\n\n", blk(80, "09:00", "Alex", "body"))
    rc, raw, d, err = run(["--archive", A, "--text", "preamble"])
    check(rc == 0 and d is not None and d["matched"] == 0, "preamble not searched")

def _case_11():
    case("skipped day files: CR, frontmatter, not UTF-8")
    A = archive()
    day(A, 777, "2026-10-22", blk(90, "09:00", "Alex", "word"))
    write(os.path.join(A, "777", "2026-10-23.md"), (FM.format(chat=777, date="2026-10-23", off="+08:00") + blk(91, "09:00", "Alex", "word")).replace("\n", "\r\n"))
    day(A, 777, "2026-10-24", blk(92, "09:00", "Alex", "word"), front=FM.format(chat=778, date="2026-10-24", off="+08:00"))
    day(A, 777, "2026-10-25", blk(93, "09:00", "Alex", "word"), front=FM.format(chat=777, date="2026-10-26", off="+08:00"))
    day(A, 777, "2026-10-27", blk(94, "09:00", "Alex", "word"), front='---\nchat_id: 777\ndate: 2026-10-27\n---\n\n')
    day(A, 777, "2026-10-28", blk(95, "09:00", "Alex", "word"), front="")
    with open(os.path.join(A, "777", "2026-10-29.md"), "wb") as fh:
        fh.write(FM.format(chat=777, date="2026-10-29", off="+08:00").encode() + b"<!-- msg:96 -->\n**09:00 A**\xef\xbc\x9a\nword \xff\n\n")
    day(A, 777, "2026-10-30", blk(97, "09:00", "Alex", "word"), off="+8:00")
    rc, raw, d, err = run(["--archive", A, "--text", "word"])
    check(rc == 0 and cites(d) == ["telegram:777/90"], f"only the good file: {cites(d)}")
    if d:
        reasons = {s["file"]: s["reason"] for s in d["skipped"]}
        want = {"777/2026-10-23.md": "carriage-return", "777/2026-10-24.md": "chat-id-mismatch",
                "777/2026-10-25.md": "date-mismatch", "777/2026-10-27.md": "bad-frontmatter",
                "777/2026-10-28.md": "bad-frontmatter", "777/2026-10-29.md": "not-utf8",
                "777/2026-10-30.md": "bad-frontmatter"}
        check(reasons == want, f"skip reasons: {reasons}")
        check(d["skipped_count"] == 7 and d["searched_files"] == 1, f"counts: {d['skipped_count']}, {d['searched_files']}")

def _case_12():
    case("FIFO and symlinked day files are skipped without waiting")
    A = archive()
    day(A, 777, "2026-11-01", blk(100, "09:00", "Alex", "word"))
    os.mkfifo(os.path.join(A, "777", "2026-11-02.md"))
    outside = os.path.join(SCRATCH, "outside-day.md")
    write(outside, FM.format(chat=777, date="2026-11-03", off="+08:00") + blk(101, "09:00", "Alex", "word"))
    os.symlink(outside, os.path.join(A, "777", "2026-11-03.md"))
    os.symlink(os.path.join(SCRATCH, "nowhere.md"), os.path.join(A, "777", "2026-11-04.md"))
    try:
        rc, raw, d, err = run(["--archive", A, "--text", "word"], timeout=10)
    except subprocess.TimeoutExpired:
        rc, d = None, None
    check(rc == 0 and cites(d) == ["telegram:777/100"], f"returned without hanging: rc={rc} {cites(d)}")
    if d:
        reasons = {s["file"]: s["reason"] for s in d["skipped"]}
        check(reasons == {"777/2026-11-02.md": "not-regular-file", "777/2026-11-03.md": "not-regular-file",
                          "777/2026-11-04.md": "not-regular-file"}, f"reasons: {reasons}")

def _case_13():
    case("symlinked chat directory is not entered")
    A = archive()
    day(A, 777, "2026-11-05", blk(110, "09:00", "Alex", "word"))
    other = os.path.join(SCRATCH, "other-chat")
    write(os.path.join(other, "2026-11-05.md"), FM.format(chat=888, date="2026-11-05", off="+08:00") + blk(111, "09:00", "Alex", "word"))
    os.symlink(other, os.path.join(A, "888"))
    rc, raw, d, err = run(["--archive", A, "--text", "word"])
    check(rc == 0 and cites(d) == ["telegram:777/110"], f"symlinked chat not searched: {cites(d)}")
    if d:
        check({s["file"]: s["reason"] for s in d["skipped"]} == {"888": "symlinked-chat-directory"}, f"skipped: {d['skipped']}")

# ---------------------------------------------------------------- filters
def _case_14():
    case("sender, date range and chat filters")
    A = archive()
    day(A, 777, "2026-09-01", blk(200, "09:00", "Alex Chen", "status"), blk(201, "09:05", "Bea", "status"))
    day(A, 777, "2026-09-02", blk(202, "10:00", "alex chen", "status"))
    day(A, 777, "2026-09-03", blk(203, "11:00", "Bea", "status"))
    day(A, -1001234567890, "2026-09-02", blk(204, "12:00", "Alex Chen", "status"))
    rc, raw, d, err = run(["--archive", A, "--sender", "ALEX"])
    check(rc == 0 and cites(d) == ["telegram:-1001234567890/204", "telegram:777/202", "telegram:777/200"], f"sender, newest first: {cites(d)}")
    rc, raw, d, err = run(["--archive", A, "--since", "2026-09-02", "--until", "2026-09-02"])
    check(rc == 0 and cites(d) == ["telegram:-1001234567890/204", "telegram:777/202"], f"date range inclusive: {cites(d)}")
    rc, raw, d, err = run(["--archive", A, "--chat", "777", "--since", "2026-09-03"])
    check(rc == 0 and cites(d) == ["telegram:777/203"], f"chat + since: {cites(d)}")
    rc, raw, d, err = run(["--archive", A, "--chat", "-1001234567890", "--text", "status"])
    check(rc == 0 and cites(d) == ["telegram:-1001234567890/204"] and d["results"][0]["chat_id"] == -1001234567890, f"negative chat id: {d}")
    rc, raw, d, err = run(["--archive", A, "--chat", "555", "--chat", "777", "--text", "status", "--until", "2026-09-01"])
    check(rc == 0 and d and d["missing_chats"] == [555] and cites(d) == ["telegram:777/201", "telegram:777/200"], f"missing chat listed: {d}")
    rc, raw, d, err = run(["--archive", A, "--chat", "777", "--cite", "telegram:777/200"])
    check(rc == 2 and d and d["error"]["type"] == "usage", "citations do not mix with filters")

def _case_15():
    case("values that begin with a dash, in --opt=value form")
    A = archive()
    day(A, -1009, "2026-09-05", blk(220, "09:00", "Alex", "run it with -v please"))
    rc, raw, d, err = run(["--archive=" + A, "--text=-v please", "--chat=-1009", "--sender=Alex"])
    check(rc == 0 and cites(d) == ["telegram:-1009/220"], f"--opt=value: rc={rc} {cites(d)}")
    rc, raw, d, err = run(["--archive", A, "--cite=telegram:-1009/220"])
    check(rc == 0 and d and [b["citation"] for b in d["blocks"]] == ["telegram:-1009/220"], f"--cite=: {d}")
    rc, raw, d, err = run(["--archiv", A, "--text", "please"])
    check(rc == 2 and d and d["error"]["type"] == "usage", "abbreviated option names are refused")

def _case_16():
    case("case folding: snippet maps back to the original text")
    A = archive()
    day(A, 777, "2026-09-10", blk(210, "09:00", "Alex", "Die STRASSE ist lang"), blk(211, "09:01", "Ödön", "Ärger"))
    rc, raw, d, err = run(["--archive", A, "--text", "straße"])
    check(rc == 0 and cites(d) == ["telegram:777/210"], f"ß folds to ss: {cites(d)}")
    rc, raw, d, err = run(["--archive", A, "--text", "ärger", "--sender", "ÖDÖN"])
    check(rc == 0 and cites(d) == ["telegram:777/211"], f"non-ASCII case: {cites(d)}")

def _case_17():
    case("cap: more matches than max_results")
    A = archive()
    for i in range(25):
        day(A, 777, f"2026-08-{i + 1:02d}", blk(300 + i, "09:00", "Alex", f"weekly report {i}"))
    rc, raw, d, err = run(["--archive", A, "--text", "weekly"])
    check(rc == 0 and d and d["matched"] == 25 and d["shown"] == 20 and d["truncated"] is True, f"20 of 25: {d and (d['matched'], d['shown'], d['truncated'])}")
    check(cites(d)[:1] == ["telegram:777/324"] and cites(d)[-1:] == ["telegram:777/305"], f"newest 20: {cites(d)[:1]}…{cites(d)[-1:]}")
    rc, raw, d, err = run(["--archive", A, "--text", "weekly", "--max-results", "3"])
    check(rc == 0 and d and d["shown"] == 3 and cites(d) == ["telegram:777/324", "telegram:777/323", "telegram:777/322"], "max_results 3")
    for bad in (["--max-results", "0"], ["--max-results", "101"], ["--snippet-chars", "19"], ["--snippet-chars", "201"], ["--max-results", "x"]):
        rc, raw, d, err = run(["--archive", A, "--text", "weekly"] + bad)
        check(rc == 2 and d and d["error"]["type"] == "usage", f"{bad} refused: rc={rc}")

def _case_18():
    case("snippet of a long message")
    A = archive()
    long_text = "a" * 240 + " needle " + "b" * 252
    day(A, 777, "2026-07-01", blk(400, "09:00", "Alex", long_text), blk(401, "09:01", "Alex", "x" * 300))
    rc, raw, d, err = run(["--archive", A, "--text", "needle"])
    s = d["results"][0]["snippet"] if d and d.get("results") else ""
    check("needle" in s and s.startswith("…") and s.endswith("…") and len(s) <= 82, f"centered snippet ({len(s)}): {s!r}")
    rc, raw, d, err = run(["--archive", A, "--sender", "Alex", "--snippet-chars", "20"])
    s = {r["citation"]: r["snippet"] for r in (d or {}).get("results", [])}
    check(s.get("telegram:777/401") == "x" * 20 + "…", f"start of text without a term: {s.get('telegram:777/401')!r}")
    long_sender = "N" * 100
    day(A, 777, "2026-07-02", blk(402, "09:00", long_sender, "hello"))
    rc, raw, d, err = run(["--archive", A, "--text", "hello"])
    check(d and d["results"] and d["results"][0]["sender"] == "N" * 64 + "…", "sender cut to 64")

def _case_19():
    case("whole text only for named citations, capped at 4000")
    A = archive()
    day(A, 777, "2026-07-03", blk(410, "09:00", "Alex", "y" * 5000))
    rc, raw, d, err = run(["--archive", A, "--cite", "telegram:777/410"])
    b = d["blocks"][0] if d and d.get("blocks") else {}
    check(len(b.get("text", "")) == 4000 and b.get("text_truncated") is True, f"cut to 4000: {len(b.get('text', ''))}")
    rs = (run(["--archive", A, "--text", "yyy"])[2] or {}).get("results") or [{"text": None}]
    check("text" not in rs[0] and "snippet" in rs[0], "a search result has a snippet and no text field")
    eleven = sum((["--cite", f"telegram:777/{i}"] for i in range(1, 12)), [])
    rc, raw, d, err = run(["--archive", A] + eleven)
    check(rc == 2 and d and d["error"]["type"] == "usage", "more than 10 citations refused")
    for bad in ("777/410", "telegram:777/msg410", "telegram:777/0410", "telegram:0777/410", "telegram:777/", "Telegram:777/410"):
        rc, raw, d, err = run(["--archive", A, "--cite", bad])
        check(rc == 2 and d and d["error"]["type"] == "usage", f"malformed citation {bad!r} refused: rc={rc}")
    rc, raw, d, err = run(["--archive", A, "--cite", "telegram:777/1", "--cite", "telegram:999/1"])
    check(rc == 0 and d and d["blocks"] == [] and d["not_found"] == ["telegram:777/1", "telegram:999/1"], f"not found: {d}")

def _case_20():
    case("usage errors")
    A = archive()
    day(A, 777, "2026-07-04", blk(420, "09:00", "Alex", "hi"))
    for bad in ([], ["--text", ""], ["--text", "   "], ["--sender", ""], ["--since", "2026-13-01"], ["--since", "2026-07-05", "--until", "2026-07-04"],
                ["--chat", "abc"], ["--unknown"]):
        rc, raw, d, err = run(["--archive", A] + bad)
        check(rc == 2 and d and d.get("error", {}).get("type") == "usage", f"{bad} refused: rc={rc} {raw[:120]!r}")
    rc, raw, d, err = run(["--text", "hi"])
    check(rc == 2 and d and d["error"]["type"] == "usage", "--archive is required")
    for bad in ("relative/telegram", os.path.join(SCRATCH, "does-not-exist"), os.path.join(A, "777", "2026-07-04.md")):
        rc, raw, d, err = run(["--archive", bad, "--text", "hi"])
        check(rc == 4 and d and d["error"]["type"] == "archive_missing", f"{bad} is archive_missing: rc={rc}")

def _case_21():
    case("output escapes control and bidirectional characters")
    A = archive()
    day(A, 777, "2026-07-05", blk(430, "09:00", "Eve‮", "pay ‮gnp.exe now \x1b[31m red \u0085   ⁦x⁩ ‏"))
    rc, raw, d, err = run(["--archive", A, "--text", "pay"])
    check(rc == 0 and d and d["results"], f"found: rc={rc}")
    for ch in ("‮", "\x1b", "\u0085", " ", "⁦", "⁩", "‏"):
        check(d is not None and ch.encode("utf-8") not in raw, f"U+{ord(ch):04X} not raw in output")
    if d and d["results"]:
        check("‮gnp.exe" in d["results"][0]["snippet"] and "\x1b[31m" in d["results"][0]["snippet"], "decoded text keeps them")
        check(d["results"][0]["sender"] == "Eve‮", "sender keeps them")

# ---------------------------------------------------------------- guard and read-only
def _case_22():
    case("guard: archive inside a repository and ignored")
    repo, A = repo_archive("r-ignored", "archives/telegram/\n")
    rc, raw, d, err = run(["--archive", A, "--text", "hello"])
    check(rc == 0 and cites(d) == ["telegram:777/5242880"], f"searched: rc={rc} {d}")

def _case_23():
    case("guard: archive inside a repository and not ignored")
    repo, A = repo_archive("r-not-ignored", "*.log\n")
    rc, raw, d, err = run(["--archive", A, "--text", "hello"])
    check(rc == 3 and d and d["error"]["type"] == "not_ignored", f"refused: rc={rc} {d}")
    check(d and d["error"].get("files") == ["777/2026-10-11.md"] and d["error"].get("count") == 1, f"names the file: {d}")
    check(d is not None and b"hello" not in raw and b"Alex" not in raw, "no message text in the refusal")
    rc, raw, d, err = run(["--archive", A, "--cite", "telegram:777/5242880"])
    check(rc == 3 and d and d["error"]["type"] == "not_ignored" and b"hello" not in raw, "citation lookup refused too")

def _case_24():
    case("guard: tracked day file under an ignore rule")
    repo, A = repo_archive("r-tracked", "archives/telegram/\n")
    git("add", "-f", "archives/telegram/777/2026-10-11.md", cwd=repo)
    rc, raw, d, err = run(["--archive", A, "--text", "hello"])
    check(rc == 3 and d and d["error"]["type"] == "not_ignored" and d["error"].get("files") == ["777/2026-10-11.md"], f"tracked refused: {d}")

def _case_25():
    case("guard: a partial ignore rule leaves one chat out")
    repo, A = repo_archive("r-partial", "archives/telegram/777/\n")
    day(A, 888, "2026-10-11", blk(1, "09:00", "Bo", "hello"))
    rc, raw, d, err = run(["--archive", A, "--text", "hello"])
    check(rc == 3 and d and d["error"].get("files") == ["888/2026-10-11.md"], f"uncovered chat named: {d}")
    rc, raw, d, err = run(["--archive", A, "--text", "hello", "--chat", "777"])
    check(rc == 0 and cites(d) == ["telegram:777/5242880"], "only the files to be read are checked")

def _case_26():
    case("guard: GIT_DIR in the environment does not redirect the check")
    repo, A = repo_archive("r-gitdir", "*.log\n")
    elsewhere = os.path.join(SCRATCH, "elsewhere")
    os.makedirs(elsewhere)
    git("init", "-q", cwd=elsewhere)
    rc, raw, d, err = run(["--archive", A, "--text", "hello"], extra_env={"GIT_DIR": os.path.join(elsewhere, ".git"), "GIT_WORK_TREE": elsewhere})
    check(rc == 3 and d and d["error"]["type"] == "not_ignored", f"still checked against the archive's repository: rc={rc} {d}")

def _case_27():
    case("guard: git failure other than not-a-repository refuses")
    A = archive()
    day(A, 777, "2026-10-11", blk(1, "09:00", "Alex", "hello"))
    fakebin = os.path.join(SCRATCH, "fakebin")
    os.makedirs(fakebin, exist_ok=True)
    write(os.path.join(fakebin, "git"), "#!/bin/sh\necho 'fatal: detected dubious ownership in repository' >&2\nexit 128\n")
    os.chmod(os.path.join(fakebin, "git"), 0o755)
    rc, raw, d, err = run(["--archive", A, "--text", "hello"], extra_env={"PATH": fakebin + os.pathsep + "/usr/bin:/bin"})
    check(rc == 3 and d and d["error"]["type"] == "git_failed" and b"hello" not in raw, f"git_failed: rc={rc} {d}")
    rc, raw, d, err = run(["--archive", A, "--text", "hello"], extra_env={"PATH": os.path.join(SCRATCH, "empty-path")})
    check(rc == 3 and d and d["error"]["type"] == "git_failed", f"no git at all: rc={rc} {d}")

def _case_28():
    case("read-only: nothing in the archive or the working directory changes")
    A = archive()
    write(os.path.join(A, "777", "2026-10-11.md"), SPEC_EXAMPLE)
    day(A, 777, "2026-10-12", blk(5300000, "09:00", "Alex", "later"))
    write(os.path.join(A, "777", "media", "5243904", "menu.jpg"), "jpeg")
    def listing(top):
        out = []
        for base, dirs, files in os.walk(top):
            for n in sorted(dirs + files):
                st = os.lstat(os.path.join(base, n))
                out.append((os.path.relpath(os.path.join(base, n), top), st.st_size, st.st_mtime_ns, st.st_mode))
        return sorted(out)
    work = os.path.join(SCRATCH, "cwd")
    os.makedirs(work)
    before, before_cwd = listing(os.path.dirname(A)), listing(work)
    r1 = run(["--archive", A, "--text", "hello"], cwd=work)
    r2 = run(["--archive", A, "--cite", "telegram:777/5242880"], cwd=work)
    check(r1[0] == 0 and r2[0] == 0 and r2[2] and len(r2[2]["blocks"]) == 1, "both calls succeeded")
    check(listing(os.path.dirname(A)) == before, "archive listing unchanged")
    check(listing(work) == before_cwd == [], "working directory still empty")

CASES = [_case_82, _case_0, _case_1, _case_2, _case_3, _case_4, _case_5, _case_6, _case_7, _case_8, _case_9, _case_10, _case_11, _case_12, _case_13, _case_14, _case_15, _case_16, _case_17, _case_18, _case_19, _case_20, _case_21, _case_22, _case_23, _case_24, _case_25, _case_26, _case_27, _case_28]
for fn in CASES:
    try:
        fn()
    except Exception as e:  # a crash fails this case only
        check(False, f"crashed: {type(e).__name__}: {e}")

print(f"RESULT {passed} {failed}")
EOF
)
    rm -rf "$SCRATCH"
    printf '%s\n' "$OUT" | grep -v '^RESULT ' | sed "s|^|  [$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)] |"
    RES=$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p')
    if [ -z "$RES" ]; then
        echo "FAIL harness crashed under $PY"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        continue
    fi
    set -- $RES
    TOTAL_PASS=$((TOTAL_PASS + $1)); TOTAL_FAIL=$((TOTAL_FAIL + $2))
    echo "$PY: $1 passed, $2 failed"
done

echo
echo "Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
[ "$TOTAL_FAIL" -eq 0 ]
