#!/bin/bash
# SessionStart check for che-telegram-mcp plugin
#
# Verifies binaries + Keychain entries needed by the two bundled MCP servers
# (telegram-all and telegram-bot). Output mirrors what the wrappers will look
# for at runtime, so a green checkmark here means the wrapper will succeed.
#
# Note: this hook does NOT read disabledMcpjsonServers from settings.json. If
# you've intentionally disabled one server, ignore its warnings (the footer
# note explains how).

GITHUB_REPO="PsychQuant/che-msg"

# Search locations — MUST match the wrapper's `for loc in ...` list.
# See bin/che-telegram-{all,bot}-mcp-wrapper.sh.
PLAIN_VERSION='^[0-9]+\.[0-9]+\.[0-9]+$'

# read_version_record <file>: its content with surrounding whitespace removed
# (a trailing CR included); whitespace inside is kept, so "0. 9.0" stays
# malformed. The same rule as the wrappers' read on #83's branch.
read_version_record() {
    local v
    v=$(cat "$1" 2>/dev/null || true)
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

check_binary() {
    local name="$1" pkg_dir="$2" label="$3"
    local found=""
    # Order matters: prefer installed binary > source build (matches wrapper).
    for loc in \
        "$HOME/bin/$name" \
        "/usr/local/bin/$name" \
        "$HOME/.local/bin/$name" \
        "$HOME/Developer/che-msg/$pkg_dir/.build/release/$name" \
        "$HOME/Developer/che-mcps/$pkg_dir/.build/release/$name"; do
        if [[ -x "$loc" ]]; then
            found="$loc"
            break
        fi
    done
    if [[ -n "$found" ]]; then
        # Read sidecar version (only present for $HOME/bin installs).
        local version_file="$HOME/bin/.${name}.version"
        local installed_version=""
        [[ -f "$version_file" ]] && installed_version=$(read_version_record "$version_file")
        # A record that is not x.y.z is reported by notify_if_outdated, not shown here.
        if [[ "$installed_version" =~ $PLAIN_VERSION ]]; then
            echo "✓ $label v$installed_version installed: $found"
        else
            echo "✓ $label installed: $found"
        fi
    else
        echo "⚠️  $label not found"
        echo "   Wrappers will auto-download on first invocation, or build manually:"
        echo "     git clone https://github.com/$GITHUB_REPO.git ~/Developer/che-msg"
        echo "     cd ~/Developer/che-msg/$pkg_dir && swift build -c release --product $name"
    fi
}

# Single GitHub API hit for both binaries (same release / same tag).
fetch_latest_tag() {
    curl -sL --max-time 5 "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/'
}

# Compares the way the wrappers' version check on #83's branch does
# (PsychQuant/che-msg#83, #89): the record trimmed of surrounding whitespace
# only, both sides plain x.y.z, ordered with sort -V. The installed binary can be
# newer than the latest release (a hand-installed build today; any newer binary
# once the wrappers keep it, #83), so "different" is not "older".
notify_if_outdated() {
    local name="$1" label="$2" latest="$3"
    local version_file="$HOME/bin/.${name}.version"
    [[ -f "$version_file" ]] || return  # not a managed install (source build / manual)
    local installed
    installed=$(read_version_record "$version_file")
    if [[ ! "$installed" =~ $PLAIN_VERSION ]]; then
        echo "⚠️  $label: version record ~/bin/.${name}.version is not a plain x.y.z version"
        return
    fi
    [[ "$latest" =~ $PLAIN_VERSION ]] || return  # API failed / offline / rate-limited / odd tag; stay quiet
    if [[ "$installed" == "$latest" ]]; then
        return
    elif [[ "$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | head -1)" == "$installed" ]]; then
        echo "⬆️  $label v$installed → v$latest available (wrapper auto-upgrades on next plugin update)"
    else
        echo "ℹ  $label v$installed is installed, newer than the latest release v$latest"
    fi
}

check_keychain_required() {
    local account="$1" service="$2" label="$3"
    # Without -w: only the item's attributes are read, never its value.
    if security find-generic-password -a "$account" -s "$service" &>/dev/null; then
        echo "✓ $label in Keychain"
    else
        echo "⚠️  $label not in Keychain — in your own terminal (security prompts for the value):"
        echo "   security add-generic-password -a $account -s $service -U -w"
    fi
}

check_keychain_optional() {
    local account="$1" service="$2" label="$3"
    if security find-generic-password -a "$account" -s "$service" &>/dev/null; then
        echo "✓ $label in Keychain (optional)"
    fi
    # Silent when missing — optional creds shouldn't generate warnings.
}

echo "── Telegram MCP Status ──"

# telegram-all: personal account via TDLib
check_binary "CheTelegramAllMCP" "che-telegram-all-mcp" "telegram-all (TDLib)"
check_keychain_required "che-telegram-all-mcp" "TELEGRAM_API_ID" "API ID"
check_keychain_required "che-telegram-all-mcp" "TELEGRAM_API_HASH" "API Hash"
check_keychain_optional "che-telegram-all-mcp" "TELEGRAM_PHONE" "Phone (auto-fire)"
check_keychain_optional "che-telegram-all-mcp" "TELEGRAM_2FA_PASSWORD" "2FA password (auto-fire)"

# telegram-bot: bot account via Bot API
check_binary "CheTelegramBotMCP" "che-telegram-bot-mcp" "telegram-bot"
check_keychain_required "che-telegram-bot-mcp" "TELEGRAM_BOT_TOKEN" "Bot Token"

# Upstream-version notice (single API call, both binaries share one release).
LATEST=$(fetch_latest_tag)
notify_if_outdated "CheTelegramAllMCP" "telegram-all" "$LATEST"
notify_if_outdated "CheTelegramBotMCP" "telegram-bot" "$LATEST"

# Footer: how to silence warnings for a server you don't use.
echo "ℹ  Using only one server? Add the other to disabledMcpjsonServers in"
echo "    ~/.claude/settings.json or .claude/settings.json (project), e.g."
echo "    {\"disabledMcpjsonServers\": [\"telegram-bot\"]}  ← suppresses bot."
