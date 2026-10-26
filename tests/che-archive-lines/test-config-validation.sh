#!/bin/bash
# Regression test for #149: config values must be integers before they reach
# bash arithmetic in scripts/line-save-chat.sh.
#
# bash evaluates array subscripts inside $((…)), so a config value such as
# a[$(cmd)] runs cmd. load_config read three values with grep and passed them
# straight into $((…)) in `save` and `test`; calibrate wrote whatever the user
# typed as menu_offset_y. Each case below plants a payload that would create a
# marker file, then checks the marker never appears and nothing is clicked.
#
# The script never touches the real mouse here: a stub directory first on PATH
# provides cliclick (logs its arguments; `p` prints a fixed position) and
# osascript (prints a fixed LINE window for the System Events query, nothing
# otherwise), and HOME points at a scratch directory so the real config under
# ~/.config/che-archive-lines is never read or written.
#
# calibrate refuses to run unless stdin is a terminal (PsychQuant/che-msg#52),
# so its cases run under a pseudo-terminal from tests/lib/pty_run.py (run_pty),
# typing the lines the case gives and then end of input. The last section
# checks the #52 guards themselves: no terminal, input that ends at either
# prompt, and a cursor outside the LINE window, each leaving the config as it
# was. (A bare #149 is PsychQuant/psychquant-claude-plugins#149.)
#
# Usage:
#   bash tests/che-archive-lines/test-config-validation.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "$SCRIPT_DIR/../../plugins/che-archive-lines/scripts" && pwd)/line-save-chat.sh"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/archive-lines-config-XXXXXX") || { echo "✗ mktemp failed" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "✗ scratch dir missing" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

STUB="$SCRATCH/stub"
mkdir -p "$STUB"
# STUB_POS / STUB_WINDOW override what the stubs report (default: a sane
# cursor position and LINE window), so a case can feed a payload through them.
cat > "$STUB/cliclick" <<EOF
#!/bin/bash
echo "\$*" >> "$SCRATCH/clicks.log"
[ "\$1" = p ] && echo "\${STUB_POS:-500,300}"
exit 0
EOF
# STUB_OSA_FAIL=1 makes the window query fail the way real osascript does when
# LINE is not running or has no window (an AppleScript error, exit status 1).
# Every call is logged, so a case can check that LINE was never activated.
cat > "$STUB/osascript" <<EOF
#!/bin/bash
echo "\$*" >> "$SCRATCH/osascript.log"
case "\$*" in *"System Events"*)
    if [ -n "\${STUB_OSA_FAIL:-}" ]; then echo "execution error: Can't get window 1 of process \\"LINE\\". (-1719)" >&2; exit 1; fi
    echo "\${STUB_WINDOW:-100 100 800 600}" ;;
esac
exit 0
EOF
chmod +x "$STUB/cliclick" "$STUB/osascript"

PASSED=0
FAILED=0
CONFIG="$SCRATCH/home/.config/che-archive-lines/config.json"
MARK="$SCRATCH/PWNED"

reset() {
    rm -rf "$SCRATCH/home" "$SCRATCH/clicks.log" "$SCRATCH/osascript.log" "$MARK"
    mkdir -p "$SCRATCH/home"
}
write_config() {  # $1 offset_x, $2 offset_y, $3 menu_offset_y line (empty = omit)
    mkdir -p "$(dirname "$CONFIG")"
    {
        echo '{'
        echo '  "version": "1.0",'
        echo "  \"offset_x\": $1,"
        echo "  \"offset_y\": $2,"
        [ -n "$3" ] && echo "  \"menu_offset_y\": $3,"
        echo '  "description": "x"'
        echo '}'
    } > "$CONFIG"
}
run() {  # $@ = script arguments; stdin passes through. Runs the script by its
         # shebang (/bin/bash, 3.2 on macOS), as the skill does — not PATH's bash.
    HOME="$SCRATCH/home" PATH="$STUB:$PATH" "$TARGET" "$@" > "$SCRATCH/out.log" 2>&1
}
PTY_RUN="$(cd "$SCRIPT_DIR/../lib" && pwd)/pty_run.py"
pty() {  # $1 = what the user types (empty, or lines ending in a newline), then a
         # command and its arguments, run with a pseudo-terminal as stdin, stdout
         # and stderr. out.log is removed first, so a case never reads the
         # previous case's log.
    rm -f "$SCRATCH/out.log"
    HOME="$SCRATCH/home" PATH="$STUB:$PATH" PYTHONDONTWRITEBYTECODE=1 python3 "$PTY_RUN" "$SCRATCH/out.log" "$@"
}
run_pty() {  # $1 = what the user types, then script arguments
    local typed="$1"; shift
    pty "$typed" "$TARGET" "$@"
}
ok()   { echo "  ✓ $1"; PASSED=$((PASSED + 1)); }
bad()  { echo "  ✗ $1"; sed 's/^/      /' "$SCRATCH/out.log"; FAILED=$((FAILED + 1)); }
clicks() { cat "$SCRATCH/clicks.log" 2>/dev/null | grep -v '^p$' || true; }

