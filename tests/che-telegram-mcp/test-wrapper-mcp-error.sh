#!/bin/bash
# Smoke test for wrapper MCP-shaped JSON-RPC error emission (#31).
#
# Tests that the lock-refused branches of che-telegram-all-mcp-wrapper.sh
# emit a valid JSON-RPC 2.0 error envelope to stdout (in addition to the
# existing stderr message), so Claude Code's MCP client can surface a
# human-readable error message instead of generic -32000.
#
# Tests:
#   1. test_happy_path_no_lock        : no lock → wrapper forks fake binary OK
#   2. test_lock_refused_emits_valid_json : alive PID lock → stdout first line
#      is valid JSON-RPC 2.0 error with code=-32000, non-trivial message
#   3. test_stale_lock_self_recovery  : dead-PID lock → stale-cleanup runs +
#      wrapper forks fake binary
#   4. test_json_data_includes_recovery_command : emitted JSON .error.data
#      .recoveryCommand starts with "pkill"
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-mcp-error.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../../plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh"
if [ ! -f "$WRAPPER" ]; then
    echo "✗ wrapper not found: $WRAPPER" >&2
    exit 1
fi
FAIL=0
TOTAL=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

# Verify jq is available — required for JSON validation.
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for these tests. Install via 'brew install jq'." >&2
    exit 1
fi

# Extract the atomic-claim lock block from the wrapper into a standalone
# executable so we can test lock-refusal behavior without spawning the real
# binary or touching real Telegram credentials. The fake wrapper takes the
# same env-var inputs as the real one (LOCK_DIR / PID_FILE paths overridden).
make_fake_wrapper() {
    local out=$1
    local lock_dir=$2
    local pid_file=$3
    local binary_name=$4

    cat > "$out" <<FAKE_EOF
#!/bin/bash
# Fake wrapper extracting just the lock-claim logic from
# che-telegram-all-mcp-wrapper.sh, with the real binary replaced by /bin/sleep.

set -u
BINARY_NAME="$binary_name"
BINARY="/bin/sleep"
LOCK_DIR="$lock_dir"
LOCK_FILE="\${LOCK_DIR}.flock"
LOCK_MODE=""
PID_FILE="$pid_file"

mkdir -p "\$(dirname "\$LOCK_DIR")"
mkdir -p "\$(dirname "\$PID_FILE")"

# Source the helpers from the real wrapper. read_initialize_id (PR-1b) reads
# stdin briefly to extract the JSON-RPC initialize id so the response can be
# matched by Claude Code's MCP client. emit_mcp_error_response writes the
# JSON envelope. Falls back to no-op stubs if helpers aren't defined yet —
# this lets RED test phase work before helpers are added.
read_initialize_id() {
    printf 'null'   # no-op stub — overridden if real helper exists
}
emit_mcp_error_response() {
    : # no-op stub — overridden if real helper exists
}

if grep -q '^read_initialize_id' "$WRAPPER" 2>/dev/null; then
    # shellcheck disable=SC1090
    eval "\$(sed -n '/^read_initialize_id()/,/^}\$/p' "$WRAPPER")"
fi
if grep -q '^emit_mcp_error_response' "$WRAPPER" 2>/dev/null; then
    # shellcheck disable=SC1090
    eval "\$(sed -n '/^emit_mcp_error_response()/,/^}\$/p' "$WRAPPER")"
fi

# Mirror the real wrapper's atomic-claim block. Force mkdir mode (skip flock
# branch) so tests are deterministic across machines with/without flock.
if ! mkdir "\$LOCK_DIR" 2>/dev/null; then
    OWNER_PID=
    [ -f "\$LOCK_DIR/owner.pid" ] && read -r OWNER_PID < "\$LOCK_DIR/owner.pid" 2>/dev/null
    if [[ "\$OWNER_PID" =~ ^[0-9]+\$ ]] && ! kill -0 "\$OWNER_PID" 2>/dev/null; then
        rm -rf "\$LOCK_DIR"
        mkdir "\$LOCK_DIR" 2>/dev/null || {
            echo "\$BINARY_NAME: Failed to claim lock (stale-cleanup race). Retry shortly." >&2
            exit 1
        }
    else
        # PR-1b: read initialize id from stdin so MCP client matches the response.
        REQ_ID=\$(read_initialize_id)
        emit_mcp_error_response "\${OWNER_PID:-0}" "\$REQ_ID"
        echo "\$BINARY_NAME: Another instance is already running (lock held by PID \${OWNER_PID:-?}). Use the existing Claude Code window, or kill the previous wrapper first." >&2
        exit 1
    fi
fi
echo \$\$ > "\$LOCK_DIR/owner.pid"

# Mimic the real wrapper: fork BINARY with sleep duration arg.
"\$BINARY" 1 <&0 &
BIN_PID=\$!
echo "\$BIN_PID" > "\$PID_FILE"

cleanup() {
    if [[ -n "\$BIN_PID" ]] && kill -0 "\$BIN_PID" 2>/dev/null; then
        kill -TERM "\$BIN_PID" 2>/dev/null
        wait "\$BIN_PID" 2>/dev/null
    fi
    [ -d "\$LOCK_DIR" ] && {
        OWNER_PID=
        [ -f "\$LOCK_DIR/owner.pid" ] && read -r OWNER_PID < "\$LOCK_DIR/owner.pid" 2>/dev/null
        [[ "\$OWNER_PID" == "\$\$" ]] && rm -rf "\$LOCK_DIR"
    }
    [ -f "\$PID_FILE" ] && {
        CURRENT_PID=
        read -r CURRENT_PID < "\$PID_FILE" 2>/dev/null || true
        [[ "\$CURRENT_PID" == "\$BIN_PID" ]] && rm -f "\$PID_FILE"
    }
}
trap cleanup EXIT INT TERM

wait "\$BIN_PID"
exit \$?
FAKE_EOF
    chmod +x "$out"
}

