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

1. `auth_status` — check the current state.
   - `state` is `ready` and `sync_stalled` is `false` → stop: nothing to do.
   - `state` is `closed` → the session was closed; tell the user to reconnect the server (`/mcp`), then run this skill again.
   - Otherwise (including `ready` with `sync_stalled: true`) → step 2.
2. Follow `next_step` until the state is `ready` (call `auth_run` again after each step, or `auth_status` to re-read it):
   - `next_step.tool` is `logout` (a stalled session) → do not call it yourself. Explain that it resets the local session (the database is moved aside, not deleted; nothing is revoked on Telegram's side) and that logging in again needs a code sent to their account; call `logout` only after they agree, and only after it succeeds tell them to end the old session in Telegram → Settings → Devices. Then call `auth_run`.
   - `required_args` is `["api_id", "api_hash"]` → the wrapper found no API credentials in the Keychain. Point the user to the plugin README's setup (store `TELEGRAM_API_ID` and `TELEGRAM_API_HASH`, then reconnect with `/mcp`), or call `auth_set_parameters` with the values they give you.
   - `required_args` is `["code"]` → ask the user for the login code Telegram sent them, then `auth_run(code: "…")`. The code is never sent automatically.
   - `required_args` is `["phone"]` or `["password"]` → the server has no value for it. With che-telegram-all-mcp 0.9.0 or later, first offer to store it in the Keychain (`TELEGRAM_PHONE` / `TELEGRAM_2FA_PASSWORD`, as the plugin README shows; if an item is already stored, it may be locked, wrong or out of date), then call `auth_run` without arguments. Otherwise, or if the user prefers, ask for it and call `auth_run(phone: "+886…")` or `auth_run(password: "…")`; a 2FA password typed here stays in the conversation transcript, so say so.
3. Confirm with `auth_status` — `state` should be `ready` with `sync_stalled: false`.

With binary 0.9.0 or later and both Keychain items stored, the phone number and the 2FA password are sent for you and the login code is the only value the user types.

The step-by-step tools (`auth_set_parameters`, `auth_send_phone`, `auth_send_code`, `auth_send_password`) remain as a fallback if `auth_run` reports something it cannot handle.

Session is persisted in `~/Library/Application Support/che-telegram-all-mcp/tdlib/`. After first login, authentication is not needed again.
