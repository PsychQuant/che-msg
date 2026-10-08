---
name: auth
description: Authenticate Telegram personal account (one-time setup)
disable-model-invocation: true
allowed-tools:
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_status
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_set_parameters
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_send_phone
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_send_code
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_send_password
---

# Telegram Authentication

Guide the user through one-time authentication:

1. `auth_status` — check current state
2. If not ready:
   - `auth_set_parameters` — API credentials are auto-loaded from Keychain
   - `auth_send_phone` — ask user for their phone number (e.g., +886...)
   - `auth_send_code` — ask user for the verification code received in Telegram
   - `auth_send_password` — only if 2FA is enabled
3. Verify with `auth_status` — should show "ready"

Session is persisted in `~/Library/Application Support/che-telegram-all-mcp/tdlib/`. After first login, authentication is not needed again.
