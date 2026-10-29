#!/bin/bash
# Behaviour of plugins/che-slack-mcp/bin/che-slack-mcp-wrapper.sh
# (PsychQuant/che-msg#99, task 6.1 of add-che-slack-mcp).
#
# Runs the real wrapper against a private HOME with an empty environment
# (env -i). The HOME holds, as each case needs, a fake CheSlackMCP that records
# its environment, arguments and first stdin line; a fake `security` that
# records every call and fails; and a fake `curl` that records every call and
# either fails or serves a fake release from files in the HOME. Nothing reaches
# the network, the real Keychain or the real ~/bin.
#
# Design (獨立的 che-slack-mcp plugin): the wrapper pins DESIRED_VERSION,
# downloads the binary from that release only, and reads and exports no
# credential — CheSlackMCP reads each workspace's session from the Keychain
# itself.
#
# Tests:
#   1. An installed binary at the pinned version starts with the client's
#      stdin; the wrapper writes nothing to stdout and calls neither curl nor
#      security.
#   2. The binary's environment holds no Slack credential: no variable named
#      SLACK_* other than the two pacing overrides, none whose name contains
#      TOKEN or COOKIE, and no value shaped like a Slack token (xox?-…).
#   3. The pacing overrides SLACK_MCP_MIN_INTERVAL_MS and
#      SLACK_MCP_MAX_CONCURRENCY reach the binary unchanged.
#   4. No binary and the download fails: exit 1, nothing started, and stdout
#      answers the initialize request (numeric id) with a JSON-RPC error whose
#      data.docsUrl is the README section "When slack does not start". Only the
#      pinned release was asked for, never releases/latest.
#   5. The same with a string request id.
#   6. No binary and the download works: the asset named exactly CheSlackMCP
#      of the pinned release is installed in ~/bin with the version sidecar,
#      and started with the client's stdin.
#   7. A ~/bin binary whose sidecar names another version is upgraded; when
#      that download fails, the existing binary is kept and started.
#   8. A source build under ~/Developer/che-msg/che-slack-mcp is used as it
#      is: no download, no sidecar written.
#   9. No case reached curl except the download cases, and no case called
#      security.
#
# Usage:
#   bash tests/che-slack-mcp/test-wrapper.sh
#
# Exit: 0 on all pass, 1 on any failure.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# WRAPPER_UNDER_TEST runs the tests against another copy.
WRAPPER="${WRAPPER_UNDER_TEST:-$ROOT/plugins/che-slack-mcp/bin/che-slack-mcp-wrapper.sh}"
if [ ! -f "$WRAPPER" ]; then
    echo "FAIL wrapper not found: $WRAPPER"
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for these tests. Install via 'brew install jq'." >&2
    exit 1
fi
DESIRED_VERSION=$(sed -n 's/^DESIRED_VERSION="\(.*\)"$/\1/p' "$WRAPPER")
if [ -z "$DESIRED_VERSION" ]; then
    echo "FAIL the wrapper has no DESIRED_VERSION=\"x.y.z\" line"
    exit 1
fi
DOCS_URL="https://github.com/PsychQuant/che-msg/blob/main/plugins/che-slack-mcp/README.md#when-slack-does-not-start"
TAG_API="https://api.github.com/repos/PsychQuant/che-msg/releases/tags/v$DESIRED_VERSION"
ASSET_URL="https://github.com/PsychQuant/che-msg/releases/download/v$DESIRED_VERSION/CheSlackMCP"

FAIL=0
TOTAL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
test_case() { TOTAL=$((TOTAL + 1)); echo "Test: $1"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/slack-wrapper-XXXXXX") || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

# fake_binary <path>: a CheSlackMCP stand-in. It records its environment
# (env -0, so a value with a newline stays one record), its arguments and the
# first stdin line, then exits 0.
fake_binary() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'EOF'
#!/bin/bash
/usr/bin/env -0 > "$HOME/binary.env"
printf '%s\n' "$@" > "$HOME/binary.args"
echo started >> "$HOME/started"
if IFS= read -r -t 2 line; then printf '%s\n' "$line" > "$HOME/stdin.txt"; fi
exit 0
EOF
    chmod +x "$1"
}

