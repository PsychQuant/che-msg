#!/bin/bash
# Smoke test for wrapper PID tracking (#8)
#
# Tests:
#   1. Orphan cleanup: if PID file points to a live process matching BINARY_NAME,
#      wrapper should kill it before starting new instance.
#   2. PID file maintenance: new process's PID is written to PID file.
#   3. Cleanup on exit: PID file removed when wrapper exits normally.
#   4. PID recycling protection: if PID is alive but different command,
#      wrapper should NOT kill it.
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-pid.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
TOTAL=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

# Extract the PID-tracking block from a wrapper into a standalone executable,
# substituting BINARY with a fake sleep command and PID_FILE with a temp path.
# This lets us test the logic without running the real MCP server.
make_fake_wrapper() {
    local out=$1
    local pid_file=$2
    local binary_name=$3
    local sleep_duration=$4

    cat > "$out" <<EOF
#!/bin/bash
BINARY_NAME="$binary_name"
BINARY="/bin/sleep"
PID_FILE="$pid_file"
mkdir -p "\$(dirname "\$PID_FILE")"

if [[ -f "\$PID_FILE" ]]; then
    OLD_PID=
    read -r OLD_PID < "\$PID_FILE" 2>/dev/null || true
    if [[ "\$OLD_PID" =~ ^[0-9]+\$ ]] && kill -0 "\$OLD_PID" 2>/dev/null; then
        OLD_COMM=\$(ps -p "\$OLD_PID" -o comm= 2>/dev/null)
        OLD_BASENAME=\$(basename "\$OLD_COMM" 2>/dev/null)
        if [[ "\$OLD_BASENAME" == "\$BINARY_NAME" ]]; then
            kill -TERM "\$OLD_PID" 2>/dev/null
            for _ in 1 2 3 4; do
                kill -0 "\$OLD_PID" 2>/dev/null || break
                sleep 0.5
            done
            kill -0 "\$OLD_PID" 2>/dev/null && kill -KILL "\$OLD_PID" 2>/dev/null
        fi
    fi
fi

"\$BINARY" $sleep_duration <&0 &
BIN_PID=\$!
echo "\$BIN_PID" > "\$PID_FILE"

cleanup() {
    if [[ -n "\$BIN_PID" ]] && kill -0 "\$BIN_PID" 2>/dev/null; then
        kill -TERM "\$BIN_PID" 2>/dev/null
        for _ in 1 2 3 4; do
            kill -0 "\$BIN_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -0 "\$BIN_PID" 2>/dev/null && kill -KILL "\$BIN_PID" 2>/dev/null
        wait "\$BIN_PID" 2>/dev/null
    fi
    if [[ -f "\$PID_FILE" ]]; then
        CURRENT_PID=
        read -r CURRENT_PID < "\$PID_FILE" 2>/dev/null || true
        [[ "\$CURRENT_PID" == "\$BIN_PID" ]] && rm -f "\$PID_FILE"
    fi
}
trap cleanup EXIT INT TERM

wait "\$BIN_PID"
exit \$?
EOF
    chmod +x "$out"
}

