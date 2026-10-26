#!/bin/bash
# Wrapper for che-telegram-all-mcp (personal account via TDLib)
# Credentials are read from macOS Keychain at runtime — never stored in config files.
#
# Auto-upgrade design (v1.3.0+):
# - DESIRED_VERSION below pins the binary version this plugin expects.
# - ~/bin/.CheTelegramAllMCP.version sidecar tracks what's installed.
# - With no binary installed, downloads it. Once one is installed in ~/bin,
#   re-downloads from GitHub Release only when the sidecar is older than the
#   pin, missing, or not a plain x.y.z; a binary newer than the pin is kept
#   (PsychQuant/che-msg#83).
# - The download (lib/download.sh, shared with the bot wrapper) retries,
#   resumes a cut-off transfer from a version-named partial file, refuses an
#   HTTP error, and lets one process at a time write (PsychQuant/che-msg#56).
#   It installs nothing whose sha256 does not match (PsychQuant/che-msg#50).
#   It runs in the background, never on the startup path: an installed binary
#   of 0.7.0 or later runs meanwhile (PsychQuant/che-msg#67).
# - Source builds in $HOME/Developer/... are NEVER auto-replaced.

BINARY_NAME="CheTelegramAllMCP"
GITHUB_REPO="PsychQuant/che-msg"
INSTALL_DIR="$HOME/bin"
INSTALLED_BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
DESIRED_VERSION="0.9.0"
# The sha256 of the v$DESIRED_VERSION release asset, and the version it was
# taken from (PsychQuant/che-msg#50). A download is installed only if its
# sha256 equals SHA256_PIN; the pin counts only while SHA256_PIN_VERSION equals
# DESIRED_VERSION. A release sets both after its build (RELEASING.md); a version
# bump clears them. 0.8.0 was released before pins existed; its pin is the
# digest GitHub lists for the asset, which equals the sha256 of the 0.8.0
# binary in use. With no pin that counts, the download is checked against
# GitHub's digest only, which catches a damaged file but not a replaced asset.
SHA256_PIN_VERSION="0.8.0"
SHA256_PIN="90e8a365c1447e3f8b7d2967d08ea064b99149ab3513771bf1dcf22bc1198b6c"
# The pinned release only, never releases/latest: a pin could not match it.
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME"
RELEASE_API_URL="https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION"

# --- Startup errors Claude Code can show (#31, PsychQuant/che-msg#58) ---
# When the wrapper exits before starting the server, Claude Code's MCP
# transport sees no response and shows a generic "-32000 Server error".
# Answering the pending initialize request with a JSON-RPC 2.0 error lets it
# show the reason instead. The wrapper stops early only for missing Keychain
# credentials, a binary it cannot obtain, or a binary older than 0.7.0;
# another session running telegram-all never stops it (the server decides
# who opens TDLib).
#
# The error carries the id of the initialize request, which
# lib/startup-error.sh's read_first_request reads briefly from stdin (Claude
# Code drops an error whose id is null). A first request for another method,
# such as server/discover, gets "method not found" (-32601) there instead
# (PsychQuant/che-msg#59).

# Emit a JSON-RPC 2.0 error answering the pending initialize request, then
# exit 1. $1 is the message and MUST NOT contain double quotes or backslashes
# (callers build it only from fixed literals, version numbers and paths with
# $HOME shown as ~), so the JSON needs no escaping.
fail_startup() {
    local message="$1"
    REQUEST_ID=null
    # Answers a first request other than initialize itself and exits
    # (lib/startup-error.sh, PsychQuant/che-msg#59).
    declare -F read_first_request >/dev/null && read_first_request
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"%s","data":{"docsUrl":"https://github.com/PsychQuant/che-msg/blob/main/plugins/che-telegram-mcp/README.md#when-telegram-all-does-not-start"}}}\n' \
        "$REQUEST_ID" "$message"
    exit 1
}

# --- Shared code (PsychQuant/che-msg#56, #67) ---
# lib/startup-error.sh reads the client's first request for fail_startup;
# lib/download.sh downloads and installs the binary for both wrappers, and
# holds version_at_least and read_version_record, which the decision below
# uses.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
if [[ -z "$PLUGIN_ROOT" ]] || ! source "$PLUGIN_ROOT/lib/startup-error.sh" || ! source "$PLUGIN_ROOT/lib/download.sh"; then
    echo "$BINARY_NAME: ERROR — the plugin's lib/ files cannot be read; reinstall the che-telegram-mcp plugin" >&2
    fail_startup "The che-telegram-mcp plugin is incomplete: its lib/startup-error.sh or lib/download.sh cannot be read. Reinstall the plugin, then reconnect with /mcp."
fi

# Find binary — prefer $HOME/bin (installed from release) > source builds
BINARY=""
for loc in "$INSTALLED_BINARY" "/usr/local/bin/$BINARY_NAME" "$HOME/.local/bin/$BINARY_NAME" "$HOME/Developer/che-msg/che-telegram-all-mcp/.build/release/$BINARY_NAME" "$HOME/Developer/che-mcps/che-telegram-all-mcp/.build/release/$BINARY_NAME"; do
    [[ -x "$loc" ]] && BINARY="$loc" && break