expect_rejected() {  # $1 name, then script args; the run must fail, run no payload, click nothing
    local name="$1"; shift
    run "$@"; local rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "$MARK" ] && [ -z "$(clicks)" ]; then ok "$name"
    else bad "$name (exit $rc, payload ran: $([ -e "$MARK" ] && echo yes || echo no), clicks: $(clicks | tr '\n' ' '))"; fi
}

# load_config strips spaces (tr -d ' ') and stops at the first , or }, so the
# payload uses an unbraced $IFS for the space. (A ${IFS} payload is cut off at
# its } by that grep, which hides the bug instead of testing it.)
PAYLOAD="a[\$(touch\$IFS$MARK)]"
# Positive control: the payload must really run a command when bash does
# arithmetic on it here, or every payload case below would pass vacuously
# (e.g. a scratch path with a character that cuts the payload short).
# Run it in a fresh shell with the script's own interpreter (its shebang), as
# the script runs: this file uses `set -u`, under which bash stops at the unset
# array `a` before it evaluates the subscript, so an in-process check would
# report a live payload as dead.
SHEBANG_BASH=$(head -1 "$TARGET" | sed 's/^#! *//')
"$SHEBANG_BASH" -c 'v="$1"; : $((v))' _ "$PAYLOAD" 2>/dev/null
if [ -e "$MARK" ]; then rm -f "$MARK"
else echo "✗ positive control: the payload does not run in this environment ($MARK) — payload cases would be vacuous"; exit 1; fi
[ -x "$TARGET" ] || { echo "✗ $TARGET is not executable"; exit 1; }
# Positive control for run_pty: the command must see a terminal on stdin and
# read the typed lines in order, then end of input. Otherwise the calibrate
# cases below would stop at its terminal check and test nothing they name.
python3 "$PTY_RUN" "$SCRATCH/out.log" $'\n250\n' "$SHEBANG_BASH" -c \
    '[ -t 0 ] || exit 3; read -r a || exit 4; read -r b || exit 5; [ -z "$a" ] && [ "$b" = 250 ] || exit 6; read -r c && exit 7; exit 0'
rc=$?
[ "$rc" -eq 0 ] || { echo "✗ positive control: run_pty does not give a terminal that delivers the typed lines (exit $rc)"; cat "$SCRATCH/out.log" 2>/dev/null; exit 1; }

echo "test-config-validation.sh (#149, che-msg#52)"

# ---- valid config: save and test click where expected ----
reset; write_config -20 30 240
run save; rc=$?
if [ "$rc" -eq 0 ] && [ "$(clicks | tr '\n' ' ')" = "c:880,130 c:880,370 " ]; then ok "valid config: save clicks ⋮ and the menu item"
else bad "valid config: save (exit $rc, clicks: $(clicks | tr '\n' ' '))"; fi
reset; write_config -20 30 240
run test; rc=$?
if [ "$rc" -eq 0 ] && [ "$(clicks | tr '\n' ' ')" = "c:880,130 " ]; then ok "valid config: test clicks ⋮ only"
else bad "valid config: test (exit $rc, clicks: $(clicks | tr '\n' ' '))"; fi
reset; write_config -20 30 ""
run save; rc=$?
if [ "$rc" -eq 0 ] && [ "$(clicks | tr '\n' ' ')" = "c:880,130 c:880,370 " ]; then ok "menu_offset_y missing: defaults to 240"
else bad "menu_offset_y missing (exit $rc, clicks: $(clicks | tr '\n' ' '))"; fi