# Temp directory for this test run.
TMPDIR=$(mktemp -d -t test-wrapper-mcp-error.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Build a single fake wrapper used by all tests (lock + pid paths injected).
LOCK_DIR="$TMPDIR/test-lock"
PID_FILE="$TMPDIR/test.pid"
FAKE_WRAPPER="$TMPDIR/fake-wrapper.sh"
make_fake_wrapper "$FAKE_WRAPPER" "$LOCK_DIR" "$PID_FILE" "CheTelegramAllMCP"

echo "=================================="
echo "test-wrapper-mcp-error.sh (#31)"
echo "=================================="

# ---------------------------------------------------------------
test_case "test_happy_path_no_lock"
rm -rf "$LOCK_DIR" "$PID_FILE"
STDOUT=$("$FAKE_WRAPPER" < /dev/null 2>/tmp/stderr-$$.log)
EXIT=$?
rm -f /tmp/stderr-$$.log
if [ "$EXIT" -eq 0 ]; then
    pass "exits 0 on happy path"
else
    fail "expected exit 0, got $EXIT"
fi
if [ -z "$STDOUT" ]; then
    pass "no stdout on happy path"
else
    fail "expected empty stdout, got: $STDOUT"
fi

# ---------------------------------------------------------------
test_case "test_lock_refused_emits_valid_json"
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
# Use our own PID as the "alive holder" — guaranteed alive during this script.
echo $$ > "$LOCK_DIR/owner.pid"

STDOUT=$("$FAKE_WRAPPER" < /dev/null 2>/dev/null)
EXIT=$?

if [ "$EXIT" -eq 1 ]; then
    pass "exits 1 when lock refused"
else
    fail "expected exit 1, got $EXIT"
fi

FIRST_LINE=$(echo "$STDOUT" | head -1)
if [ -z "$FIRST_LINE" ]; then
    fail "expected JSON-RPC error envelope on stdout, got empty"
else
    if echo "$FIRST_LINE" | jq -e '.jsonrpc == "2.0" and .id == null and .error.code == -32000 and (.error.message | length > 50)' >/dev/null 2>&1; then
        pass "stdout first line is valid JSON-RPC 2.0 error envelope"
    else
        fail "stdout first line failed envelope validation: $FIRST_LINE"
    fi
fi
rm -rf "$LOCK_DIR"

# ---------------------------------------------------------------
test_case "test_stale_lock_self_recovery"
rm -rf "$LOCK_DIR" "$PID_FILE"
mkdir -p "$LOCK_DIR"
# Use a PID guaranteed dead: spawn a no-op and immediately wait for it.
DEAD_PID=$(bash -c 'echo $$; exit 0')
echo "$DEAD_PID" > "$LOCK_DIR/owner.pid"

STDOUT=$("$FAKE_WRAPPER" < /dev/null 2>/tmp/stderr-$$.log)
EXIT=$?
rm -f /tmp/stderr-$$.log

if [ "$EXIT" -eq 0 ]; then
    pass "stale-cleanup path exits 0 (wrapper proceeded)"
else
    fail "expected exit 0 after stale cleanup, got $EXIT"
fi
if [ -z "$STDOUT" ]; then
    pass "stale-cleanup path emits no stdout (proceeded normally)"
else
    fail "expected empty stdout, got: $STDOUT"
fi
rm -rf "$LOCK_DIR"

# ---------------------------------------------------------------
test_case "test_json_data_includes_recovery_command"
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
echo $$ > "$LOCK_DIR/owner.pid"

STDOUT=$("$FAKE_WRAPPER" < /dev/null 2>/dev/null)
FIRST_LINE=$(echo "$STDOUT" | head -1)

if [ -z "$FIRST_LINE" ]; then
    fail "expected JSON on stdout (cannot validate recoveryCommand)"
else
    RECOVERY=$(echo "$FIRST_LINE" | jq -r '.error.data.recoveryCommand // empty' 2>/dev/null)
    if [[ "$RECOVERY" == pkill* ]]; then
        pass "error.data.recoveryCommand starts with 'pkill'"
    else
        fail "expected recoveryCommand starting with 'pkill', got: '$RECOVERY'"
    fi
fi
rm -rf "$LOCK_DIR"

# ---------------------------------------------------------------
# PR-1b: wrapper must read initialize id from stdin and respond with matching id
# so Claude Code's MCP client surfaces error.message instead of dropping the
# response as unmatched. Without this, id stays null and Claude Code falls
# back to generic -32000 (empirically confirmed on 2026-05-22).
test_case "test_lock_refused_with_initialize_request_id_matches"
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
echo $$ > "$LOCK_DIR/owner.pid"

# Feed a JSON-RPC initialize request to stdin; wrapper should respond with id=42
INIT_REQ='{"jsonrpc":"2.0","id":42,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}'
STDOUT=$(printf '%s\n' "$INIT_REQ" | "$FAKE_WRAPPER" 2>/dev/null)
FIRST_LINE=$(echo "$STDOUT" | head -1)

if [ -z "$FIRST_LINE" ]; then
    fail "expected JSON envelope on stdout, got empty"
else
    RESP_ID=$(echo "$FIRST_LINE" | jq -c '.id' 2>/dev/null)
    if [ "$RESP_ID" = "42" ]; then
        pass "response.id matches request.id (42)"
    else
        fail "expected response.id == 42, got: $RESP_ID (full: $FIRST_LINE)"
    fi
fi
rm -rf "$LOCK_DIR"

# ---------------------------------------------------------------
# Stdin timeout fallback: when no initialize arrives (e.g. direct shell debug),
# read_initialize_id should return null after timeout and emit envelope with
# id:null. Verifies the v1.3.2 PR-90 behavior is preserved as fallback.
test_case "test_lock_refused_no_stdin_falls_back_to_null_id"
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
echo $$ > "$LOCK_DIR/owner.pid"

# Empty stdin → read_initialize_id gets immediate EOF, no id available
STDOUT=$("$FAKE_WRAPPER" < /dev/null 2>/dev/null)
FIRST_LINE=$(echo "$STDOUT" | head -1)

if [ -z "$FIRST_LINE" ]; then
    fail "expected JSON envelope even on empty stdin, got empty"
else
    RESP_ID=$(echo "$FIRST_LINE" | jq -c '.id' 2>/dev/null)
    if [ "$RESP_ID" = "null" ]; then
        pass "response.id falls back to null when stdin has no initialize"
    else
        fail "expected response.id == null on empty stdin, got: $RESP_ID"
    fi
fi
rm -rf "$LOCK_DIR"

# ---------------------------------------------------------------
echo ""
echo "=================================="
if [ "$FAIL" -eq 0 ]; then
    echo "✓ All $TOTAL tests passed"
    exit 0
else
    echo "✗ $FAIL / $TOTAL tests failed"
    exit 1
fi
