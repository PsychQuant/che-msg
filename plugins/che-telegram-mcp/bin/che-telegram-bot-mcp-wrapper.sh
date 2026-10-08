#!/bin/bash
# Wrapper for che-telegram-bot-mcp (Bot API)
# Bot token is read from macOS Keychain at runtime.
#
# Auto-upgrade design (v1.3.0+):
# - DESIRED_VERSION below pins the binary version this plugin expects.
# - ~/bin/.CheTelegramBotMCP.version sidecar tracks what's installed.
# - On mismatch, re-downloads from GitHub Release (atomic .tmp + mv).
# - Source builds in $HOME/Developer/... are NEVER auto-replaced.

BINARY_NAME="CheTelegramBotMCP"
GITHUB_REPO="PsychQuant/che-msg"
INSTALL_DIR="$HOME/bin"
INSTALLED_BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
DESIRED_VERSION="0.5.0"
DOWNLOAD_TIMEOUT=180  # bot binary is small (~30MB)

# Find binary
BINARY=""
for loc in "$INSTALLED_BINARY" "/usr/local/bin/$BINARY_NAME" "$HOME/.local/bin/$BINARY_NAME" "$HOME/Developer/che-msg/che-telegram-bot-mcp/.build/release/$BINARY_NAME" "$HOME/Developer/che-mcps/che-telegram-bot-mcp/.build/release/$BINARY_NAME"; do
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
    NEED_DOWNLOAD=true
    REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading from $GITHUB_REPO..." >&2
    mkdir -p "$INSTALL_DIR"

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
            echo "    cd ~/Developer/che-msg/che-telegram-bot-mcp && swift build -c release --product $BINARY_NAME" >&2
            exit 1
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
                exit 1
            fi
        fi
    fi
fi

# Read bot token from macOS Keychain
export TELEGRAM_BOT_TOKEN="$(security find-generic-password -a "che-telegram-bot-mcp" -s "TELEGRAM_BOT_TOKEN" -w 2>/dev/null)"

if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    echo "Bot token not found in Keychain." >&2
    echo "Set it up:" >&2
    echo "  security add-generic-password -a che-telegram-bot-mcp -s TELEGRAM_BOT_TOKEN -w 'YOUR_TOKEN' -U" >&2
    echo "Get a token from @BotFather on Telegram." >&2
    exit 1
fi

# NOTE: bot-mcp 不需要 local resource PID tracking (#12)
# Bot API 是 HTTPS client，本地端 **沒有** local DB / file lock / binlog
# 這類 single-instance resource。所以 #8 引入的 PID file + orphan cleanup
# 對 bot-mcp 不適用。getUpdates long-polling race 應該由 server-side
# locking 處理，不是 wrapper PID tracking（見 #10 follow-up）。
exec "$BINARY" "$@"