# make_home <dir> [installed|none] [sidecar version] [curl: fail|serve]
make_home() {
    local home=$1 binary=${2:-installed} sidecar=${3:-$DESIRED_VERSION} curl_mode=${4:-fail}
    mkdir -p "$home/bin" "$home/fakebin"
    if [ "$binary" = installed ]; then
        fake_binary "$home/bin/CheSlackMCP"
        echo "$sidecar" > "$home/bin/.CheSlackMCP.version"
    fi
    printf '#!/bin/bash\necho "$*" >> "$HOME/security.calls"\nexit 44\n' > "$home/fakebin/security"
    echo "$curl_mode" > "$home/curl.mode"
    # The served release lists decoys around the real asset, so the wrapper
    # must pick the asset named exactly CheSlackMCP.
    cat > "$home/release.json" <<EOF
{
  "tag_name": "v$DESIRED_VERSION",
  "assets": [
    { "name": "che-slack-mcp.mcpb", "browser_download_url": "https://github.com/PsychQuant/che-msg/releases/download/v$DESIRED_VERSION/che-slack-mcp.mcpb" },
    { "name": "CheSlackMCP", "browser_download_url": "$ASSET_URL" },
    { "name": "CheTelegramAllMCP", "browser_download_url": "https://github.com/PsychQuant/che-msg/releases/download/v$DESIRED_VERSION/CheTelegramAllMCP" }
  ]
}
EOF
    fake_binary "$home/served-binary"
    cat > "$home/fakebin/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/curl.calls"
[ "$(cat "$HOME/curl.mode" 2>/dev/null)" = serve ] || exit 22
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        --max-time) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
if [ -n "$out" ]; then
    echo "$url" >> "$HOME/curl.downloads"
    cp "$HOME/served-binary" "$out"
    exit 0
fi
case "$url" in
    */releases/tags/v*) cat "$HOME/release.json" ;;
    *) exit 22 ;;
esac
EOF
    chmod +x "$home/fakebin/security" "$home/fakebin/curl"
}

# run_wrapper <home> <stdin-file> [VAR=value ...]: runs the wrapper in an empty
# environment plus the given variables; stdout to $home/out, stderr to
# $home/err; prints the exit status.
run_wrapper() {
    local home=$1 input=$2; shift 2
    env -i HOME="$home" PATH="$home/fakebin:/usr/bin:/bin" "$@" \
        /bin/bash "$WRAPPER" < "$input" > "$home/out" 2> "$home/err"
    echo $?
}

initialize() { printf '{"jsonrpc":"2.0","id":%s,"method":"initialize","params":{}}\n' "$1"; }

# check_started <home> <expected stdin line>
check_started() {
    if [ -f "$1/started" ]; then pass "binary started"; else fail "binary did not start (stderr: $(head -c 300 "$1/err"))"; fi
    if [ "$(cat "$1/stdin.txt" 2>/dev/null)" = "$2" ]; then
        pass "binary read the client's stdin"
    else
        fail "binary did not receive the client's stdin"
    fi
    if [ ! -s "$1/out" ]; then pass "wrapper wrote nothing to stdout"; else fail "stdout: $(head -c 200 "$1/out")"; fi
}

# check_error <home> <expected id as jq literal>
check_error() {
    local line
    line=$(head -1 "$1/out")
    if printf '%s' "$line" | jq -e --argjson id "$2" --arg url "$DOCS_URL" '
        .jsonrpc == "2.0" and .id == $id and .error.code == -32000
        and (.error.message | type == "string" and length > 20)
        and .error.data.docsUrl == $url' >/dev/null 2>&1; then
        pass "stdout answers the initialize request with the error"
    else
        fail "stdout is not the expected JSON-RPC error: ${line:0:300}"
    fi
    if [ ! -e "$1/started" ]; then pass "no binary started"; else fail "a binary was started"; fi
}

# check_pinned_only <home>: every release query names the pinned tag.
check_pinned_only() {
    local queries
    queries=$(grep -v -e ' -o ' "$1/curl.calls" 2>/dev/null)
    if [ -n "$queries" ] && ! printf '%s\n' "$queries" | grep -v -q -F "$TAG_API"; then
        pass "only the pinned release v$DESIRED_VERSION was asked for"
    else
        fail "release queries other than $TAG_API: ${queries:-none}"
    fi
    if ! grep -q 'releases/latest' "$1/curl.calls" 2>/dev/null; then pass "releases/latest never asked for"; else fail "asked for releases/latest"; fi
}