# Helper: poll for condition with timeout (avoids timing races)
# Uses `ps -o state=` to detect zombies (Z state) as "dead", since `kill -0`
# returns success for zombies (process exists but is un-reaped). After detecting
# death, attempts to reap via `wait` so subsequent checks see the PID gone.
wait_for_dead() {
    local pid=$1
    local max_tenths=${2:-30}  # default 3s
    local i=0
    while [[ $i -lt $max_tenths ]]; do
        local state
        state=$(ps -p "$pid" -o state= 2>/dev/null | tr -d ' ')
        # Treat missing process OR zombie as "dead"
        if [[ -z "$state" ]] || [[ "$state" == Z* ]]; then
            wait "$pid" 2>/dev/null  # reap if we're the parent
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

wait_for_file() {
    local path=$1
    local max_tenths=${2:-30}
    local i=0
    while [[ $i -lt $max_tenths ]]; do
        [[ -f "$path" ]] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

# ----------------------------------------------------------------------
# Test 0: stdin inheritance — critical for MCP stdio protocol
# POSIX rule: in non-interactive shell, `cmd &` redirects stdin to /dev/null
# unless explicitly overridden with `<&0`. Using `/bin/sleep` as fake binary
# never exercises this path; we need a binary that actually reads stdin.
test_case "Wrapper inherits stdin to backgrounded binary (POSIX & rule)"
PID_FILE="$TMPDIR/test0.pid"
OUT_FILE="$TMPDIR/test0.out"

# Build a minimal wrapper that mimics the production stdin-inheritance path
cat > "$TMPDIR/wrapper0.sh" <<EOF
#!/bin/bash
PID_FILE="$PID_FILE"
/bin/cat > "$OUT_FILE" <&0 &
BIN_PID=\$!
echo "\$BIN_PID" > "\$PID_FILE"
wait "\$BIN_PID"
EOF
chmod +x "$TMPDIR/wrapper0.sh"

echo "MCP_STDIN_TEST_PAYLOAD" | "$TMPDIR/wrapper0.sh"
if [[ "$(cat "$OUT_FILE" 2>/dev/null)" == "MCP_STDIN_TEST_PAYLOAD" ]]; then
    pass "stdin inherited via <&0 (bug from commit 06015c9 blocked)"
else
    fail "stdin NOT inherited — POSIX & rule redirected to /dev/null (MCP stdio would break)"
fi

# ----------------------------------------------------------------------
test_case "PID file created on start, removed on clean exit"
PID_FILE="$TMPDIR/test1.pid"
make_fake_wrapper "$TMPDIR/wrapper1.sh" "$PID_FILE" "sleep" "3"
"$TMPDIR/wrapper1.sh" &
WRAPPER_PID=$!
if wait_for_file "$PID_FILE" 30; then
    pass "PID file created"
else
    fail "PID file missing during run"
fi
wait "$WRAPPER_PID"
if [[ ! -f "$PID_FILE" ]]; then
    pass "PID file removed after exit"
else
    fail "PID file still exists after exit"
fi

# ----------------------------------------------------------------------
test_case "Orphan process killed on startup"
PID_FILE="$TMPDIR/test2.pid"
# Start an orphan "sleep" process matching BINARY_NAME
/bin/sleep 30 &
ORPHAN_PID=$!
echo "$ORPHAN_PID" > "$PID_FILE"
sleep 0.1
if kill -0 "$ORPHAN_PID" 2>/dev/null; then
    pass "orphan started (PID $ORPHAN_PID)"
else
    fail "orphan setup failed"
fi

make_fake_wrapper "$TMPDIR/wrapper2.sh" "$PID_FILE" "sleep" "3"
"$TMPDIR/wrapper2.sh" &
WRAPPER_PID=$!
# Poll up to 4s for orphan to be killed (wrapper uses SIGTERM + up to 2s wait + SIGKILL)
if wait_for_dead "$ORPHAN_PID" 40; then
    pass "orphan killed by wrapper"
else
    fail "orphan survived wrapper startup (PID $ORPHAN_PID still alive)"
    kill -KILL "$ORPHAN_PID" 2>/dev/null
fi
wait "$WRAPPER_PID" 2>/dev/null

# ----------------------------------------------------------------------
test_case "PID recycling protection (PID alive but wrong command)"
PID_FILE="$TMPDIR/test3.pid"
# Start a long-lived process NOT matching BINARY_NAME
# tail -f /dev/null sits forever; comm name basename = "tail"
/usr/bin/tail -f /dev/null &
UNRELATED_PID=$!
echo "$UNRELATED_PID" > "$PID_FILE"
sleep 0.2
if ! kill -0 "$UNRELATED_PID" 2>/dev/null; then
    fail "unrelated process setup failed (tail died unexpectedly)"
fi

# Wrapper looks for "sleep" as BINARY_NAME, but PID points to "tail"
make_fake_wrapper "$TMPDIR/wrapper3.sh" "$PID_FILE" "sleep" "3"
"$TMPDIR/wrapper3.sh" &
WRAPPER_PID=$!
# Wait long enough to be sure wrapper's check phase has completed (>= 4s would cover SIGTERM + SIGKILL paths)
sleep 1
if kill -0 "$UNRELATED_PID" 2>/dev/null; then
    pass "unrelated process NOT killed (PID recycling protection works)"
else
    fail "unrelated process was killed (PID recycling protection failed)"
fi
kill -TERM "$UNRELATED_PID" 2>/dev/null
wait "$WRAPPER_PID" 2>/dev/null
wait "$UNRELATED_PID" 2>/dev/null

# ----------------------------------------------------------------------
test_case "Stale PID file (process already dead)"
PID_FILE="$TMPDIR/test4.pid"
# Write a PID that's guaranteed not to exist (very high number)
echo "99999" > "$PID_FILE"

make_fake_wrapper "$TMPDIR/wrapper4.sh" "$PID_FILE" "sleep" "3"
"$TMPDIR/wrapper4.sh" &
WRAPPER_PID=$!
# Poll for file content to change
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    NEW_PID=$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$NEW_PID" && "$NEW_PID" != "99999" ]] && break
    sleep 0.1
done
if [[ -f "$PID_FILE" ]]; then
    NEW_PID=$(cat "$PID_FILE" | tr -d '[:space:]')
    if [[ "$NEW_PID" != "99999" ]] && [[ -n "$NEW_PID" ]] && kill -0 "$NEW_PID" 2>/dev/null; then
        pass "stale PID replaced with live PID ($NEW_PID)"
    else
        fail "stale PID not handled correctly (got '$NEW_PID')"
    fi
else
    fail "PID file missing during run"
fi
wait "$WRAPPER_PID" 2>/dev/null

# ----------------------------------------------------------------------
test_case "Wrapper forwards SIGTERM to binary"
PID_FILE="$TMPDIR/test5.pid"
make_fake_wrapper "$TMPDIR/wrapper5.sh" "$PID_FILE" "sleep" "30"
"$TMPDIR/wrapper5.sh" &
WRAPPER_PID=$!
if ! wait_for_file "$PID_FILE" 30; then
    fail "PID file never created"
fi
BIN_PID=$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')
if [[ -z "$BIN_PID" ]]; then
    fail "could not read BIN_PID"
else
    kill -TERM "$WRAPPER_PID"
    if wait_for_dead "$BIN_PID" 40; then
        pass "binary terminated when wrapper received SIGTERM"
    else
        fail "binary survived wrapper SIGTERM (PID $BIN_PID still alive)"
        kill -KILL "$BIN_PID" 2>/dev/null
    fi
fi
wait "$WRAPPER_PID" 2>/dev/null

# ----------------------------------------------------------------------
test_case "Ownership check: wrapper does not delete PID file claimed by another wrapper"
PID_FILE="$TMPDIR/test6.pid"
make_fake_wrapper "$TMPDIR/wrapper6.sh" "$PID_FILE" "sleep" "3"
"$TMPDIR/wrapper6.sh" &
WRAPPER_A_PID=$!
wait_for_file "$PID_FILE" 30
A_BIN_PID=$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')

# Simulate: an old wrapper from previous session runs cleanup with stale BIN_PID
# (replicate the ownership-check logic; should NOT delete the file)
(
    BIN_PID="99998"
    if [[ -f "$PID_FILE" ]] && [[ "$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')" == "$BIN_PID" ]]; then
        rm -f "$PID_FILE"
    fi
)

if [[ -f "$PID_FILE" ]] && [[ "$(cat "$PID_FILE" | tr -d '[:space:]')" == "$A_BIN_PID" ]]; then
    pass "PID file preserved (ownership check blocked wrong owner)"
else
    fail "PID file was deleted or corrupted by wrong-owner cleanup"
fi
wait "$WRAPPER_A_PID" 2>/dev/null

# ----------------------------------------------------------------------
test_case "SIGKILL fallback: binary that ignores SIGTERM still gets killed"
PID_FILE="$TMPDIR/test7.pid"
# Stubborn binary structure (#11):
#   The previous version used `trap '' TERM; sleep 30`. Bash's trap ignores
#   SIGTERM correctly, but `sleep 30` is a CHILD process. SIGKILL of the bash
#   subshell killed bash but left sleep as an orphan adopted by launchd. The
#   test then "passed" by checking only the bash PID, missing the orphan.
#
#   Naive fix attempt: `read -t 30 < /dev/null`. DOES NOT WORK — /dev/null
#   returns EOF immediately, `read` returns exit=1 in ~1ms regardless of -t.
#   Verified: stubborn binary would exit before wrapper even sent SIGTERM,
#   making Test 7 a false positive.
#
#   Correct fix: block the bash main process on a FIFO with no writer.
#   Open-for-read on a FIFO without a writer blocks at the OS open()
#   syscall. `read -t` does NOT apply during open() (bash's read timeout
#   only applies once fd is open), so this effectively blocks forever
#   until SIGKILL arrives. No child fork.
#
#   Sentinel file ($STUBBORN_READY) is touched AFTER trap is set and
#   FIFO is created. Test harness waits for this sentinel before sending
#   SIGTERM, avoiding the race where bash hasn't installed trap yet
#   (verified by Codex during #11 verify round — without the sentinel,
#   SIGTERM sometimes killed bash before trap took effect).
STUBBORN_READY="$TMPDIR/stubborn-ready"
cat > "$TMPDIR/stubborn-binary.sh" <<STUBBORN
#!/bin/bash
trap '' TERM
FIFO="$TMPDIR/stubborn-fifo-\$\$"
if ! mkfifo "\$FIFO" 2>/dev/null; then
    echo "stubborn: mkfifo failed for \$FIFO" >&2
    exit 1
fi
# Cleanup FIFO on normal exit (SIGKILL won't run this; leftover FIFO is harmless)
trap 'rm -f "\$FIFO"' EXIT
# Sentinel: signals test harness that trap + FIFO are ready
touch "$STUBBORN_READY"
read < "\$FIFO" || true
STUBBORN
chmod +x "$TMPDIR/stubborn-binary.sh"

# Custom wrapper that uses stubborn binary
cat > "$TMPDIR/wrapper7.sh" <<EOF
#!/bin/bash
BINARY_NAME="stubborn-binary.sh"
BINARY="$TMPDIR/stubborn-binary.sh"
PID_FILE="$PID_FILE"

"\$BINARY" <&0 &
BIN_PID=\$!
echo "\$BIN_PID" > "\$PID_FILE"

cleanup() {
    if [[ -n "\$BIN_PID" ]] && kill -0 "\$BIN_PID" 2>/dev/null; then
        kill -TERM "\$BIN_PID" 2>/dev/null
        for _ in 1 2 3 4; do
            kill -0 "\$BIN_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -0 "\$BIN_PID" 2>/dev/null && kill -KILL "\$BIN_PID" 2>/dev/null
        wait "\$BIN_PID" 2>/dev/null
    fi
    if [[ -f "\$PID_FILE" ]]; then
        CURRENT_PID=
        read -r CURRENT_PID < "\$PID_FILE" 2>/dev/null || true
        [[ "\$CURRENT_PID" == "\$BIN_PID" ]] && rm -f "\$PID_FILE"
    fi
}
trap cleanup EXIT INT TERM

wait "\$BIN_PID"
EOF
chmod +x "$TMPDIR/wrapper7.sh"

"$TMPDIR/wrapper7.sh" &
WRAPPER_PID=$!
wait_for_file "$PID_FILE" 30
STUBBORN_PID=$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')

# CRITICAL: wait for stubborn binary to install its SIGTERM-ignore trap
# AND be blocked inside read < FIFO before sending SIGTERM. Otherwise
# bash dies on default SIGTERM handler and test becomes false positive.
if ! wait_for_file "$STUBBORN_READY" 30; then
    fail "stubborn binary failed to become ready"
fi

# Snapshot any children of stubborn binary BEFORE termination (for orphan check)
CHILDREN_BEFORE=$(pgrep -P "$STUBBORN_PID" 2>/dev/null | tr '\n' ' ')

# Tell wrapper to terminate; binary will ignore SIGTERM, wrapper should SIGKILL it
START_NS=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
kill -TERM "$WRAPPER_PID"
if wait_for_dead "$STUBBORN_PID" 50; then
    # Verify wrapper actually took the SIGKILL path (≥1.5s elapsed).
    # If it died quickly (<500ms), bash died before trap took effect,
    # meaning SIGKILL fallback was never exercised.
    wait "$WRAPPER_PID" 2>/dev/null
    END_NS=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
    ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
    if (( ELAPSED_MS < 1500 )); then
        fail "wrapper exited in ${ELAPSED_MS}ms — SIGKILL path not exercised (trap race?)"
    else
        pass "stubborn binary killed via SIGKILL fallback (${ELAPSED_MS}ms elapsed, SIGTERM-ignore verified)"
    fi
else
    fail "stubborn binary survived SIGKILL fallback"
    kill -KILL "$STUBBORN_PID" 2>/dev/null
fi

# Verify NO orphan children remain (#11)
ORPHAN_FOUND=
for child_pid in $CHILDREN_BEFORE; do
    if kill -0 "$child_pid" 2>/dev/null; then
        ORPHAN_FOUND="$child_pid"
        kill -KILL "$child_pid" 2>/dev/null
        break
    fi
done
if [[ -z "$ORPHAN_FOUND" ]]; then
    pass "no orphan children left after SIGKILL (process tree fully reaped)"
else
    fail "orphan child PID $ORPHAN_FOUND survived parent SIGKILL"
fi
wait "$WRAPPER_PID" 2>/dev/null

# ----------------------------------------------------------------------
test_case "Corrupted PID file with internal whitespace is rejected, not coalesced"
PID_FILE="$TMPDIR/test8.pid"
# Write corrupted content: "12 34" should NOT be parsed as PID 1234
echo "12 34" > "$PID_FILE"

make_fake_wrapper "$TMPDIR/wrapper8.sh" "$PID_FILE" "sleep" "2"
"$TMPDIR/wrapper8.sh" &
WRAPPER_PID=$!

# Poll until wrapper overwrites PID file with its own BIN_PID
NEW_CONTENT=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    NEW_CONTENT=$(cat "$PID_FILE" 2>/dev/null)
    [[ "$NEW_CONTENT" != "12 34" ]] && break
    sleep 0.1
done

if [[ "$NEW_CONTENT" == "1234" ]]; then
    fail "wrapper parsed '12 34' as '1234' (tr -d bug regressed)"
elif [[ "$NEW_CONTENT" =~ ^[0-9]+$ ]]; then
    pass "corrupted PID rejected, valid new PID written ($NEW_CONTENT)"
else
    fail "unexpected PID file content: '$NEW_CONTENT'"
fi
wait "$WRAPPER_PID" 2>/dev/null

# ----------------------------------------------------------------------
test_case "Atomic-claim lock: second instance fails fast, first instance survives (#10)"
LOCK_DIR="$TMPDIR/test9-lock"
LOCK_FILE="${LOCK_DIR}.flock"
PID_FILE="$TMPDIR/test9.pid"

# Build a wrapper that uses the same atomic-claim primitive as production
# (mkdir-based fallback path; works even on macOS without flock)
make_lock_wrapper() {
    local out=$1
    local sleep_duration=$2

    cat > "$out" <<EOF
#!/bin/bash
LOCK_DIR="$LOCK_DIR"
LOCK_FILE="${LOCK_FILE}"
LOCK_MODE=""
mkdir -p "\$(dirname "\$LOCK_DIR")"

if command -v flock >/dev/null 2>&1; then
    LOCK_MODE="flock"
    exec 200>"\$LOCK_FILE"
    if ! flock -n 200; then
        echo "Another instance is already running." >&2
        exit 1
    fi
else
    LOCK_MODE="mkdir"
    if ! mkdir "\$LOCK_DIR" 2>/dev/null; then
        OWNER_PID=
        [ -f "\$LOCK_DIR/owner.pid" ] && read -r OWNER_PID < "\$LOCK_DIR/owner.pid" 2>/dev/null
        if [[ "\$OWNER_PID" =~ ^[0-9]+\$ ]] && ! kill -0 "\$OWNER_PID" 2>/dev/null; then
            rm -rf "\$LOCK_DIR"
            mkdir "\$LOCK_DIR" 2>/dev/null || { echo "Failed to claim lock." >&2; exit 1; }
        else
            echo "Another instance is already running." >&2
            exit 1
        fi
    fi
    echo \$\$ > "\$LOCK_DIR/owner.pid"
fi

/bin/sleep $sleep_duration <&0 &
BIN_PID=\$!

cleanup() {
    if [[ -n "\$BIN_PID" ]] && kill -0 "\$BIN_PID" 2>/dev/null; then
        kill -TERM "\$BIN_PID" 2>/dev/null
        wait "\$BIN_PID" 2>/dev/null
    fi
    if [[ "\$LOCK_MODE" == "mkdir" ]] && [[ -d "\$LOCK_DIR" ]]; then
        OWNER_PID=
        [ -f "\$LOCK_DIR/owner.pid" ] && read -r OWNER_PID < "\$LOCK_DIR/owner.pid" 2>/dev/null
        [[ "\$OWNER_PID" == "\$\$" ]] && rm -rf "\$LOCK_DIR"
    fi
}
trap cleanup EXIT INT TERM
wait "\$BIN_PID"
EOF
    chmod +x "$out"
}

make_lock_wrapper "$TMPDIR/wrapper9a.sh" "3"
make_lock_wrapper "$TMPDIR/wrapper9b.sh" "3"

# Start first instance — should claim lock and run
"$TMPDIR/wrapper9a.sh" &
W9A_PID=$!
# Wait for lock to be claimed
LOCK_CLAIMED=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [[ -d "$LOCK_DIR" ]] || [[ -f "$LOCK_FILE" ]]; then
        LOCK_CLAIMED=1
        break
    fi
    sleep 0.05
done

if [[ "$LOCK_CLAIMED" != 1 ]]; then
    fail "first wrapper failed to claim lock"
    kill -TERM "$W9A_PID" 2>/dev/null
    wait "$W9A_PID" 2>/dev/null
else
    # Start second instance — should fail-fast with "already running"
    SECOND_OUT="$TMPDIR/test9-second.stderr"
    "$TMPDIR/wrapper9b.sh" 2>"$SECOND_OUT"
    SECOND_EXIT=$?

    if [[ "$SECOND_EXIT" -eq 1 ]] && grep -q "already running" "$SECOND_OUT"; then
        pass "second instance fail-fast (exit=1, stderr contains 'already running')"
    else
        fail "second instance behavior unexpected (exit=$SECOND_EXIT, stderr=$(cat "$SECOND_OUT"))"
    fi

    # First instance should still be alive
    if kill -0 "$W9A_PID" 2>/dev/null; then
        pass "first instance survived second-instance attempt (no SIGTERM cross-fire)"
    else
        fail "first instance died unexpectedly"
    fi

    # Cleanup
    kill -TERM "$W9A_PID" 2>/dev/null
    wait "$W9A_PID" 2>/dev/null
fi

# ----------------------------------------------------------------------
echo ""
echo "Results: $((TOTAL - FAIL))/$TOTAL passed"
exit $FAIL
