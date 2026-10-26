#!/bin/bash
# Runs the real che-telegram-all-mcp wrapper against a private HOME
# (PsychQuant/che-msg#58). Sourced by the che-telegram-mcp wrapper tests.
#
# The HOME holds a fake CheTelegramAllMCP at $HOME/bin with the version
# sidecar the wrapper expects, so the wrapper starts it without downloading.
# A fake `security` answers the two Keychain lookups, and a fake `curl`
# (tests/lib/fake_curl.sh) records every call and, unless the test gives it
# something to serve, fails, so a test can never reach the network. Nothing
# outside the private HOME is read or written.

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# WRAPPER_UNDER_TEST runs the tests against another copy, e.g. an earlier version.
WRAPPER="${WRAPPER_UNDER_TEST:-$HARNESS_ROOT/plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh}"
DESIRED_VERSION=$(sed -n 's/^DESIRED_VERSION="\(.*\)"$/\1/p' "$WRAPPER")
BOT_WRAPPER="${BOT_WRAPPER_UNDER_TEST:-$HARNESS_ROOT/plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh}"
BOT_DESIRED=$(sed -n 's/^DESIRED_VERSION="\(.*\)"$/\1/p' "$BOT_WRAPPER")

# make_home <dir> [credentials: yes|no] [binary version | "silent"]
# The fake binary answers --version with the given version (default: the
# wrapper's DESIRED_VERSION), or not at all with "silent", as binaries before
# 0.6.0 do. Started as a server, it appends its PID to $HOME/started.pids,
# writes the first stdin line it reads to $HOME/stdin.txt, then sleeps until
# signalled.
make_home() {
    local home=$1 credentials=${2:-yes} version=${3:-$DESIRED_VERSION}
    mkdir -p "$home/bin" "$home/fakebin"
    write_fake_all_binary "$home/bin/CheTelegramAllMCP" "$version"
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
    install_fake_curl "$home"
    chmod +x "$home/fakebin/security"
}

# write_fake_all_binary <path> <version | "silent">: the fake CheTelegramAllMCP
# make_home installs, also used as the release asset the fake curl serves.
write_fake_all_binary() {
    local path=$1 version=$2
    {
        echo '#!/bin/bash'
        if [ "$version" != silent ]; then
            echo "if [ \"\$1\" = --version ]; then echo 'che-telegram-all-mcp $version'; exit 0; fi"
        fi
    } > "$path"
    cat >> "$path" <<'EOF'
echo $$ >> "$HOME/started.pids"
if IFS= read -r -t 2 line; then printf '%s\n' "$line" > "$HOME/stdin.txt"; fi
exec /bin/sleep 300
EOF
    chmod +x "$path"
}

# make_bot_home <dir> <record content | "-">: an installed fake bot binary that
# records its start and exits, its version record (none with "-"), a `security`
# that returns a bot token, and the fake curl.
make_bot_home() {
    local home=$1 record=$2
    mkdir -p "$home/bin" "$home/fakebin"
    write_fake_bot_binary "$home/bin/CheTelegramBotMCP"
    if [ "$record" != - ]; then printf '%s' "$record" > "$home/bin/.CheTelegramBotMCP.version"; fi
    printf '#!/bin/bash\ncase "$*" in *TELEGRAM_BOT_TOKEN*) echo 123:faketoken ;; *) exit 44 ;; esac\n' > "$home/fakebin/security"
    chmod +x "$home/fakebin/security"
    install_fake_curl "$home"
}

# write_fake_bot_binary <path>: a fake CheTelegramBotMCP that records its start.
write_fake_bot_binary() {
    printf '#!/bin/bash\necho $$ >> "$HOME/started.pids"\n' > "$1"
    chmod +x "$1"
}

# install_fake_curl <home>: the scriptable fake curl in <home>/fakebin.
install_fake_curl() {
    mkdir -p "$1/fakebin"
    cp "$HARNESS_ROOT/tests/lib/fake_curl.sh" "$1/fakebin/curl"
    chmod +x "$1/fakebin/curl"
}

# serve_asset <home> <file>: the fake curl serves <file> for a release download.
serve_asset() {
    mkdir -p "$1/fake-curl"
    cp "$2" "$1/fake-curl/asset"
}

# serve_release_api <home> <binary name> <file> [version]: the fake curl answers
# the release API with a release that lists <binary name>, with the sha256 of
# <file> as its digest, after another asset with a different digest. The layout
# is GitHub's: pretty-printed, each asset's digest before its download URL.
serve_release_api() {
    local home=$1 name=$2 file=$3 version=${4:-$DESIRED_VERSION} digest
    digest=$(shasum -a 256 "$file" | awk '{print $1}')
    mkdir -p "$home/fake-curl"
    cat > "$home/fake-curl/api" <<EOF
{
  "url": "https://api.github.com/repos/PsychQuant/che-msg/releases/1",
  "tag_name": "v$version",
  "assets": [
    {
      "url": "https://api.github.com/repos/PsychQuant/che-msg/releases/assets/1",
      "name": "$name.mcpb",
      "uploader": {
        "login": "someone"
      },
      "size": 10,
      "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      "browser_download_url": "https://github.com/PsychQuant/che-msg/releases/download/v$version/$name.mcpb"
    },
    {
      "url": "https://api.github.com/repos/PsychQuant/che-msg/releases/assets/2",
      "name": "$name",
      "uploader": {
        "login": "someone"
      },
      "size": $(wc -c < "$file" | tr -d ' '),
      "digest": "sha256:$digest",
      "browser_download_url": "https://github.com/PsychQuant/che-msg/releases/download/v$version/$name"
    }
  ]
}
EOF
}

# wrapper_copy <wrapper> <dir>: a copy of the wrapper at <dir>/bin/, next to a
# copy of the plugin's lib/ at <dir>/lib/, as the wrapper finds it in the
# plugin; prints the copy's path. The test edits the copy, never the original.
wrapper_copy() {
    local src=$1 dir=$2
    mkdir -p "$dir/bin"
    cp -R "$HARNESS_ROOT/plugins/che-telegram-mcp/lib" "$dir/lib"
    cp "$src" "$dir/bin/$(basename "$src")"
    echo "$dir/bin/$(basename "$src")"
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
