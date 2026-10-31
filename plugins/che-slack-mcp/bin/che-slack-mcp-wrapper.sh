#!/bin/bash
# Wrapper for che-slack-mcp (Slack, signed in as you with a browser session).
#
# This wrapper reads no credential and exports none. CheSlackMCP reads each
# workspace's session from the macOS Keychain itself, on every tool call, so
# no token or cookie passes through this script, the environment or the
# command line. Workspaces are imported in a terminal with `slack-all auth
# import` (see the plugin README).
#
# Auto-upgrade, as in che-telegram-mcp:
# - DESIRED_VERSION below pins the binary version this plugin expects.
# - ~/bin/.CheSlackMCP.version records what the wrapper installed.
# - On a mismatch it downloads that release's asset again, to a temporary
#   file of its own, and installs it under a lock ("Download and install").
# - Only the pinned release is asked for, never releases/latest: a newer
#   binary under the pinned version's sidecar would no longer be a pin.
# - Builds under $HOME/Developer/... are never replaced.

BINARY_NAME="CheSlackMCP"
GITHUB_REPO="PsychQuant/che-msg"
INSTALL_DIR="$HOME/bin"
INSTALLED_BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
DESIRED_VERSION="0.9.0"
DOWNLOAD_TIMEOUT=180

# --- Startup errors Claude Code can show (as in che-telegram-mcp, #31) ---
# When the wrapper exits before starting the server, Claude Code shows only a
# generic "-32000 Server error". Answering the pending initialize request with
# a JSON-RPC 2.0 error lets /mcp show the reason. Claude Code drops a response
# whose id is null, so the error carries the id of the initialize request,
# read from the first stdin line (2 s at most).
read_initialize_id() {
    local line=""
    local id="null"

    if IFS= read -r -t 2 line 2>/dev/null && [ -n "$line" ]; then
        if command -v jq >/dev/null 2>&1; then
            local extracted
            extracted=$(printf '%s' "$line" | jq -c '.id' 2>/dev/null || true)
            if [ -n "$extracted" ]; then
                id="$extracted"
            fi
        else
            if [[ "$line" =~ \"id\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                id="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ \"id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                id="\"${BASH_REMATCH[1]}\""
            fi
        fi
    fi

    printf '%s' "$id"
}

# Emit the JSON-RPC 2.0 error, then exit 1. $1 MUST NOT contain double quotes
# or backslashes (callers pass fixed literals and version numbers only).
fail_startup() {
    local message="$1"
    local request_id
    request_id=$(read_initialize_id)
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"%s","data":{"docsUrl":"https://github.com/PsychQuant/che-msg/blob/main/plugins/che-slack-mcp/README.md#when-slack-does-not-start"}}}\n' \
        "$request_id" "$message"
    exit 1
}

# --- Download and install (#99) ---
# Every Claude Code session can start this wrapper, so several may download at
# once. Each downloads to a temporary file of its own next to the installed
# binary, so the final mv is an atomic rename on one filesystem. The install
# (chmod, mv, sidecar) runs under a lock, after reading the sidecar again: when
# another start has installed the pinned version meanwhile, the download is
# discarded. The sidecar is written, and "installed" reported, only after chmod
# and mv succeeded; otherwise the wrapper falls back as for a failed download.
#
# The lock is a directory (mkdir is atomic) holding its owner's PID. It is
# stale when that PID no longer runs, or when it is older than
# LOCK_STALE_MINUTES: its owner only renames files, so an older lock was left
# by a process killed before it wrote its PID, or one whose PID now belongs to
# another process. A stale lock is taken over. A live one is waited for,
# polling every 0.2 s for LOCK_WAIT_SECONDS at most; then the install is
# skipped. Two starts taking over the same stale lock may both install, which
# still never leaves a partial binary: each moves a complete file into place.
LOCK_DIR="$INSTALL_DIR/.${BINARY_NAME}.lock"
LOCK_WAIT_SECONDS=60
LOCK_STALE_MINUTES=5
LOCK_HELD=false
TMP_BINARY=""
INSTALL_RESULT=""

lock_is_stale() {
    local owner
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
        return 0
    fi
    [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null)" ]]
}

acquire_install_lock() {
    local polls=$((LOCK_WAIT_SECONDS * 5))
    while (( polls > 0 )); do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            LOCK_HELD=true
            echo "$$" > "$LOCK_DIR/pid"
            return 0
        fi
        polls=$((polls - 1))
        if lock_is_stale; then
            echo "$BINARY_NAME: taking over the stale install lock $LOCK_DIR" >&2
            mv -f "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null && rm -rf "$LOCK_DIR.stale.$$"
        else
            sleep 0.2
        fi
    done
    return 1
}

