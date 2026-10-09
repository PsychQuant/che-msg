#!/bin/bash
# Wrapper for che-telegram-all-mcp (personal account via TDLib)
# Credentials are read from macOS Keychain at runtime — never stored in config files.
#
# Auto-upgrade design (v1.3.0+):
# - DESIRED_VERSION below pins the binary version this plugin expects.
# - ~/bin/.CheTelegramAllMCP.version sidecar tracks what's installed.
# - On mismatch, re-downloads from GitHub Release (atomic .tmp + mv).
# - Source builds in $HOME/Developer/... are NEVER auto-replaced.

BINARY_NAME="CheTelegramAllMCP"
GITHUB_REPO="PsychQuant/che-msg"
INSTALL_DIR="$HOME/bin"
INSTALLED_BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
DESIRED_VERSION="0.6.0"
DOWNLOAD_TIMEOUT=600  # universal binary ~220MB; allow slow links

# --- Startup errors Claude Code can show (#31, PsychQuant/che-msg#58) ---
# When the wrapper exits before starting the server, Claude Code's MCP
# transport sees no response and shows a generic "-32000 Server error".
# Answering the pending initialize request with a JSON-RPC 2.0 error lets it
# show the reason instead. The wrapper stops early only for missing Keychain
# credentials or a binary it cannot obtain; another session running
# telegram-all never stops it (the server decides who opens TDLib).
#
# PR-1b (empirical-driven, 2026-05-22): Claude Code drops a response whose id
# is null as unmatched transport noise, so the error carries the id of the
# initialize request, read briefly from stdin.

# Read first line of stdin (expected: JSON-RPC initialize request) with a
# short timeout, extract the request id. Falls back to "null" if stdin is
# empty, times out, or doesn't contain valid JSON.
#
# Output format mirrors JSON literal: numeric id printed unquoted (e.g.
# `42`), string id wrapped in JSON quotes (e.g. `"abc"`), missing/invalid
# id returns `null`. Caller substitutes this directly into the JSON
# envelope's `"id":<x>` slot.
#
# Timeout is 2s — Claude Code MCP transport typically sends initialize
# within milliseconds of spawning the child process. Longer timeout
# would delay wrapper exit and could push Claude Code into its own
# transport timeout.
read_initialize_id() {
    local line=""
    local id="null"

    if IFS= read -r -t 2 line 2>/dev/null && [ -n "$line" ]; then
        if command -v jq >/dev/null 2>&1; then
            # jq -c outputs JSON-compact form: number unquoted, string with
            # quotes, null as literal `null`. Perfect for direct substitution.
            local extracted
            extracted=$(printf '%s' "$line" | jq -c '.id' 2>/dev/null || true)
            if [ -n "$extracted" ]; then
                id="$extracted"
            fi
        else
            # Fallback for environments without jq. Handles integer ids
            # and quoted string ids — covers MCP 1.0 spec (id is string,
            # number, or null per JSON-RPC 2.0).
            if [[ "$line" =~ \"id\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                id="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ \"id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                id="\"${BASH_REMATCH[1]}\""
            fi
        fi
    fi

    printf '%s' "$id"
}

# Emit a JSON-RPC 2.0 error answering the pending initialize request, then
# exit 1. $1 is the message and MUST NOT contain double quotes or backslashes
# (every caller passes a fixed literal), so the JSON needs no escaping.
fail_startup() {
    local message="$1"
    local request_id
    request_id=$(read_initialize_id)
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"%s","data":{"docsUrl":"https://github.com/PsychQuant/che-msg/blob/main/plugins/che-telegram-mcp/README.md#when-telegram-all-does-not-start"}}}\n' \
        "$request_id" "$message"
    exit 1
}

# Find binary — prefer $HOME/bin (installed from release) > source builds
BINARY=""
for loc in "$INSTALLED_BINARY" "/usr/local/bin/$BINARY_NAME" "$HOME/.local/bin/$BINARY_NAME" "$HOME/Developer/che-msg/che-telegram-all-mcp/.build/release/$BINARY_NAME" "$HOME/Developer/che-mcps/che-telegram-all-mcp/.build/release/$BINARY_NAME"; do
    [[ -x "$loc" ]] && BINARY="$loc" && break
done

# Decide whether to download.
NEED_DOWNLOAD=false
REASON=""
INSTALLED_VERSION=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)

