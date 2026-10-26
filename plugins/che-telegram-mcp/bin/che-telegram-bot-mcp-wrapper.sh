#!/bin/bash
# Wrapper for che-telegram-bot-mcp (Bot API)
# Bot token is read from macOS Keychain at runtime.
#
# Auto-upgrade design (v1.3.0+):
# - DESIRED_VERSION below pins the binary version this plugin expects.
# - ~/bin/.CheTelegramBotMCP.version sidecar tracks what's installed.
# - With no binary installed, downloads it. Once one is installed in ~/bin,
#   re-downloads from GitHub Release only when the sidecar is older than the
#   pin, missing, or not a plain x.y.z; a binary newer than the pin is kept
#   (PsychQuant/che-msg#83).
# - The download (lib/download.sh, shared with the telegram-all wrapper)
#   retries, resumes a cut-off transfer from a version-named partial file,
#   refuses an HTTP error, and lets one process at a time write
#   (PsychQuant/che-msg#56). It installs nothing whose sha256 does not match
#   (PsychQuant/che-msg#50). This wrapper has no --version probe, so what the
#   download refuses is all that keeps a bad file from being run. It runs in
#   the background, never on the startup path (PsychQuant/che-msg#67).
# - Source builds in $HOME/Developer/... are NEVER auto-replaced.

BINARY_NAME="CheTelegramBotMCP"
GITHUB_REPO="PsychQuant/che-msg"
INSTALL_DIR="$HOME/bin"
INSTALLED_BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
DESIRED_VERSION="0.9.0"
# The sha256 of the v$DESIRED_VERSION release asset, and the version it was
# taken from (PsychQuant/che-msg#50). A download is installed only if its
# sha256 equals SHA256_PIN; the pin counts only while SHA256_PIN_VERSION equals
# DESIRED_VERSION. A release sets both after its build (RELEASING.md); a version
# bump clears them. Empty for 0.8.0, which was released before pins existed:
# the download is then checked against the sha256 digest GitHub's release API
# reports, which catches a damaged file but not a replaced asset.
SHA256_PIN_VERSION=""
SHA256_PIN=""
# The pinned release only, never releases/latest: a pin could not match it.
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME"
RELEASE_API_URL="https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION"

# lib/download.sh downloads and installs the binary for both wrappers, and
# holds version_at_least and read_version_record (PsychQuant/che-msg#56).
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
if [[ -z "$PLUGIN_ROOT" ]] || ! source "$PLUGIN_ROOT/lib/download.sh"; then
    echo "$BINARY_NAME: ERROR — the plugin's lib/download.sh cannot be read; reinstall the che-telegram-mcp plugin" >&2
    exit 1
fi

# Find binary
BINARY=""
for loc in "$INSTALLED_BINARY" "/usr/local/bin/$BINARY_NAME" "$HOME/.local/bin/$BINARY_NAME" "$HOME/Developer/che-msg/che-telegram-bot-mcp/.build/release/$BINARY_NAME" "$HOME/Developer/che-mcps/che-telegram-bot-mcp/.build/release/$BINARY_NAME"; do
    [[ -x "$loc" ]] && BINARY="$loc" && break
done

# Decide whether to download. With no binary installed it always does; for the
# copy in ~/bin, only an older, missing or unreadable sidecar triggers it: a
# session still running an older plugin must not put its older binary back
# over a newer one (PsychQuant/che-msg#83).
NEED_DOWNLOAD=false
REASON=""
INSTALLED_VERSION=$(read_version_record "$VERSION_FILE")

if [[ -z "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ "$BINARY" == "$INSTALLED_BINARY" ]] && ! version_at_least "$INSTALLED_VERSION" "$DESIRED_VERSION"; then
    NEED_DOWNLOAD=true
    if [[ "$INSTALLED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION}"
    else
        REASON="plugin wants v${DESIRED_VERSION}, and the version record is missing or not x.y.z"
    fi
fi

# Downloading in the background (PsychQuant/che-msg#67): the download never
# runs on the startup path (lib/download.sh). An installed binary is started at
# once; the version downloaded is used from the first start after it is
# installed. With none, the wrapper waits FIRST_INSTALL_WAIT seconds for the
# download, then says what is happening and exits; the download goes on.
DOWNLOAD_SIZE="about 18 MB"   # told to the user on a first install
FIRST_INSTALL_WAIT=$(install_wait_seconds 3)   # CHE_TELEGRAM_MCP_INSTALL_WAIT overrides
if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading v$DESIRED_VERSION from $GITHUB_REPO in the background (log: ~/bin/.$BINARY_NAME.download.log)" >&2
    download_start "$BINARY_NAME" "$DESIRED_VERSION" "$DOWNLOAD_URL" "$INSTALL_DIR" \
        "$SHA256_PIN_VERSION" "$SHA256_PIN" "$RELEASE_API_URL"
    if [[ -n "$BINARY" ]]; then
        echo "$BINARY_NAME: running the installed binary meanwhile; the first start after the download uses v$DESIRED_VERSION" >&2
    else
        download_wait "$BINARY_NAME" "$DESIRED_VERSION" "$INSTALL_DIR" "$FIRST_INSTALL_WAIT"
        case "$DOWNLOAD_STATE" in
            installed)
                BINARY="$INSTALLED_BINARY" ;;
            running)
                echo "$BINARY_NAME: v$DESIRED_VERSION is not installed yet: it is downloading in the background ($DOWNLOAD_SIZE$(download_progress "$BINARY_NAME" "$DESIRED_VERSION" "$INSTALL_DIR"))." >&2
                echo "  Reconnect with /mcp in a minute, once it has finished; the download goes on and resumes if it is interrupted." >&2
                exit 1 ;;
            *)
                echo "$BINARY_NAME: ERROR — v$DESIRED_VERSION not installed: $(download_failure "$DOWNLOAD_STATUS")." >&2
                echo "  Reconnect with /mcp to try again." >&2
                download_manual_hint "$BINARY_NAME" "$DESIRED_VERSION" "$DOWNLOAD_URL" "$SHA256_PIN_VERSION" "$SHA256_PIN"
                exit 1 ;;
        esac
    fi
fi

# Read bot token from macOS Keychain
export TELEGRAM_BOT_TOKEN="$(security find-generic-password -a "che-telegram-bot-mcp" -s "TELEGRAM_BOT_TOKEN" -w 2>/dev/null)"

if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    echo "Bot token not found in Keychain." >&2
    echo "Set it up in your own terminal (security prompts for the value):" >&2
    echo "  security add-generic-password -a che-telegram-bot-mcp -s TELEGRAM_BOT_TOKEN -U -w" >&2
    echo "Get a token from @BotFather on Telegram." >&2
    exit 1
fi

# NOTE: bot-mcp 不需要 local resource PID tracking (#12)
# Bot API 是 HTTPS client，本地端 **沒有** local DB / file lock / binlog
# 這類 single-instance resource。所以 #8 引入的 PID file + orphan cleanup
# 對 bot-mcp 不適用。getUpdates long-polling race 應該由 server-side
# locking 處理，不是 wrapper PID tracking（見 #10 follow-up）。
exec "$BINARY" "$@"
