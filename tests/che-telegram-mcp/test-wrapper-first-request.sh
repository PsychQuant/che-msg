#!/bin/bash
# What the che-telegram-mcp wrappers answer when the client's first message
# is not initialize (PsychQuant/che-msg#59).
#
# Claude Code builds from 2026-10 may send a server/discover request before
# initialize. When a wrapper stops before starting its server, its startup
# error (JSON-RPC -32000 with data.docsUrl) answers only initialize; a first
# request for another method gets "method not found" (-32601) for its own id
# from lib/startup-error.sh, and the wrapper exits 1 as it does after the
# startup error. Before #59 the wrapper answered the probe with the startup
# error. A first request the wrapper does not have to answer, because it
# starts the server, reaches the server untouched.
#
# Runs the real wrappers against private HOMEs (tests/lib/wrapper_harness.sh);
# the fake curl serves nothing but a slow asset, and nothing reaches the
# network.
#
# Tests:
#   For telegram-all, with server/discover as the first request:
#   1. Missing credentials, numeric id: the only line on stdout is a JSON-RPC
#      error with that id and code -32601, there is no -32000 answer, the
#      wrapper exits 1, no binary is started, and stderr names the cause.
#   2. The same with a string id.
#   3. A notification for another method first: nothing on stdout, exit 1.
#   4. Nothing installed and the download failing: -32601 as in 1.
#   5. Nothing installed and the download still running when the wait ends
#      (the first-install answer): -32601 as in 1.
#   6. Only a 0.6.0 binary and the download failing: -32601 as in 1.
#   7. A binary it runs and credentials present: the binary is started and
#      receives the request as its first line; the wrapper writes nothing.
#   For telegram-bot, with server/discover as the first request:
#   8. Nothing installed and the download failing: -32601 as in 1.
#   9. Nothing installed and the download still running: -32601 as in 1.
#   For telegram-all, missing credentials, with other first lines:
#  10. An initialize notification (no id): nothing on stdout, exit 1, the
#      cause on stderr.
#  11. A batch (a JSON array): one -32600 error with id null, no -32000.
#  12. A client that never writes (stdin open, nothing sent): the wrapper
#      answers -32000 with id null and exits 1 within a bounded time instead
#      of waiting for stdin to close.
#  13. telegram-bot with a binary it runs and a token: the binary receives the
#      request as its first line; the wrapper writes nothing.
#   lib/startup-error.sh's read_first_request, sourced on its own:
#  14. With jq, one case per kind of first line: an initialize request (id a
#      number, a string or null) sets REQUEST_ID; an initialize notification
#      and a notification for another method (even with an id inside params)
#      get no answer and exit 1; a request for another method gets -32601 for
#      its id (null, a float, a negative number, an empty string and a string
#      with an escaped quote included); a batch, empty or not, gets -32600 with
#      id null; a method that is missing, not a string or empty leaves the
#      startup error with the object's id; an id of another type, two JSON
#      values on the line, a JSON value that is not an object, a line that is
#      not JSON and empty stdin leave it with id null.
#  15. Without a jq (none on PATH and no system jq): every line leaves the
#      startup error with id null, a request for another method and a batch
#      included.
#  16. Number ids are echoed exactly: 9007199254740993 and
#      3.141592653589793238462643383279 (the raw text is compared).
#  17. Only a jq of 1.7 or later is used: the system jq (STARTUP_SYSTEM_JQ,
#      /usr/bin/jq) first, then the one on PATH. A jq-1.6 alone, or a jq whose
#      version cannot be read, means no jq (id null, no -32601); a jq-1.7.1 or
#      jq-2.0 on PATH is used; a system jq-1.6 is passed over for a jq-1.7.1
#      on PATH, and a system jq-1.7.1 is used before a jq-1.6 on PATH (one
#      that fails if it is used to parse).
#
# Usage:
#   bash tests/che-telegram-mcp/test-wrapper-first-request.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/wrapper_harness.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for these tests. Install via 'brew install jq'." >&2
    exit 1
