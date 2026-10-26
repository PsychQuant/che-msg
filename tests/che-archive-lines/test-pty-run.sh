#!/bin/bash
# Self-test for tests/lib/pty_run.py, which runs calibrate under a
# pseudo-terminal in test-config-validation.sh (PsychQuant/che-msg#52).
#
# A helper that hangs, or that exits 1 with no output file, would make those
# cases fail for a reason they do not name, or pass on a stale log. The
# timeout cases come from the #52 verify: once a child had closed its copies
# of the terminal, the wait had no deadline; and on a timeout the terminal was
# closed before the kill, so the child died of SIGHUP first and killpg raised
# (6 runs in 10 with a bash child: a traceback, exit 1, no output file).
#
# Only stand-in commands run here (bash, sleep); nothing touches LINE or the
# mouse.
#
# Usage:
#   bash tests/che-archive-lines/test-pty-run.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PTY_RUN="$(cd "$SCRIPT_DIR/../lib" && pwd)/pty_run.py"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/archive-lines-pty-XXXXXX") || { echo "✗ mktemp failed" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "✗ scratch dir missing" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
export PYTHONDONTWRITEBYTECODE=1

PASSED=0
FAILED=0
OUT="$SCRATCH/out.log"
ERR="$SCRATCH/err.log"
ok()  { echo "  ✓ $1"; PASSED=$((PASSED + 1)); }
bad() { echo "  ✗ $1"; sed 's/^/      out: /' "$OUT" 2>/dev/null; sed 's/^/      err: /' "$ERR"; FAILED=$((FAILED + 1)); }
pty() {  # $@ = pty_run.py arguments after its own name, OUT excluded
    rm -f "$OUT"
    python3 "$PTY_RUN" "$@" 2> "$ERR"
}
pty_out() { pty "$OUT" "$@"; }                                 # INPUT CMD [ARG...]
pty_out_t() { local t="$1"; shift; pty --timeout "$t" "$OUT" "$@"; }  # SECONDS INPUT CMD [ARG...]
gone() { ! kill -0 "$(cat "$1")" 2>/dev/null; }

echo "test-pty-run.sh (#52)"

# ---- what the calibrate cases rely on ----
pty_out $'\n250\n' /bin/bash -c '[ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 3; read -r a || exit 4; read -r b || exit 5; [ -z "$a" ] && [ "$b" = 250 ] || exit 6; read -r c && exit 7; exit 0'
rc=$?
if [ "$rc" -eq 0 ]; then ok "stdin, stdout and stderr are a terminal; the lines arrive in order, then end of input"
else bad "terminal and line order (exit $rc)"; fi
pty_out '' /bin/bash -c 'read -r a && exit 3; echo "first read: end of input"; exit 0'
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'first read: end of input' "$OUT"; then ok "empty input: the first read sees end of input; output reaches OUT"
else bad "empty input (exit $rc)"; fi
pty_out '' /bin/bash -c 'exit 7'
rc=$?
if [ "$rc" -eq 7 ]; then ok "the command's exit status is passed through"
else bad "exit status (exit $rc)"; fi
pty_out '' /bin/bash -c 'kill -TERM $$'
rc=$?
if [ "$rc" -eq 143 ]; then ok "a command ended by SIGTERM gives 128 + 15"
else bad "signal exit (exit $rc)"; fi
pty_out 'no newline' /bin/bash -c 'exit 0'
rc=$?
if [ "$rc" -eq 2 ] && grep -q 'must be empty or end with a newline' "$OUT"; then ok "input that does not end in a newline: exit 2, and OUT says why"
else bad "bad input (exit $rc)"; fi

# ---- timeout: 124 within the deadline, OUT written, the child killed ----
# The child keeps the terminal open. Repeated, because the SIGHUP race lost
# only some of the time.
for i in 1 2 3 4 5; do
    start=$SECONDS
    pty_out_t 0.5 '' /bin/bash -c 'echo $$ > "$1"; sleep 30' _ "$SCRATCH/child.pid"
    rc=$?; took=$((SECONDS - start))
    if [ "$rc" -eq 124 ] && [ "$took" -lt 10 ] && grep -q 'killed' "$OUT" && [ ! -s "$ERR" ] && gone "$SCRATCH/child.pid"; then ok "timeout, child holds the terminal (run $i): 124 in ${took}s, OUT says killed, nothing on stderr"
    else bad "timeout, child holds the terminal (run $i) (exit $rc, ${took}s)"; fi
done
# The child closes its copies of the terminal and keeps running: the terminal
# reaches end of file at once, and only the wait can enforce the deadline.
start=$SECONDS
pty_out_t 1 '' /bin/bash -c 'exec </dev/null >/dev/null 2>&1; sleep 30 & echo $! > "$1"; wait' _ "$SCRATCH/sleep.pid"
rc=$?; took=$((SECONDS - start))
if [ "$rc" -eq 124 ] && [ "$took" -lt 10 ] && grep -q 'killed' "$OUT" && [ ! -s "$ERR" ] && gone "$SCRATCH/sleep.pid"; then ok "timeout after the child closed the terminal: 124 in ${took}s, its process group killed"
else bad "timeout after the child closed the terminal (exit $rc, ${took}s)"; fi
for t in 0 -1 abc; do
    pty_out_t "$t" '' /bin/bash -c 'exit 0'
    rc=$?
    if [ "$rc" -eq 2 ] && grep -q -- '--timeout' "$OUT"; then ok "--timeout $t is refused with exit 2"
    else bad "--timeout $t (exit $rc)"; fi
done

echo
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
