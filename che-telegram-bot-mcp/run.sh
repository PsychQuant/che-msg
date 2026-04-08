#!/bin/bash
export TELEGRAM_BOT_TOKEN="$(security find-generic-password -a "che-telegram-bot-mcp" -s "TELEGRAM_BOT_TOKEN" -w)"
exec "$(dirname "$0")/.build/release/CheTelegramBotMCP" "$@"