fi

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

LIB="$HARNESS_ROOT/plugins/che-telegram-mcp/lib/startup-error.sh"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrapper-first-request-XXXXXX") || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "ERROR: cannot create a scratch directory" >&2; exit 1; }
STARTED=()
finish() {
    for pid in "${STARTED[@]+"${STARTED[@]}"}"; do kill -KILL "$pid" 2>/dev/null; done
    for pids in "$SCRATCH"/*/started.pids "$SCRATCH"/*/curl.pids; do
        [ -f "$pids" ] && while read -r pid; do kill -KILL "$pid" 2>/dev/null; done < "$pids"
    done
    # A first-install case leaves its download running in a session of its own.
    pkill -KILL -f -- "$SCRATCH" 2>/dev/null
    rm -rf "$SCRATCH"
}
trap finish EXIT

probe() { printf '{"jsonrpc":"2.0","id":%s,"method":"server/discover","params":{}}' "$1"; }
SLOW=8   # seconds the fake asset takes, longer than the wait below

# run <home> <wrapper> <first line> [install wait]: runs the wrapper to its
# end with that line on stdin; sets RC.
run() {
    local home=$1 wrapper=$2 line=$3 wait=${4:-}
    printf '%s\n' "$line" > "$home/in"
    if [ -n "$wait" ]; then
        HOME="$home" PATH="$home/fakebin:$PATH" CHE_TELEGRAM_MCP_INSTALL_WAIT=$wait /bin/bash "$wrapper" < "$home/in" > "$home/out" 2> "$home/err"
    else
        HOME="$home" PATH="$home/fakebin:$PATH" /bin/bash "$wrapper" < "$home/in" > "$home/out" 2> "$home/err"
    fi
    RC=$?
}

# check_method_not_found <home> <id as jq literal> <stderr substring>
check_method_not_found() {
    local home=$1 id=$2 cause=$3 lines
    if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
    lines=$(wc -l < "$home/out" | tr -d ' ')
    if [ "$lines" -eq 1 ] && head -1 "$home/out" | jq -e --argjson id "$id" '
        .jsonrpc == "2.0" and .id == $id and .error.code == -32601
        and (.error.message | type == "string")' >/dev/null 2>&1; then
        pass "the only answer is -32601 for the request's id $id"
    else
        fail "stdout is not one -32601 answer for id $id: $(head -c 300 "$home/out")"
    fi
    if ! grep -q -- '-32000' "$home/out"; then pass "the request is not answered with the startup error"; else fail "the startup error (-32000) answered the request"; fi
    if [ ! -e "$home/started.pids" ]; then pass "no binary started"; else fail "a binary was started"; fi
    if grep -q -- "$cause" "$home/err"; then pass "stderr says: $cause"; else fail "stderr lacks '$cause': $(tail -3 "$home/err" | tr '\n' ' ')"; fi
}

# ----------------------------------------------------------------------
test_case "telegram-all, missing credentials: server/discover with a numeric id"
H="$SCRATCH/all-nocreds"; make_home "$H" no
run "$H" "$WRAPPER" "$(probe 1)"
check_method_not_found "$H" 1 "credentials not found in Keychain"

# ----------------------------------------------------------------------
test_case "telegram-all, missing credentials: server/discover with a string id"
H="$SCRATCH/all-nocreds-string"; make_home "$H" no
run "$H" "$WRAPPER" "$(probe '"probe-1"')"
check_method_not_found "$H" '"probe-1"' "credentials not found in Keychain"

# ----------------------------------------------------------------------
test_case "telegram-all, missing credentials: a notification first gets no answer"
H="$SCRATCH/all-notification"; make_home "$H" no
run "$H" "$WRAPPER" '{"jsonrpc":"2.0","method":"notifications/initialized"}'
if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
if [ ! -s "$H/out" ]; then pass "nothing on stdout"; else fail "stdout: $(head -c 300 "$H/out")"; fi