if [[ -z "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ "$BINARY" == "$INSTALLED_BINARY" ]] && [[ "$INSTALLED_VERSION" != "$DESIRED_VERSION" ]]; then
    # Only auto-upgrade installed binaries; never touch source builds.
    NEED_DOWNLOAD=true
    REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading from $GITHUB_REPO..." >&2
    mkdir -p "$INSTALL_DIR"

    # Try pinned tag first, then fall back to latest release.
    URL=""
    for API_URL in \
        "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION" \
        "https://api.github.com/repos/$GITHUB_REPO/releases/latest"
    do
        URL=$(curl -sL --max-time 30 "$API_URL" 2>/dev/null \
            | grep '"browser_download_url"' | grep "/$BINARY_NAME\"" | head -1 \
            | sed 's/.*"\(https[^"]*\)".*/\1/')
        [[ -n "$URL" ]] && break
    done

    if [[ -z "$URL" ]]; then
        if [[ -x "$INSTALLED_BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — no download URL found, keeping existing binary" >&2
            BINARY="$INSTALLED_BINARY"
        else
            echo "$BINARY_NAME: ERROR — no release asset found at $GITHUB_REPO." >&2
            echo "  Install manually: https://github.com/$GITHUB_REPO/releases" >&2
            echo "  Or build from source:" >&2
            echo "    git clone https://github.com/$GITHUB_REPO.git ~/Developer/che-msg" >&2
            echo "    cd ~/Developer/che-msg/che-telegram-all-mcp && swift build -c release --product $BINARY_NAME" >&2
            fail_startup "CheTelegramAllMCP is not installed and no release asset was found to download. Install it by hand as the che-telegram-mcp README describes, then reconnect with /mcp."
        fi
    else
        if curl -sL --max-time "$DOWNLOAD_TIMEOUT" "$URL" -o "${INSTALLED_BINARY}.tmp" 2>/dev/null; then
            chmod +x "${INSTALLED_BINARY}.tmp"
            xattr -dr com.apple.quarantine "${INSTALLED_BINARY}.tmp" 2>/dev/null || true
            mv "${INSTALLED_BINARY}.tmp" "$INSTALLED_BINARY"
            echo "$DESIRED_VERSION" > "$VERSION_FILE"
            echo "$BINARY_NAME: installed v$DESIRED_VERSION" >&2
            BINARY="$INSTALLED_BINARY"
        else
            rm -f "${INSTALLED_BINARY}.tmp" 2>/dev/null
            if [[ -x "$INSTALLED_BINARY" ]]; then
                echo "$BINARY_NAME: WARNING — download failed, keeping existing binary" >&2
                BINARY="$INSTALLED_BINARY"
            else
                echo "$BINARY_NAME: ERROR — download failed" >&2
                fail_startup "Downloading CheTelegramAllMCP failed. Check the network, or install it by hand as the che-telegram-mcp README describes, then reconnect with /mcp."
            fi
        fi
    fi
fi

# Read credentials from macOS Keychain
export TELEGRAM_API_ID="$(security find-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_API_ID" -w 2>/dev/null)"
export TELEGRAM_API_HASH="$(security find-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_API_HASH" -w 2>/dev/null)"

if [[ -z "$TELEGRAM_API_ID" || -z "$TELEGRAM_API_HASH" ]]; then
    echo "Telegram API credentials not found in Keychain." >&2
    echo "Set them up:" >&2
    echo "  security add-generic-password -a che-telegram-all-mcp -s TELEGRAM_API_ID -w 'YOUR_ID' -U" >&2
    echo "  security add-generic-password -a che-telegram-all-mcp -s TELEGRAM_API_HASH -w 'YOUR_HASH' -U" >&2
    echo "Get credentials at: https://my.telegram.org" >&2
    fail_startup "Telegram API credentials are not in the Keychain. Store TELEGRAM_API_ID and TELEGRAM_API_HASH as the che-telegram-mcp README describes, then reconnect with /mcp."
fi

# --- Start the server ---
# Several Claude Code sessions may each run one. The server takes TDLib's lock
# only when a tool first needs TDLib and releases it when idle; while another
# process holds it, read tools answer from TDLib's local cache
# (PsychQuant/che-msg#58). So the wrapper takes no lock, keeps no shared PID
# file, and sends signals only to the binary it started itself: an earlier
# version killed "the previous PID" from a shared file, which without a lock
# would have stopped another session's server.
#
# Fork + wait + trap（不能用 exec，因為 exec 會取代 shell，無法 trap cleanup）
# CRITICAL: `<&0` explicitly inherits wrapper's stdin. Without it, POSIX/bash
# redirects backgrounded (&) command's stdin to /dev/null, breaking MCP
# stdio JSON-RPC protocol (#8 follow-up bug).
"$BINARY" "$@" <&0 &
BIN_PID=$!

cleanup() {
    if [[ -n "$BIN_PID" ]] && kill -0 "$BIN_PID" 2>/dev/null; then
        kill -TERM "$BIN_PID" 2>/dev/null
        # Wait up to 2s for graceful shutdown
        for _ in 1 2 3 4; do
            kill -0 "$BIN_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -0 "$BIN_PID" 2>/dev/null && kill -KILL "$BIN_PID" 2>/dev/null
        wait "$BIN_PID" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

wait "$BIN_PID"
exit $?
