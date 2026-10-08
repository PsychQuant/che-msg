---
name: send
description: Send a Telegram message to a chat
disable-model-invocation: true
argument-hint: "[chat] [message]"
allowed-tools:
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_status
  - mcp__plugin_che-telegram-mcp_telegram-all__search_chats
---

# Send Telegram Message

1. Check `auth_status` — must be "ready"
2. If user didn't specify a chat ID, use `search_chats` to find the target chat by name
3. Confirm the recipient and message content with the user before sending
4. Use `send_message` to send

**Always confirm before sending** — messages cannot be unsent from the recipient's view.