# ----------------------------------------------------------------------
test_case "telegram-all, nothing installed and the download failing"
H="$SCRATCH/all-nobinary"; make_home "$H"
rm -f "$H/bin/CheTelegramAllMCP" "$H/bin/.CheTelegramAllMCP.version"
run "$H" "$WRAPPER" "$(probe 2)"
check_method_not_found "$H" 2 "not installed"
if [ -s "$H/curl.calls" ]; then pass "the download was attempted (fake curl)"; else fail "no download attempt"; fi

# ----------------------------------------------------------------------
test_case "telegram-all, nothing installed and the download still running"
H="$SCRATCH/all-downloading"; make_home "$H"
rm -f "$H/bin/CheTelegramAllMCP" "$H/bin/.CheTelegramAllMCP.version"
echo "a slow asset" > "$H/asset"; serve_asset "$H" "$H/asset"; echo "$SLOW" > "$H/fake-curl/asset.delay"
run "$H" "$WRAPPER" "$(probe 3)" 1
check_method_not_found "$H" 3 "not installed yet"

# ----------------------------------------------------------------------
test_case "telegram-all, only a 0.6.0 binary and the download failing"
H="$SCRATCH/all-binary060"; make_home "$H" yes 0.6.0
run "$H" "$WRAPPER" "$(probe 4)"
# The version probe starts nothing as a server: a 0.6.0 fake answers --version.
check_method_not_found "$H" 4 "needs 0.7.0 or later"

# ----------------------------------------------------------------------
test_case "telegram-all, a binary it runs: the request reaches the server untouched"
H="$SCRATCH/all-starts"; make_home "$H"
printf '%s\n' "$(probe 5)" > "$H/in"
W=$(start_wrapper "$H" "$H/in" "$H/out"); STARTED+=("$W")
if wait_until 5 has_pids "$H" 1 && wait_until 5 test -s "$H/stdin.txt"; then pass "binary started"; else fail "binary did not start or read nothing"; fi
if [ "$(cat "$H/stdin.txt" 2>/dev/null)" = "$(probe 5)" ]; then pass "the binary's first line is the request"; else fail "the binary read: $(head -c 200 "$H/stdin.txt" 2>/dev/null)"; fi
if [ ! -s "$H/out" ]; then pass "the wrapper wrote nothing to stdout"; else fail "the wrapper wrote: $(head -c 200 "$H/out")"; fi
stop "$W"

# ----------------------------------------------------------------------
test_case "telegram-bot, nothing installed and the download failing"
H="$SCRATCH/bot-nobinary"; make_bot_home "$H" -; rm -f "$H/bin/CheTelegramBotMCP"
run "$H" "$BOT_WRAPPER" "$(probe 6)"
check_method_not_found "$H" 6 "not installed"

# ----------------------------------------------------------------------
test_case "telegram-bot, nothing installed and the download still running"
H="$SCRATCH/bot-downloading"; make_bot_home "$H" -; rm -f "$H/bin/CheTelegramBotMCP"
echo "a slow asset" > "$H/asset"; serve_asset "$H" "$H/asset"; echo "$SLOW" > "$H/fake-curl/asset.delay"
run "$H" "$BOT_WRAPPER" "$(probe '"bot-7"')" 1
check_method_not_found "$H" '"bot-7"' "not installed yet"

# ----------------------------------------------------------------------
test_case "telegram-all, missing credentials: an initialize notification gets no answer"
H="$SCRATCH/all-init-notification"; make_home "$H" no
run "$H" "$WRAPPER" '{"jsonrpc":"2.0","method":"initialize","params":{}}'
if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
if [ ! -s "$H/out" ]; then pass "nothing on stdout"; else fail "stdout: $(head -c 300 "$H/out")"; fi
if grep -q "credentials not found in Keychain" "$H/err"; then pass "the cause is on stderr"; else fail "stderr: $(tail -3 "$H/err" | tr '\n' ' ')"; fi

