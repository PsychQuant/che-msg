#!/bin/bash
# Runs the real che-telegram-all-mcp wrapper against a private HOME
# (PsychQuant/che-msg#58). Sourced by the che-telegram-mcp wrapper tests.
#
# The HOME holds a fake CheTelegramAllMCP at $HOME/bin with the version
# sidecar the wrapper expects, so the wrapper starts it without downloading.
# A fake `security` answers the two Keychain lookups, and a fake `curl` records
# any call and fails, so a test can never reach the network. Nothing outside
# the private HOME is read or written.

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# WRAPPER_UNDER_TEST runs the tests against another copy, e.g. an earlier version.
WRAPPER="${WRAPPER_UNDER_TEST:-$HARNESS_ROOT/plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh}"
DESIRED_VERSION=$(sed -n 's/^DESIRED_VERSION="\(.*\)"$/\1/p' "$WRAPPER")

# make_home <dir> [credentials: yes|no] [binary version | "silent"]
# The fake binary answers --version with the given version (default: the
# wrapper's DESIRED_VERSION), or not at all with "silent", as binaries before
# 0.6.0 do. Started as a server, it appends its PID to $HOME/started.pids,
# writes the first stdin line it reads to $HOME/stdin.txt, then sleeps until
# signalled.
make_home() {
    local home=$1 credentials=${2:-yes} version=${3:-$DESIRED_VERSION}
    mkdir -p "$home/bin" "$home/fakebin"
    {
        echo '#!/bin/bash'
        if [ "$version" != silent ]; then
            echo "if [ \"\$1\" = --version ]; then echo 'che-telegram-all-mcp $version'; exit 0; fi"
        fi
    } > "$home/bin/CheTelegramAllMCP"
    cat >> "$home/bin/CheTelegramAllMCP" <<'EOF'
echo $$ >> "$HOME/started.pids"
if IFS= read -r -t 2 line; then printf '%s\n' "$line" > "$HOME/stdin.txt"; fi
exec /bin/sleep 300
EOF
    chmod +x "$home/bin/CheTelegramAllMCP"
    if [ "$version" = silent ]; then echo "$DESIRED_VERSION"; else echo "$version"; fi > "$home/bin/.CheTelegramAllMCP.version"
    if [ "$credentials" = yes ]; then
        cat > "$home/fakebin/security" <<'EOF'
#!/bin/bash
case "$*" in
    *TELEGRAM_API_ID*) echo 12345 ;;
    *TELEGRAM_API_HASH*) echo fakehash ;;
    *) exit 44 ;;
esac
EOF
    else
        printf '#!/bin/bash\nexit 44\n' > "$home/fakebin/security"
    fi
    printf '#!/bin/bash\necho "$*" >> "$HOME/curl.calls"\nexit 1\n' > "$home/fakebin/curl"
    chmod +x "$home/fakebin/security" "$home/fakebin/curl"
}

# start_wrapper <home> <stdin-file> <stdout-file>: starts the wrapper in the
# background and prints its PID.
start_wrapper() {
    local home=$1 input=$2 output=$3
    HOME="$home" PATH="$home/fakebin:$PATH" bash "$WRAPPER" < "$input" > "$output" 2>> "$home/wrapper.stderr" &
    echo $!
}

# alive <pid>: true while the process exists and is not a zombie.
alive() {
    local state
    state=$(ps -o state= -p "$1" 2>/dev/null | tr -d ' ')
    [ -n "$state" ] && [ "${state:0:1}" != "Z" ]
}

# wait_until <seconds> <command...>: polls every 0.1 s.
wait_until() {
    local limit=$1; shift
    local tries=$((limit * 10))
    while [ "$tries" -gt 0 ]; do
        "$@" && return 0
        sleep 0.1
        tries=$((tries - 1))
    done
    return 1
}

# pid_count <home>: how many fake binaries have started.
pid_count() {
    [ -f "$1/started.pids" ] && wc -l < "$1/started.pids" | tr -d ' ' || echo 0
}

has_pids() { [ "$(pid_count "$1")" -ge "$2" ]; }

# nth_pid <home> <n>: PID of the n-th fake binary started (1-based).
nth_pid() {
    sed -n "${2}p" "$1/started.pids"
}

# stop <pid>: TERM, then wait up to 4 s for it to go.
stop() {
    kill -TERM "$1" 2>/dev/null
    wait_until 4 bash -c "! ps -o state= -p $1 2>/dev/null | grep -q '[^Z ]'" || kill -KILL "$1" 2>/dev/null
    wait "$1" 2>/dev/null
}