# ---- read side: every value that reaches $((…)) ----
reset; write_config "$PAYLOAD" 30 240;  expect_rejected "offset_x payload (save)" save
reset; write_config "$PAYLOAD" 30 240;  expect_rejected "offset_x payload (test)" test
reset; write_config -20 "$PAYLOAD" 240; expect_rejected "offset_y payload (save)" save
reset; write_config -20 "$PAYLOAD" 240; expect_rejected "offset_y payload (test)" test
reset; write_config -20 30 "$PAYLOAD";  expect_rejected "menu_offset_y payload (save)" save
reset; write_config -20 30 "x+1";       expect_rejected "expression instead of a number" save
reset; write_config -20 30 "010";       expect_rejected "leading zero (bash reads it as octal)" save
reset; write_config -20 30 "1234567";   expect_rejected "more than six digits" save

# A key that appears twice: grep returns both lines, and is_int must reject the
# pair as a whole (a per-line check would accept the valid second line).
reset; write_config -20 30 240; printf '{\n  "offset_x": %s,\n  "offset_x": -20,\n  "offset_y": 30\n}\n' "$PAYLOAD" > "$CONFIG"
expect_rejected "duplicate key: payload line then a valid line (save)" save
reset; write_config -20 30 240; printf '{\n  "offset_x": %s,\n  "offset_x": -20,\n  "offset_y": 30\n}\n' "$PAYLOAD" > "$CONFIG"
expect_rejected "duplicate key: payload line then a valid line (test)" test
# menu_offset_y present but unreadable must stop, not fall back to 240
reset; write_config -20 30 " ";         expect_rejected "menu_offset_y present but empty" save
reset; write_config -20 30 240; printf '{\n  "offset_x": -20,\n  "offset_y": 30,\n  "menu_offset_y":\n    300,\n  "description": "x"\n}\n' > "$CONFIG"
expect_rejected "menu_offset_y value on the next line (grep cannot read it)" save

# ---- values from osascript and cliclick reach $((…)) too ----
reset; write_config -20 30 240
export STUB_WINDOW="$PAYLOAD 100 800 600"; expect_rejected "window x from osascript is a payload" save; unset STUB_WINDOW
reset; write_config -20 30 240
export STUB_WINDOW="100 $PAYLOAD 800 600"; expect_rejected "window y from osascript is a payload" test; unset STUB_WINDOW
reset; write_config -20 30 240
export STUB_WINDOW="100 100 $PAYLOAD 600"; expect_rejected "window width from osascript is a payload" save; unset STUB_WINDOW
reset; write_config -20 30 240
export STUB_WINDOW=" "; expect_rejected "blank window info (test)" test; unset STUB_WINDOW
# Real osascript exits 1 when LINE has no window: each command must say so,
# not end silently under set -e.
for cmd in save test; do
    reset; write_config -20 30 240
    export STUB_OSA_FAIL=1; run "$cmd"; rc=$?; unset STUB_OSA_FAIL
    if [ "$rc" -ne 0 ] && [ -z "$(clicks)" ] && grep -q '無法取得 LINE 視窗資訊' "$SCRATCH/out.log"; then ok "no LINE window ($cmd): reports it, clicks nothing"
    else bad "no LINE window ($cmd) (exit $rc, clicks: $(clicks | tr '\n' ' '))"; fi
done
reset
export STUB_OSA_FAIL=1; run_pty $'\n\n' calibrate; rc=$?; unset STUB_OSA_FAIL
if [ "$rc" -ne 0 ] && [ ! -e "$CONFIG" ] && grep -q '無法取得 LINE 視窗資訊' "$SCRATCH/out.log"; then ok "no LINE window (calibrate): reports it, writes nothing"
else bad "no LINE window (calibrate) (exit $rc)"; fi

# ---- messages: a bad config is not reported as "not calibrated" ----
reset; write_config -20 30 "x+1"; run save
if grep -q '整數' "$SCRATCH/out.log" && ! grep -q '尚未校準' "$SCRATCH/out.log"; then ok "invalid config: one message, not \"not calibrated\""
else bad "invalid config message"; fi
reset; run save
if grep -q '尚未校準' "$SCRATCH/out.log"; then ok "missing config: \"not calibrated\""
else bad "missing config message"; fi

