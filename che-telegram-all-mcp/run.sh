#!/bin/bash
export TELEGRAM_API_ID="$(security find-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_API_ID" -w)"
export TELEGRAM_API_HASH="$(security find-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_API_HASH" -w)"
exec "$(dirname "$0")/.build/release/CheTelegramAllMCP" "$@"