done

# Decide whether to download. With no binary installed it always does; for the
# copy in ~/bin, only an older, missing or unreadable sidecar triggers it: a
# session still running an older plugin must not put its older binary back
# over a newer one (PsychQuant/che-msg#83).
NEED_DOWNLOAD=false
KEPT_AFTER_FAILED_DOWNLOAD=false
DOWNLOAD_PROBLEM=""
REASON=""
INSTALLED_VERSION=$(read_version_record "$VERSION_FILE")

if [[ -z "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ "$BINARY" == "$INSTALLED_BINARY" ]] && ! version_at_least "$INSTALLED_VERSION" "$DESIRED_VERSION"; then
    # Only auto-upgrade installed binaries; never touch source builds.
    NEED_DOWNLOAD=true
    if [[ "$INSTALLED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION}"
    else
        REASON="plugin wants v${DESIRED_VERSION}, and the version record is missing or not x.y.z"
    fi
fi

# --- The oldest binary this wrapper runs (PsychQuant/che-msg#58, #63) ---
# From 0.6.0 the server decides which session opens TDLib, and this wrapper
# takes no lock of its own. An older binary opens TDLib at startup without
# coordinating, so running one — for example the previous version, kept
# because the download did not succeed — could let two sessions open the same
# TDLib database. 0.6.0 and later answer --version before touching TDLib;
# older binaries print nothing (they start as a server and stop at the empty
# stdin). The probe runs without Telegram credentials, so even an old binary
# cannot log in or open its database, and is stopped after 5 seconds.
#
# From 0.7.0 the logout tool is a local reset (PsychQuant/che-msg#63). A
# 0.6.x binary still sends Telegram's log-out, which makes TDLib delete its
# local database, while this plugin's skill tells the user that nothing is
# deleted — so 0.6.x is refused too.
MIN_BINARY_VERSION="0.7.0"

# probe_version <binary>: the x.y.z the binary reports for --version, or nothing.
probe_version() {
    local out pid
    out=$(mktemp "${TMPDIR:-/tmp}/che-telegram-all-version-XXXXXX") || return 0
    env -u TELEGRAM_API_ID -u TELEGRAM_API_HASH -u TELEGRAM_PHONE -u TELEGRAM_2FA_PASSWORD \
        "$1" --version </dev/null >"$out" 2>/dev/null &
    pid=$!
    for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    sed -n 's/^che-telegram-all-mcp \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' "$out" | head -1
    rm -f "$out"
}

# --- Downloading in the background (PsychQuant/che-msg#67) ---
# Claude Code waits about 30 seconds for initialize, and this binary is about
# 240 MB, so the download never runs on the startup path (lib/download.sh). A
# binary this wrapper can run (0.7.0 or later) is started at once; the version
# downloaded is used from the first start after it is installed. With none,
# the wrapper waits FIRST_INSTALL_WAIT seconds for the download, then answers
# initialize with what is happening; the download goes on either way.
DOWNLOAD_SIZE="about 240 MB"   # told to the user on a first install
FIRST_INSTALL_WAIT=$(install_wait_seconds 3)   # CHE_TELEGRAM_MCP_INSTALL_WAIT overrides
DOWNLOAD_RUNNING=false
BINARY_VERSION=""
PROBED=""
if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading v$DESIRED_VERSION from $GITHUB_REPO in the background (log: ~/bin/.che-telegram-mcp-download/$BINARY_NAME.log)" >&2
    download_start "$BINARY_NAME" "$DESIRED_VERSION" "$DOWNLOAD_URL" "$INSTALL_DIR" \
        "$SHA256_PIN_VERSION" "$SHA256_PIN" "$RELEASE_API_URL"
    if [[ -n "$BINARY" ]]; then
        BINARY_VERSION=$(probe_version "$BINARY"); PROBED=$BINARY
    fi
    if [[ -n "$BINARY_VERSION" ]] && version_at_least "$BINARY_VERSION" "$MIN_BINARY_VERSION"; then
        echo "$BINARY_NAME: running the installed v$BINARY_VERSION meanwhile; the first start after the download uses v$DESIRED_VERSION" >&2
    else
        download_wait "$BINARY_NAME" "$DESIRED_VERSION" "$INSTALL_DIR" "$FIRST_INSTALL_WAIT"
        case "$DOWNLOAD_STATE" in
            installed)
                BINARY="$INSTALLED_BINARY"; PROBED="" ;;
            failed)
                DOWNLOAD_PROBLEM=$(download_failure "$DOWNLOAD_STATUS") ;;
            running)
                DOWNLOAD_RUNNING=true
                DOWNLOAD_PROBLEM="it is downloading in the background ($DOWNLOAD_SIZE$(download_progress "$BINARY_NAME" "$DESIRED_VERSION" "$INSTALL_DIR"))" ;;
        esac
        if [[ "$DOWNLOAD_STATE" != installed && -z "$BINARY" ]]; then
            if $DOWNLOAD_RUNNING; then
                echo "$BINARY_NAME: v$DESIRED_VERSION is not installed yet: $DOWNLOAD_PROBLEM." >&2
                fail_startup "CheTelegramAllMCP v$DESIRED_VERSION is not installed yet: $DOWNLOAD_PROBLEM. Reconnect with /mcp in a few minutes, once it has finished; the download goes on after this message and resumes if it is interrupted."
            fi
            echo "$BINARY_NAME: ERROR — v$DESIRED_VERSION not installed: $DOWNLOAD_PROBLEM." >&2
            download_manual_hint "$BINARY_NAME" "$DESIRED_VERSION" "$DOWNLOAD_URL" "$SHA256_PIN_VERSION" "$SHA256_PIN"
            fail_startup "CheTelegramAllMCP v$DESIRED_VERSION could not be installed: $DOWNLOAD_PROBLEM. Reconnect with /mcp to try again, or install it by hand as the che-telegram-mcp README describes."
        fi
        [[ "$DOWNLOAD_STATE" != installed ]] && KEPT_AFTER_FAILED_DOWNLOAD=true
    fi
fi

# --- Refuse a binary older than MIN_BINARY_VERSION ---
[[ "$PROBED" == "$BINARY" && -n "$PROBED" ]] || BINARY_VERSION=$(probe_version "$BINARY")
if [[ -z "$BINARY_VERSION" ]] || \
   [[ "$(printf '%s\n%s\n' "$MIN_BINARY_VERSION" "$BINARY_VERSION" | sort -V | head -1)" != "$MIN_BINARY_VERSION" ]]; then
    echo "$BINARY_NAME: $BINARY reports version ${BINARY_VERSION:-unknown}; this wrapper needs $MIN_BINARY_VERSION or later" >&2
    # Every candidate path is $HOME/... or /usr/local/bin/..., so showing
    # $HOME as ~ leaves only fixed literals in the message.
    case "$BINARY" in
        "$HOME"/*) SHOWN_BINARY="~/${BINARY#"$HOME"/}" ;;
        *)         SHOWN_BINARY="$BINARY" ;;
    esac
    if [[ -n "$BINARY_VERSION" ]]; then
        FOUND="reports version $BINARY_VERSION"
    else
        FOUND="does not report a version (binaries before 0.6.0 do not)"
    fi
    NEXT="Install the current version by hand as the che-telegram-mcp README describes, then reconnect with /mcp."
    if $KEPT_AFTER_FAILED_DOWNLOAD && $DOWNLOAD_RUNNING; then
        WHY="v$DESIRED_VERSION is not installed yet: $DOWNLOAD_PROBLEM."
        NEXT="Reconnect with /mcp in a few minutes, once the download has finished, or install it by hand as the che-telegram-mcp README describes."
    elif $KEPT_AFTER_FAILED_DOWNLOAD; then
        WHY="The download of v$DESIRED_VERSION did not succeed ($DOWNLOAD_PROBLEM), so the previous binary was kept."
    elif $NEED_DOWNLOAD; then
        WHY="The release that was downloaded is older than $MIN_BINARY_VERSION."
    elif [[ "$BINARY" != "$INSTALLED_BINARY" ]]; then
        WHY="It is not the copy the plugin installs in ~/bin, so it is never upgraded automatically."
    elif [[ "$INSTALLED_VERSION" == "$DESIRED_VERSION" ]]; then
        WHY="Its version record already says v$DESIRED_VERSION, so no download was attempted."
    else
        # Only a record that passed the x.y.z check reaches this branch, so the
        # value is digits and dots and is safe inside fail_startup's JSON message.
        WHY="Its version record says v$INSTALLED_VERSION, newer than the v$DESIRED_VERSION this plugin pins, so no download was attempted."
    fi
    if [[ -n "$BINARY_VERSION" ]] && \
       [[ "$(printf '%s\n%s\n' "0.6.0" "$BINARY_VERSION" | sort -V | head -1)" == "0.6.0" ]]; then
        RISK="its logout tool sends Telegram's log-out, which deletes the local TDLib database"
    else
        RISK="it would open TDLib without coordinating with other sessions"
    fi
    fail_startup "CheTelegramAllMCP $MIN_BINARY_VERSION or later is required. The binary at $SHOWN_BINARY $FOUND, and $RISK. $WHY $NEXT"
fi

# Read credentials from macOS Keychain
export TELEGRAM_API_ID="$(security find-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_API_ID" -w 2>/dev/null)"
export TELEGRAM_API_HASH="$(security find-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_API_HASH" -w 2>/dev/null)"

if [[ -z "$TELEGRAM_API_ID" || -z "$TELEGRAM_API_HASH" ]]; then
    echo "Telegram API credentials not found in Keychain." >&2
    echo "Set them up in your own terminal (security prompts for each value):" >&2
    echo "  security add-generic-password -a che-telegram-all-mcp -s TELEGRAM_API_ID -U -w" >&2
    echo "  security add-generic-password -a che-telegram-all-mcp -s TELEGRAM_API_HASH -U -w" >&2
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