# ---- write side: calibrate stores only integers ----
# Each rejection also checks its own message, so a case cannot pass by stopping
# earlier for another reason (such as the terminal check).
reset
run_pty $'\n'"$PAYLOAD"$'\n' calibrate; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$CONFIG" ] && [ ! -e "$MARK" ] && grep -q '請輸入整數像素值' "$SCRATCH/out.log"; then ok "calibrate refuses a non-integer menu offset and writes nothing"
else bad "calibrate payload (exit $rc, config written: $([ -e "$CONFIG" ] && echo yes || echo no))"; fi
reset
export STUB_POS="500,$PAYLOAD"
run_pty $'\n250\n' calibrate; rc=$?
unset STUB_POS
if [ "$rc" -ne 0 ] && [ ! -e "$CONFIG" ] && [ ! -e "$MARK" ] && grep -q '無法取得滑鼠位置' "$SCRATCH/out.log"; then ok "calibrate refuses a cursor y that is not an integer"
else bad "calibrate cursor-y payload (exit $rc)"; fi
reset
export STUB_POS="$PAYLOAD,300"
run_pty $'\n250\n' calibrate; rc=$?
unset STUB_POS
if [ "$rc" -ne 0 ] && [ ! -e "$CONFIG" ] && [ ! -e "$MARK" ] && grep -q '無法取得滑鼠位置' "$SCRATCH/out.log"; then ok "calibrate refuses a cursor position that is not an integer"
else bad "calibrate cursor payload (exit $rc, config written: $([ -e "$CONFIG" ] && echo yes || echo no), payload ran: $([ -e "$MARK" ] && echo yes || echo no))"; fi
reset
run_pty $'\n250\n' calibrate; rc=$?
# The activate check is also the positive control for the osascript log, which
# the terminal cases below expect to stay empty.
if [ "$rc" -eq 0 ] && grep -q '"menu_offset_y": 250,' "$CONFIG" && grep -q '"offset_x": -400,' "$CONFIG" && grep -q '"offset_y": 200,' "$CONFIG" \
    && grep -q 'tell application "LINE" to activate' "$SCRATCH/osascript.log"
then ok "calibrate stores the computed offsets and a typed menu offset"
else bad "calibrate valid (exit $rc): $(tr '\n' ' ' < "$CONFIG" 2>/dev/null)"; fi
reset
run_pty $'\n\n' calibrate; rc=$?
if [ "$rc" -eq 0 ] && grep -q '"menu_offset_y": 240,' "$CONFIG"; then ok "calibrate: an empty menu offset stores the default 240"
else bad "calibrate empty (exit $rc): $(tr '\n' ' ' < "$CONFIG" 2>/dev/null)"; fi

