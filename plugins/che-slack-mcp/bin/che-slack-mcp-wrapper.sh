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
# - On a mismatch it downloads that release's asset again (.tmp, then mv).
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

    # -f: an HTTP error (404 before the release exists) is a failure, not a
    # page saved as the binary.
    URL=$(curl -fsSL --max-time 30 "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION" 2>/dev/null \
        | grep '"browser_download_url"' | grep "/$BINARY_NAME\"" | head -1 \
        | sed 's/.*"\(https[^"]*\)".*/\1/')

    if [[ -n "$URL" ]] && curl -fsSL --max-time "$DOWNLOAD_TIMEOUT" "$URL" -o "${INSTALLED_BINARY}.tmp" 2>/dev/null; then
        chmod +x "${INSTALLED_BINARY}.tmp"
        xattr -dr com.apple.quarantine "${INSTALLED_BINARY}.tmp" 2>/dev/null || true
        mv "${INSTALLED_BINARY}.tmp" "$INSTALLED_BINARY"
        echo "$DESIRED_VERSION" > "$VERSION_FILE"
        echo "$BINARY_NAME: installed v$DESIRED_VERSION" >&2
        BINARY="$INSTALLED_BINARY"
    else
        rm -f "${INSTALLED_BINARY}.tmp" 2>/dev/null
        if [[ -n "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — download of v$DESIRED_VERSION failed, keeping existing binary" >&2
        else
            echo "$BINARY_NAME: ERROR — could not download $BINARY_NAME v$DESIRED_VERSION from $GITHUB_REPO." >&2
            echo "  Install it by hand: https://github.com/$GITHUB_REPO/releases/tag/v$DESIRED_VERSION" >&2
            echo "  Or build it from source:" >&2
            echo "    git clone https://github.com/$GITHUB_REPO.git ~/Developer/che-msg" >&2
            echo "    cd ~/Developer/che-msg/che-slack-mcp && swift build -c release" >&2
            fail_startup "CheSlackMCP is not installed and v$DESIRED_VERSION could not be downloaded. Install or build it as the che-slack-mcp README describes, then reconnect with /mcp."
        fi
    fi
fi

# --- Start the server ---
# The Slack Web API is stateless HTTP and the server holds no local lock that
# outlives it, so the wrapper simply becomes the binary; stdin, stdout and the
# environment (including SLACK_MCP_MIN_INTERVAL_MS and
# SLACK_MCP_MAX_CONCURRENCY) pass through unchanged.
exec "$BINARY" "$@"