# ----------------------------------------------------------------------
test_case "telegram-all, missing credentials: a batch gets one -32600 error with id null"
H="$SCRATCH/all-batch"; make_home "$H" no
run "$H" "$WRAPPER" "[$(probe 1),{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\"}]"
if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
if [ "$(wc -l < "$H/out" | tr -d ' ')" -eq 1 ] && head -1 "$H/out" | jq -e '.jsonrpc == "2.0" and .id == null and .error.code == -32600' >/dev/null 2>&1; then
    pass "the only answer is -32600 with id null"
else
    fail "stdout is not one -32600 error: $(head -c 300 "$H/out")"
fi
if ! grep -q -- '-32000' "$H/out"; then pass "no startup error (-32000)"; else fail "the startup error was written"; fi

# ----------------------------------------------------------------------
test_case "telegram-all, missing credentials: a client that never writes gets an answer in bounded time"
H="$SCRATCH/all-silent-client"; make_home "$H" no
mkfifo "$H/fifo"
/bin/sleep 60 > "$H/fifo" &
HOLDER=$!; STARTED+=("$HOLDER")
t0=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
HOME="$H" PATH="$H/fakebin:$PATH" /bin/bash "$WRAPPER" < "$H/fifo" > "$H/out" 2> "$H/err" &
W=$!; STARTED+=("$W")
BOUND=20   # seconds; the read waits 2 s, the rest is slack for a loaded machine
if wait_until "$BOUND" bash -c "! kill -0 $W 2>/dev/null"; then
    wait "$W"; RC=$?
    T=$(perl -MTime::HiRes=time -e 'printf "%.1f", time - $ARGV[0]' "$t0")
    pass "the wrapper ended after ${T}s while stdin was still open (bound ${BOUND}s)"
    if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
    if [ "$(wc -l < "$H/out" | tr -d ' ')" -eq 1 ] && head -1 "$H/out" | jq -e '.id == null and .error.code == -32000' >/dev/null 2>&1; then
        pass "the answer is the startup error with id null"
    else
        fail "stdout: $(head -c 300 "$H/out")"
    fi
else
    fail "the wrapper was still running after ${BOUND}s with stdin open"
fi
kill -KILL "$HOLDER" "$W" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# ----------------------------------------------------------------------
test_case "telegram-bot, a binary it runs: the request reaches the server untouched"
H="$SCRATCH/bot-starts"; make_bot_home "$H" "$BOT_DESIRED"
cat > "$H/bin/CheTelegramBotMCP" <<'EOF'
#!/bin/bash
echo $$ >> "$HOME/started.pids"
if IFS= read -r -t 2 line; then printf '%s\n' "$line" > "$HOME/stdin.txt"; fi
EOF
chmod +x "$H/bin/CheTelegramBotMCP"
run "$H" "$BOT_WRAPPER" "$(probe 5)"
if [ -s "$H/started.pids" ]; then pass "binary started"; else fail "binary did not start: $(tail -3 "$H/err" | tr '\n' ' ')"; fi
if [ "$(cat "$H/stdin.txt" 2>/dev/null)" = "$(probe 5)" ]; then pass "the binary's first line is the request"; else fail "the binary read: $(head -c 200 "$H/stdin.txt" 2>/dev/null)"; fi
if [ ! -s "$H/out" ]; then pass "the wrapper wrote nothing to stdout"; else fail "the wrapper wrote: $(head -c 200 "$H/out")"; fi