# ----------------------------------------------------------------------
test_case "An installed binary at the pinned version starts with the client's stdin"
H="$SCRATCH/installed"; make_home "$H"
initialize 1 > "$H/in"
RC=$(run_wrapper "$H" "$H/in")
if [ "$RC" -eq 0 ]; then pass "exit status 0 (the binary's)"; else fail "exit status $RC"; fi
check_started "$H" "$(cat "$H/in")"
if [ ! -e "$H/curl.calls" ]; then pass "no download attempted"; else fail "curl was called: $(cat "$H/curl.calls")"; fi
if [ ! -e "$H/security.calls" ]; then pass "security never called"; else fail "security was called: $(cat "$H/security.calls")"; fi

# ----------------------------------------------------------------------
test_case "The binary's environment holds no Slack credential"
# Reads the env -0 dump of case 1 (empty environment) and of case 3 (pacing
# overrides set), one NUL-separated record per variable.
check_env() {
    local label=$1 dump=$2
    if [ ! -s "$dump" ]; then fail "$label: no environment recorded"; return; fi
    local problems
    problems=$(python3 - "$dump" <<'EOF'
import re, sys
allowed = {"SLACK_MCP_MIN_INTERVAL_MS", "SLACK_MCP_MAX_CONCURRENCY"}
for record in open(sys.argv[1], "rb").read().split(b"\0"):
    if not record:
        continue
    name, _, value = record.decode("utf-8", "replace").partition("=")
    if name.upper().startswith("SLACK_") and name not in allowed:
        print(f"variable {name} is set")
    if re.search(r"TOKEN|COOKIE", name, re.I):
        print(f"variable {name} looks like a credential")
    if re.search(r"xox[a-z]-", value):
        print(f"variable {name} holds a value shaped like a Slack token")
EOF
)
    if [ $? -ne 0 ]; then fail "$label: the check could not run"; return; fi
    if [ -z "$problems" ]; then pass "$label: no Slack credential in the binary's environment"; else fail "$label: $problems"; fi
}
check_env "empty environment" "$SCRATCH/installed/binary.env"

# ----------------------------------------------------------------------
test_case "The pacing overrides reach the binary unchanged"
H="$SCRATCH/pacing"; make_home "$H"
initialize 2 > "$H/in"
RC=$(run_wrapper "$H" "$H/in" SLACK_MCP_MIN_INTERVAL_MS=500 SLACK_MCP_MAX_CONCURRENCY=2)
if [ "$RC" -eq 0 ]; then pass "exit status 0"; else fail "exit status $RC"; fi
if tr '\0' '\n' < "$H/binary.env" | grep -qx 'SLACK_MCP_MIN_INTERVAL_MS=500' \
   && tr '\0' '\n' < "$H/binary.env" | grep -qx 'SLACK_MCP_MAX_CONCURRENCY=2'; then
    pass "both overrides reached the binary"
else
    fail "an override did not reach the binary"
fi
check_env "pacing overrides set" "$H/binary.env"
if [ ! -e "$H/security.calls" ]; then pass "security never called"; else fail "security was called"; fi

# ----------------------------------------------------------------------
test_case "No binary and a failed download answer the initialize request (numeric id)"
H="$SCRATCH/nobinary"; make_home "$H" none
initialize 9 > "$H/in"
RC=$(run_wrapper "$H" "$H/in")
if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
check_error "$H" 9
check_pinned_only "$H"
if [ ! -e "$H/bin/CheSlackMCP" ] && [ ! -e "$H/bin/CheSlackMCP.tmp" ] && [ ! -e "$H/bin/.CheSlackMCP.version" ]; then
    pass "nothing left in ~/bin"
else
    fail "files left in ~/bin: $(ls -A "$H/bin")"
fi

# ----------------------------------------------------------------------
test_case "No binary and a failed download answer the initialize request (string id)"
H="$SCRATCH/nobinary-string"; make_home "$H" none
initialize '"abc"' > "$H/in"
RC=$(run_wrapper "$H" "$H/in")
if [ "$RC" -eq 1 ]; then pass "exit status 1"; else fail "exit status $RC"; fi
check_error "$H" '"abc"'

