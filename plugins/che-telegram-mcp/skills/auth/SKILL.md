---
name: auth
description: Authenticate Telegram personal account (one-time setup)
disable-model-invocation: true
allowed-tools:
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_status
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_run
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_set_parameters
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_send_phone
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_send_code
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_send_password
---

# Telegram Authentication

Guide the user through one-time authentication with `auth_run`, which drives the whole login (v0.5.0+):

1. `auth_status` — check the current state. If it is `ready`, stop: nothing to do.
2. Otherwise call `auth_run` and follow its `next_step` until the state is `ready`:
   - `next_step.required_args` empty → call `auth_run` again without arguments. The API ID and hash come from the Keychain through the wrapper.
   - `required_args` is `["code"]` → ask the user for the login code Telegram sent them, then `auth_run(code: "…")`. The code is never sent automatically.
   - `required_args` is `["phone"]` or `["password"]` → nothing could supply it: ask the user, then `auth_run(phone: "+886…")` or `auth_run(password: "…")`. A 2FA password typed here stays in the conversation transcript; say so, and mention that from che-telegram-all-mcp 0.9.0 the server reads it from the Keychain item `TELEGRAM_2FA_PASSWORD` instead (the plugin README shows how to store it).
   - `next_step.tool` is `logout` (a stalled session) → do not call it yourself. Explain that it resets the local session (the database is moved aside, not deleted; nothing is revoked on Telegram's side) and that logging in again needs a code sent to their account; call `logout` only after they agree, and only after it succeeds tell them to end the old session in Telegram → Settings → Devices. Then continue with `auth_run`.
3. Confirm with `auth_status` — it should show `ready`.

With binary 0.9.0 or later and both Keychain items (`TELEGRAM_PHONE`, `TELEGRAM_2FA_PASSWORD`) stored, the phone number and the 2FA password are sent for you and the login code is the only value the user types. With an earlier binary, or without the items, `auth_run` asks for them as above.

The step-by-step tools (`auth_set_parameters`, `auth_send_phone`, `auth_send_code`, `auth_send_password`) remain as a fallback if `auth_run` reports something it cannot handle.

Session is persisted in `~/Library/Application Support/che-telegram-all-mcp/tdlib/`. After first login, authentication is not needed again.
