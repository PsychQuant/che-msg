#!/bin/bash
# Regression test for PsychQuant/che-msg#53: without cliclick, the actions
# that only print (help, --help, -h, no argument, an unknown action) still
# work, and only the actions that click (calibrate, save, test) stop with
# "brew install cliclick".
#
# line-save-chat.sh checked for cliclick before reading the action, so `help`
# (which the skill pre-approves) failed with exit 1 and showed only the
# install hint, not the steps, the config location or the Accessibility note.
#
# PATH is a stub directory plus /usr/bin:/bin, where cliclick does not exist
# (the script checks with `command -v`). The stub osascript only records that
# it ran, so nothing on screen is touched, and HOME points at a scratch
# directory so the real config under ~/.config/che-archive-lines is never read.
#
# Usage:
#   bash tests/che-archive-lines/test-missing-cliclick.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "$SCRIPT_DIR/../../plugins/che-archive-lines/scripts" && pwd)/line-save-chat.sh"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/archive-lines-nocliclick-XXXXXX") || { echo "✗ mktemp failed" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "✗ scratch dir missing" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

STUB="$SCRATCH/stub"
mkdir -p "$STUB" "$SCRATCH/home"
cat > "$STUB/osascript" <<EOF
#!/bin/bash
echo "\$*" >> "$SCRATCH/osascript.log"
exit 0
EOF
chmod +x "$STUB/osascript"
STUB_PATH="$STUB:/usr/bin:/bin"

if PATH="$STUB_PATH" command -v cliclick >/dev/null 2>&1; then
    echo "✗ cliclick is on $STUB_PATH; this test needs a PATH without it" >&2
    exit 1
fi

PASSED=0
FAILED=0
ok()  { echo "  ✓ $1"; PASSED=$((PASSED + 1)); }
bad() { echo "  ✗ $1"; sed 's/^/      /' "$SCRATCH/out.log"; FAILED=$((FAILED + 1)); }
run() {  # $@ = script arguments. Runs the script by its shebang, as the skill does.
    rm -f "$SCRATCH/osascript.log"
    HOME="$SCRATCH/home" PATH="$STUB_PATH" "$TARGET" "$@" < /dev/null > "$SCRATCH/out.log" 2>&1
}
has()     { grep -q -- "$1" "$SCRATCH/out.log"; }
no_osa()  { [ ! -e "$SCRATCH/osascript.log" ]; }

# ---- actions that only print work without cliclick ----
for args in help --help -h ""; do
    label="${args:-(no argument)}"
    if [ -n "$args" ]; then run "$args"; else run; fi; rc=$?
    if [ "$rc" -eq 0 ] && has '設定檔位置' && has 'calibrate' && ! has '找不到 cliclick'; then
        ok "$label: shows the help and exits 0"
    else
        bad "$label (exit $rc)"
    fi
done

run frobnicate; rc=$?
if [ "$rc" -eq 1 ] && has '未知的操作' && has '設定檔位置' && ! has '找不到 cliclick'; then
    ok "unknown action: names it, shows the help, exits 1, no dependency error"
else
    bad "unknown action (exit $rc)"
fi

# ---- actions that click still stop first, before the config and before osascript ----
for action in calibrate save test; do
    run "$action"; rc=$?
    if [ "$rc" -ne 0 ] && has 'brew install cliclick' && ! has '尚未校準' && no_osa; then
        ok "$action: stops with the install hint before anything else"
    else
        bad "$action (exit $rc, osascript ran: $(no_osa && echo no || echo yes))"
    fi
done

echo
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