# ----------------------------------------------------------------------
test_case "No binary and a working download install the pinned release's CheSlackMCP"
H="$SCRATCH/download"; make_home "$H" none "" serve
initialize 3 > "$H/in"
RC=$(run_wrapper "$H" "$H/in")
if [ "$RC" -eq 0 ]; then pass "exit status 0"; else fail "exit status $RC (stderr: $(head -c 300 "$H/err"))"; fi
check_started "$H" "$(cat "$H/in")"
check_pinned_only "$H"
if [ "$(cat "$H/curl.downloads" 2>/dev/null)" = "$ASSET_URL" ]; then
    pass "downloaded exactly $ASSET_URL"
else
    fail "downloaded: $(cat "$H/curl.downloads" 2>/dev/null || echo nothing)"
fi
if [ -x "$H/bin/CheSlackMCP" ] && [ ! -e "$H/bin/CheSlackMCP.tmp" ]; then pass "installed in ~/bin"; else fail "not installed in ~/bin"; fi
if [ "$(cat "$H/bin/.CheSlackMCP.version" 2>/dev/null)" = "$DESIRED_VERSION" ]; then
    pass "version sidecar says $DESIRED_VERSION"
else
    fail "version sidecar: $(cat "$H/bin/.CheSlackMCP.version" 2>/dev/null || echo missing)"
fi

# ----------------------------------------------------------------------
test_case "Another installed version is upgraded, and kept when the download fails"
H="$SCRATCH/upgrade"; make_home "$H" installed 0.0.1 serve
initialize 4 > "$H/in"
RC=$(run_wrapper "$H" "$H/in")
if [ "$RC" -eq 0 ]; then pass "exit status 0"; else fail "exit status $RC"; fi
if [ "$(cat "$H/curl.downloads" 2>/dev/null)" = "$ASSET_URL" ]; then pass "the pinned release was downloaded"; else fail "no upgrade download"; fi
if [ "$(cat "$H/bin/.CheSlackMCP.version" 2>/dev/null)" = "$DESIRED_VERSION" ]; then pass "sidecar now says $DESIRED_VERSION"; else fail "sidecar not updated"; fi
H="$SCRATCH/upgrade-fails"; make_home "$H" installed 0.0.1 fail
initialize 5 > "$H/in"
RC=$(run_wrapper "$H" "$H/in")
if [ "$RC" -eq 0 ]; then pass "exit status 0"; else fail "exit status $RC"; fi
check_started "$H" "$(cat "$H/in")"
if grep -q 'keeping existing binary' "$H/err"; then pass "stderr says the existing binary is kept"; else fail "stderr: $(head -c 300 "$H/err")"; fi
if [ "$(cat "$H/bin/.CheSlackMCP.version")" = 0.0.1 ]; then pass "sidecar unchanged after the failed download"; else fail "sidecar changed"; fi

# ----------------------------------------------------------------------
test_case "A source build is used as it is"
H="$SCRATCH/source"; make_home "$H" none "" serve
fake_binary "$H/Developer/che-msg/che-slack-mcp/.build/release/CheSlackMCP"
initialize 6 > "$H/in"
RC=$(run_wrapper "$H" "$H/in")
if [ "$RC" -eq 0 ]; then pass "exit status 0"; else fail "exit status $RC"; fi
check_started "$H" "$(cat "$H/in")"
if [ ! -e "$H/curl.calls" ]; then pass "no download attempted"; else fail "curl was called"; fi
if [ ! -e "$H/bin/CheSlackMCP" ] && [ ! -e "$H/bin/.CheSlackMCP.version" ]; then pass "nothing written to ~/bin"; else fail "~/bin was written"; fi

# ----------------------------------------------------------------------
test_case "Only the download cases reached curl, and nothing called security"
others=$(ls "$SCRATCH"/*/curl.calls 2>/dev/null \
    | grep -v -e '/nobinary/' -e '/nobinary-string/' -e '/download/' -e '/upgrade/' -e '/upgrade-fails/' || true)
if [ -z "$others" ]; then pass "curl called only by the download cases"; else fail "curl was called: $others"; fi
calls=$(ls "$SCRATCH"/*/security.calls 2>/dev/null || true)
if [ -z "$calls" ]; then pass "security never called in any case"; else fail "security called: $calls"; fi

echo ""
echo "Ran $TOTAL test cases, $FAIL failure(s)."
[ "$FAIL" -eq 0 ]