# ---- calibrate needs an interactive terminal (PsychQuant/che-msg#52) ----
# Without one, the Enter prompt either hit end of input and ended silently
# under set -e, or, with two lines piped in, recorded wherever the mouse was
# and overwrote a good calibration. It must stop before bringing LINE forward.
unchanged() { cmp -s "$CONFIG" "$SCRATCH/before.json"; }
untouched() { [ ! -e "$SCRATCH/osascript.log" ] && [ ! -e "$SCRATCH/clicks.log" ]; }
reset; write_config -40 30 240; cp "$CONFIG" "$SCRATCH/before.json"
run calibrate < /dev/null; rc=$?
if [ "$rc" -ne 0 ] && unchanged && untouched && grep -q '互動式終端機' "$SCRATCH/out.log"; then ok "calibrate < /dev/null: says it needs a terminal, LINE not activated, config unchanged"
else bad "calibrate < /dev/null (exit $rc, config unchanged: $(unchanged && echo yes || echo no), osascript ran: $([ -e "$SCRATCH/osascript.log" ] && echo yes || echo no))"; fi
reset; write_config -40 30 240; cp "$CONFIG" "$SCRATCH/before.json"
export STUB_POS="5,5"; printf '\n\n' | run calibrate; rc=$?; unset STUB_POS
if [ "$rc" -ne 0 ] && unchanged && untouched && grep -q '互動式終端機' "$SCRATCH/out.log"; then ok "calibrate with two lines piped in: same, the calibration is not overwritten"
else bad "calibrate piped (exit $rc, config unchanged: $(unchanged && echo yes || echo no), osascript ran: $([ -e "$SCRATCH/osascript.log" ] && echo yes || echo no)): $(tr '\n' ' ' < "$CONFIG")"; fi
# stdin a pipe while stdout and stderr are a terminal, as in `printf '\n\n' |
# calibrate` typed at a terminal: the check must be on stdin, not on output.
reset; write_config -40 30 240; cp "$CONFIG" "$SCRATCH/before.json"
pty '' "$SHEBANG_BASH" -c 'printf "\n\n" | "$1" calibrate' _ "$TARGET"; rc=$?
if [ "$rc" -ne 0 ] && unchanged && untouched && grep -q '互動式終端機' "$SCRATCH/out.log"; then ok "calibrate with a pipe on stdin and a terminal on stdout: refused the same way"
else bad "calibrate, pipe on stdin, terminal on stdout (exit $rc, config unchanged: $(unchanged && echo yes || echo no), osascript ran: $([ -e "$SCRATCH/osascript.log" ] && echo yes || echo no))"; fi
reset
printf '\n250\n' | run calibrate; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$CONFIG" ] && untouched && grep -q '互動式終端機' "$SCRATCH/out.log"; then ok "calibrate piped, no config yet: none is written"
else bad "calibrate piped, no config (exit $rc, config written: $([ -e "$CONFIG" ] && echo yes || echo no))"; fi
# help is pre-approved and is where a user looks first.
reset; run help
if grep -- 'calibrate  -' "$SCRATCH/out.log" | grep -q '自己的終端機'; then ok "help: the calibrate line says to run it in your own terminal"
else bad "help: calibrate line ($(grep -- 'calibrate  -' "$SCRATCH/out.log"))"; fi
# At a terminal, input can still end (Ctrl-D): each prompt must say so, not
# end silently under set -e.
reset; write_config -40 30 240; cp "$CONFIG" "$SCRATCH/before.json"
run_pty '' calibrate; rc=$?
if [ "$rc" -ne 0 ] && unchanged && grep -q '輸入已結束，沒有讀到 Enter' "$SCRATCH/out.log"; then ok "calibrate: input ends at the Enter prompt: says so, config unchanged"
else bad "calibrate, end of input at Enter (exit $rc, config unchanged: $(unchanged && echo yes || echo no))"; fi
reset; write_config -40 30 240; cp "$CONFIG" "$SCRATCH/before.json"
run_pty $'\n' calibrate; rc=$?
if [ "$rc" -ne 0 ] && unchanged && grep -q '輸入已結束，沒有讀到選單位移' "$SCRATCH/out.log"; then ok "calibrate: input ends at the menu offset prompt: says so, config unchanged"
else bad "calibrate, end of input at the menu offset (exit $rc, config unchanged: $(unchanged && echo yes || echo no))"; fi
# The cursor must be inside the LINE window (stub: x 100..899, y 100..699).
# 5,5 is the position the diagnosis reproduced the overwrite with; the others
# are one pixel outside each edge.
for pos in 5,5 99,300 900,300 500,99 500,700; do
    reset; write_config -40 30 240; cp "$CONFIG" "$SCRATCH/before.json"
    export STUB_POS="$pos"; run_pty $'\n250\n' calibrate; rc=$?; unset STUB_POS
    if [ "$rc" -ne 0 ] && unchanged && grep -q '不在 LINE 視窗內' "$SCRATCH/out.log"; then ok "calibrate: cursor at $pos is outside the window: says so, config unchanged"
    else bad "calibrate, cursor at $pos (exit $rc, config unchanged: $(unchanged && echo yes || echo no)): $(tr '\n' ' ' < "$CONFIG")"; fi
done
# The window's own corner pixels are inside.
reset; export STUB_POS="100,100"; run_pty $'\n\n' calibrate; rc=$?; unset STUB_POS
if [ "$rc" -eq 0 ] && grep -q '"offset_x": -800,' "$CONFIG" && grep -q '"offset_y": 0,' "$CONFIG"; then ok "calibrate: cursor on the window's top-left pixel is accepted"
else bad "calibrate, cursor at 100,100 (exit $rc): $(tr '\n' ' ' < "$CONFIG" 2>/dev/null)"; fi
reset; export STUB_POS="899,699"; run_pty $'\n\n' calibrate; rc=$?; unset STUB_POS
if [ "$rc" -eq 0 ] && grep -q '"offset_x": -1,' "$CONFIG" && grep -q '"offset_y": 599,' "$CONFIG"; then ok "calibrate: cursor on the window's bottom-right pixel is accepted"
else bad "calibrate, cursor at 899,699 (exit $rc): $(tr '\n' ' ' < "$CONFIG" 2>/dev/null)"; fi

echo
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