release_install_lock() {
    $LOCK_HELD || return 0
    LOCK_HELD=false
    # Only while the lock is still ours: a waiter may have taken it over.
    [[ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" == "$$" ]] || return 0
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null
}

# Removes this start's temporary file and lock; also the EXIT trap.
cleanup_install() {
    if [[ -n "$TMP_BINARY" ]]; then
        rm -f "$TMP_BINARY"
        TMP_BINARY=""
    fi
    release_install_lock
}

# With the lock held: sets INSTALL_RESULT to present (another start installed
# the pinned version), installed, or install-failed.
install_download() {
    local current=""
    [[ -f "$VERSION_FILE" ]] && current=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)
    if [[ "$current" == "$DESIRED_VERSION" ]] && [[ -x "$INSTALLED_BINARY" ]]; then
        INSTALL_RESULT=present
        return
    fi
    INSTALL_RESULT=install-failed
    chmod 755 "$TMP_BINARY" || return
    xattr -dr com.apple.quarantine "$TMP_BINARY" 2>/dev/null || true
    mv -f "$TMP_BINARY" "$INSTALLED_BINARY" || return
    TMP_BINARY=""
    if ! echo "$DESIRED_VERSION" > "$VERSION_FILE"; then
        echo "$BINARY_NAME: WARNING — could not write $VERSION_FILE; the next start downloads v$DESIRED_VERSION again" >&2
    fi
    INSTALL_RESULT=installed
}

# Find the binary: the copy this wrapper installs first, then source builds.
BINARY=""
for loc in "$INSTALLED_BINARY" "/usr/local/bin/$BINARY_NAME" "$HOME/.local/bin/$BINARY_NAME" "$HOME/Developer/che-msg/che-slack-mcp/.build/release/$BINARY_NAME"; do
    [[ -x "$loc" ]] && BINARY="$loc" && break
done

NEED_DOWNLOAD=false
REASON=""
INSTALLED_VERSION=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)

if [[ -z "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ "$BINARY" == "$INSTALLED_BINARY" ]] && [[ "$INSTALLED_VERSION" != "$DESIRED_VERSION" ]]; then
    # Only the copy in ~/bin is upgraded; other locations are left alone.
    NEED_DOWNLOAD=true
    REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading v$DESIRED_VERSION from $GITHUB_REPO..." >&2
    mkdir -p "$INSTALL_DIR"
    trap cleanup_install EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # -f: an HTTP error (404 before the release exists) is a failure, not a
    # page saved as the binary.
    URL=$(curl -fsSL --max-time 30 "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION" 2>/dev/null \
        | grep '"browser_download_url"' | grep "/$BINARY_NAME\"" | head -1 \
        | sed 's/.*"\(https[^"]*\)".*/\1/')

    INSTALL_RESULT=download-failed
    if [[ -n "$URL" ]] && TMP_BINARY=$(mktemp "${INSTALLED_BINARY}.XXXXXX" 2>/dev/null) \
        && curl -fsSL --max-time "$DOWNLOAD_TIMEOUT" "$URL" -o "$TMP_BINARY" 2>/dev/null; then
        if acquire_install_lock; then
            install_download
        else
            INSTALL_RESULT=lock-busy
        fi
    fi
    cleanup_install

    PROBLEM=""
    case "$INSTALL_RESULT" in
        installed)
            echo "$BINARY_NAME: installed v$DESIRED_VERSION" >&2
            BINARY="$INSTALLED_BINARY" ;;
        present)
            echo "$BINARY_NAME: v$DESIRED_VERSION was installed by another start meanwhile" >&2
            BINARY="$INSTALLED_BINARY" ;;
        download-failed) PROBLEM="download of v$DESIRED_VERSION failed" ;;
        install-failed) PROBLEM="install of v$DESIRED_VERSION in $INSTALL_DIR failed" ;;
        lock-busy) PROBLEM="another start held the install lock $LOCK_DIR for ${LOCK_WAIT_SECONDS} s" ;;
    esac

    if [[ -n "$PROBLEM" ]] && [[ -n "$BINARY" ]]; then
        echo "$BINARY_NAME: WARNING — $PROBLEM, keeping existing binary" >&2
    elif [[ -n "$PROBLEM" ]]; then
        if [[ "$INSTALL_RESULT" == download-failed ]]; then
            echo "$BINARY_NAME: ERROR — could not download $BINARY_NAME v$DESIRED_VERSION from $GITHUB_REPO." >&2
            STARTUP_ERROR="CheSlackMCP is not installed and v$DESIRED_VERSION could not be downloaded."
        else
            echo "$BINARY_NAME: ERROR — $PROBLEM, and $BINARY_NAME is not installed." >&2
            STARTUP_ERROR="CheSlackMCP is not installed and v$DESIRED_VERSION could not be installed in ~/bin."
        fi
        echo "  Install it by hand: https://github.com/$GITHUB_REPO/releases/tag/v$DESIRED_VERSION" >&2
        echo "  Or build it from source:" >&2
        echo "    git clone https://github.com/$GITHUB_REPO.git ~/Developer/che-msg" >&2
        echo "    cd ~/Developer/che-msg/che-slack-mcp && swift build -c release" >&2
        fail_startup "$STARTUP_ERROR Install or build it as the che-slack-mcp README describes, then reconnect with /mcp."
    fi
fi

# --- Start the server ---
# The Slack Web API is stateless HTTP and the server holds no local lock that
# outlives it, so the wrapper simply becomes the binary; stdin, stdout and the
# environment (including SLACK_MCP_MIN_INTERVAL_MS and
# SLACK_MCP_MAX_CONCURRENCY) pass through unchanged.
trap - EXIT HUP INT TERM
exec "$BINARY" "$@"
