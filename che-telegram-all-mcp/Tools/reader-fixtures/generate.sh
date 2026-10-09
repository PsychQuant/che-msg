#!/bin/bash
# Regenerates the TDLib fixture for the local reader tests
# (Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc).
#
# Builds a never-logged-in TDLib directory (no phone number is sent) against
# Telegram's TEST environment. Requires a prior `swift build` (for the
# TDLibFramework archive) and the API credentials in the keychain under
# account "che-telegram-all-mcp", services TELEGRAM_API_ID / TELEGRAM_API_HASH.
#
# Usage: bash Tools/reader-fixtures/generate.sh

set -euo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$PKG/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc"

FW=$(find "$PKG/.build" -type f -path '*TDLibFramework.framework/Versions/A/TDLibFramework' 2>/dev/null | head -1)
if [ -z "$FW" ]; then
    echo "TDLibFramework archive not found under .build — run 'swift build' first" >&2
    exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/reader-fixtures-XXXXXX")
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

if lipo -info "$FW" 2>/dev/null | grep -q 'Architectures in the fat file'; then
    lipo -thin "$(uname -m)" "$FW" -output "$WORK/libtd.a"
else
    cp "$FW" "$WORK/libtd.a"
fi
swiftc -O -o "$WORK/gen" "$PKG/Tools/reader-fixtures/generate.swift" "$WORK/libtd.a" -lc++ -lz

TELEGRAM_API_ID="$(security find-generic-password -a che-telegram-all-mcp -s TELEGRAM_API_ID -w)" \
TELEGRAM_API_HASH="$(security find-generic-password -a che-telegram-all-mcp -s TELEGRAM_API_HASH -w)" \
    "$WORK/gen" "$WORK/run" "$FIXTURE"