# ----------------------------------------------------------------------
# reader <PATH> <first line> [system jq]: runs read_first_request from the
# lib on its own with that line (none if empty) on stdin and that PATH, with
# STARTUP_SYSTEM_JQ (the jq tried before the one on PATH) set to [system jq]
# when given; prints "<exit status>|<stdout>", where stdout ends with
# <id=REQUEST_ID> unless the reader exited.
reader() {
    local path=$1 line=$2 system_jq=${3:-} out rc
    out=$( { [ -n "$line" ] && printf '%s\n' "$line"; } | env PATH="$path" /bin/bash -c '
        source "$1" || exit 99
        [ -n "$2" ] && STARTUP_SYSTEM_JQ=$2
        read_first_request
        printf "<id=%s>" "$REQUEST_ID"' _ "$LIB" "$system_jq")
    rc=$?
    printf '%s|%s' "$rc" "$out"
}
expect_reader() {   # <label> <path> <first line> <expected> [system jq]
    local got; got=$(reader "$2" "$3" "${5:-}")
    if [ "$got" = "$4" ]; then pass "$1"; else fail "$1: got '$got', expected '$4'"; fi
}
M601='{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}'
M600='{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}'
INIT7='{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}'

test_case "read_first_request with jq"
expect_reader "initialize, numeric id: REQUEST_ID set, nothing written" "$PATH" "$INIT7" '0|<id=7>'
expect_reader "initialize, string id" "$PATH" \
    '{"jsonrpc":"2.0","id":"abc","method":"initialize"}' '0|<id="abc">'
expect_reader "initialize, id null" "$PATH" \
    '{"jsonrpc":"2.0","id":null,"method":"initialize"}' '0|<id=null>'
expect_reader "an initialize notification: no answer, exit 1" "$PATH" \
    '{"jsonrpc":"2.0","method":"initialize","params":{}}' '1|'
expect_reader "server/discover: -32601 and exit 1" "$PATH" "$(probe 8)" "1|$(printf "$M601" 8)"
expect_reader "server/discover, id null: -32601 with id null" "$PATH" "$(probe null)" "1|$(printf "$M601" null)"
expect_reader "server/discover, id 1.5" "$PATH" "$(probe 1.5)" "1|$(printf "$M601" 1.5)"
expect_reader "server/discover, id -7" "$PATH" "$(probe -7)" "1|$(printf "$M601" -7)"
expect_reader "server/discover, id empty string" "$PATH" "$(probe '""')" "1|$(printf "$M601" '""')"
expect_reader "server/discover, id with an escaped quote" "$PATH" "$(probe '"a\"b"')" "1|$(printf "$M601" '"a\"b"')"
got=$(reader "$PATH" "$(probe '"a\"b"')"); got=${got#1|}
if printf '%s' "$got" | jq -e '.id == "a\"b"' >/dev/null 2>&1; then pass "that answer is valid JSON with the same id"; else fail "not valid JSON with id a\"b: $got"; fi
expect_reader "a notification with an id inside params: no answer" "$PATH" \
    '{"jsonrpc":"2.0","method":"notifications/progress","params":{"id":5}}' '1|'
expect_reader "a batch: -32600 with id null" "$PATH" "[$(probe 1)]" "1|$M600"
expect_reader "an empty batch: -32600 with id null" "$PATH" '[]' "1|$M600"
expect_reader "a method that is not a string: the startup error with its id" "$PATH" \
    '{"jsonrpc":"2.0","id":9,"method":5}' '0|<id=9>'
expect_reader "an empty method: the startup error with its id" "$PATH" \
    '{"jsonrpc":"2.0","id":10,"method":""}' '0|<id=10>'
expect_reader "no method: the startup error with its id" "$PATH" '{"jsonrpc":"2.0","id":11}' '0|<id=11>'
expect_reader "no method and no id: id null" "$PATH" '{"jsonrpc":"2.0"}' '0|<id=null>'
expect_reader "an id that is an object: id null" "$PATH" \
    '{"jsonrpc":"2.0","id":{"a":1},"method":"server/discover"}' '0|<id=null>'
expect_reader "two JSON values on the line: id null" "$PATH" "$INIT7 $(probe 2)" '0|<id=null>'
expect_reader "a JSON number: id null" "$PATH" '5' '0|<id=null>'
expect_reader "a line that is not JSON: id null" "$PATH" 'not json' '0|<id=null>'
expect_reader "empty stdin: id null" "$PATH" '' '0|<id=null>'

test_case "read_first_request without jq"
NOJQ="$SCRATCH/no-jq-path"; mkdir -p "$NOJQ"
if env PATH="$NOJQ" /bin/bash -c 'command -v jq' >/dev/null 2>&1; then fail "jq is still on the test PATH"; else pass "jq is not on the test PATH"; fi
NONE="$SCRATCH/no-system-jq"   # a STARTUP_SYSTEM_JQ that does not exist
expect_reader "initialize: id null" "$NOJQ" "$INIT7" '0|<id=null>' "$NONE"
expect_reader "server/discover: the startup error with id null, not -32601" "$NOJQ" "$(probe 10)" '0|<id=null>' "$NONE"
expect_reader "a batch: id null" "$NOJQ" "[$(probe 1)]" '0|<id=null>' "$NONE"

# ----------------------------------------------------------------------
# A jq older than 1.7 rounds a number literal it echoes (1.6 turns
# 9007199254740993 into 9007199254740992), so an answer's id would not match
# the request's. The fakes below report a version and otherwise run the real
# jq, so only the version check can tell them apart.
REAL_JQ=$(command -v jq)
fake_jq() {   # <dir> <version output>: a jq in <dir> that reports that version
    mkdir -p "$1"
    printf '#!/bin/bash\nif [ "$1" = --version ]; then echo %s; exit 0; fi\nexec %s "$@"\n' "$2" "$REAL_JQ" > "$1/jq"
    chmod +x "$1/jq"
}
fake_jq "$SCRATCH/jq16" jq-1.6
fake_jq "$SCRATCH/jq17" jq-1.7.1
fake_jq "$SCRATCH/jq20" jq-2.0
fake_jq "$SCRATCH/jqodd" jq-master-abc
# A jq-1.6 that fails if it is used for anything but --version.
mkdir -p "$SCRATCH/jq16-unused"
printf '#!/bin/bash\nif [ "$1" = --version ]; then echo jq-1.6; exit 0; fi\nexit 3\n' > "$SCRATCH/jq16-unused/jq"
chmod +x "$SCRATCH/jq16-unused/jq"

test_case "read_first_request echoes number ids exactly (jq 1.7 or later)"
BIG='{"jsonrpc":"2.0","id":9007199254740993,"method":"server/discover"}'
LONG='{"jsonrpc":"2.0","id":3.141592653589793238462643383279,"method":"server/discover"}'
expect_reader "id 9007199254740993 is echoed as written" "$PATH" "$BIG" "1|$(printf "$M601" 9007199254740993)"
expect_reader "id 3.141592653589793238462643383279 is echoed as written" "$PATH" "$LONG" "1|$(printf "$M601" 3.141592653589793238462643383279)"
expect_reader "initialize with id 9007199254740993 keeps it for the startup error" "$PATH" \
    '{"jsonrpc":"2.0","id":9007199254740993,"method":"initialize"}' '0|<id=9007199254740993>'

test_case "read_first_request uses only jq 1.7 or later"
expect_reader "only a jq-1.6 on PATH, no system jq: id null, no -32601" "$SCRATCH/jq16" "$BIG" '0|<id=null>' "$NONE"
expect_reader "only a jq-1.6 on PATH, no system jq: initialize gets id null" "$SCRATCH/jq16" "$INIT7" '0|<id=null>' "$NONE"
expect_reader "a jq-1.7.1 on PATH, no system jq: used" "$SCRATCH/jq17" "$(probe 3)" "1|$(printf "$M601" 3)" "$NONE"
expect_reader "a jq-2.0 on PATH, no system jq: used" "$SCRATCH/jq20" "$(probe 4)" "1|$(printf "$M601" 4)" "$NONE"
expect_reader "a jq whose version cannot be read: not used" "$SCRATCH/jqodd" "$(probe 5)" '0|<id=null>' "$NONE"
expect_reader "a system jq-1.6 is passed over for a jq-1.7.1 on PATH" "$SCRATCH/jq17" "$(probe 6)" "1|$(printf "$M601" 6)" "$SCRATCH/jq16/jq"
expect_reader "a system jq-1.7.1 is used before a jq-1.6 on PATH" "$SCRATCH/jq16-unused" "$(probe 7)" "1|$(printf "$M601" 7)" "$SCRATCH/jq17/jq"

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
