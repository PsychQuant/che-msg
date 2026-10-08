---
name: telegram-messaging
description: Guide for using Telegram MCP tools across both servers — telegram-all (personal account, full access) and telegram-bot (Bot API). Covers reading chats, sending messages, search, history, group management, and how to pick the right server. Use when the user asks about Telegram messages, chats, contacts, or bot operations.
---

# Telegram Messaging

This plugin ships **two MCP servers** — pick the right one before invoking any tool.

## Server selection — always do this first

| User's intent | Server | Why |
|---------------|--------|-----|
| "Read my chat with Alice" / "what did Bob say" / "search my messages" / "send a message as me" | **`telegram-all`** | Operates as the user's personal Telegram account. Sees all private chats, full history, can act as the user. |
| "Send a notification from the bot" / "respond to bot updates" / "moderate the group with the bot" | **`telegram-bot`** | Operates as a Telegram bot. Only sees chats the bot is in; no access to user's private chats. |
| User says "Telegram" without context | Default to **`telegram-all`** | Personal-account use is the more common path; bot use is usually explicit. |

**If both servers are configured and the request is ambiguous, ask the user which one.** Don't silently pick.

If a tool call fails with "server not connected" or similar, the corresponding server is likely disabled via the user's `disabledMcpjsonServers` setting — explain this and offer to fall back to the other server if it makes sense.

---

## Path A: `telegram-all` (Personal Account, TDLib)

Tool names: `mcp__plugin_che-telegram-mcp_telegram-all__<tool>`

### Auth — one-time setup

Auth state persists in `~/Library/Application Support/che-telegram-all-mcp/tdlib/`.

**Always check `auth_status` before doing real work.** It returns `{state, next_step, last_error}`.

- If `state == "ready"`, skip auth.
- Otherwise, prefer `auth_run` (v0.5.0+) which drives the state machine in one tool:
  ```
  auth_run                         → fires auto-set params (if env present)
  auth_run                         → fires auto-send phone (if env present)
  auth_run(code: "12345")          → caller MUST supply SMS code (never auto-fired)
  auth_run                         → fires auto-send 2FA password (if env present)
  auth_run                         → state == "ready"
  ```
- Legacy per-step tools (`auth_set_parameters`, `auth_send_phone`, `auth_send_code`, `auth_send_password`) are still available as escape hatches.

`auth_status.next_step` tells you exactly which arg the next call needs (e.g., `{tool: "auth_run", required_args: ["code"], hint: "..."}`); follow it.

### Tool categories

#### Discovery (start here)
| Tool | Purpose |
|------|---------|
| `get_chats` | List recent conversations (`limit` param) |
| `search_chats` | Find chat by name |
| `get_chat` | Get details of a specific chat |
| `get_contacts` | List saved contacts |
| `get_me` | Your own profile |
| `get_user` | Look up another user by ID |

#### Reading messages
| Tool | Purpose |
|------|---------|
| `get_chat_history` | Read history (`chat_id`, `limit`, `from_message_id`, optional `since_date` / `until_date` / `max_messages`) |
| `search_messages` | Search within a chat by keyword |
| `dump_chat_to_markdown` | One-shot export with date range / cap |

#### Sending / modifying messages
| Tool | Purpose |
|------|---------|
| `send_message` | Send text to a chat |
| `edit_message` | Edit your own sent message |
| `forward_messages` | Forward between chats |
| `delete_messages` | Delete messages |
| `mark_as_read` | Mark messages read |

> ⚠️ **CRITICAL**: Always confirm with the user before `send_message`, `edit_message`, `delete_messages`, or `forward_messages`. These actions show up in real conversations and cannot always be undone.

#### Group management
| Tool | Purpose |
|------|---------|
| `get_chat_members` | List group members |
| `create_group` | Create a new group |
| `add_chat_member` | Add member to group |
| `pin_message` / `unpin_message` | Pin/unpin |
| `set_chat_title` / `set_chat_description` | Edit group info |

### Common workflows (`telegram-all`)

```
Read recent messages:
1. get_chats(limit: 10)           → find the chat
2. get_chat_history(chat_id, limit: 20) → read messages

Search:
1. search_chats(query: "name")    → find the chat
2. search_messages(chat_id, query: "keyword") → find messages

Send a message:
1. search_chats(query: "recipient") → find chat_id
2. CONFIRM with user               → show recipient + message preview
3. send_message(chat_id, text)     → send
```

---

## Path B: `telegram-bot` (Bot API)

Tool names: `mcp__plugin_che-telegram-mcp_telegram-bot__<tool>`

### What the bot can / cannot do

- ✅ Send/receive messages in chats the bot has been added to
- ✅ Manage chats it's an admin of (pin, ban, restrict, set title)
- ✅ Send media (photo, video, document, audio, sticker, location, poll)
- ❌ Read the user's private chats (Bot API has no access)
- ❌ Search across history (Bot API only fetches via 24h `get_updates` window or webhooks)

### Tool categories

#### Identity & updates
| Tool | Purpose |
|------|---------|
| `get_me` | Bot's profile |
| `get_updates` | Poll for new messages / events (24h window) |

#### Send messages & media
| Tool | Purpose |
|------|---------|
| `send_message` | Send text |
| `send_photo` / `send_video` / `send_audio` / `send_document` / `send_sticker` / `send_location` / `send_poll` | Send specific media types |
| `forward_message` / `copy_message` | Forward / copy between chats |
| `edit_message_text` | Edit a sent message |
| `delete_message` | Delete a message |

#### Chat info
| Tool | Purpose |
|------|---------|
| `get_chat` | Chat details |
| `get_chat_administrators` | List admins |
| `get_chat_member_count` | Member count |
| `get_chat_member` | One member's role |

#### Admin actions (bot must be admin)
| Tool | Purpose |
|------|---------|
| `pin_chat_message` / `unpin_chat_message` / `unpin_all_chat_messages` | Pin/unpin |
| `ban_chat_member` / `unban_chat_member` | Ban control |
| `restrict_chat_member` / `promote_chat_member` | Permissions |
| `set_chat_title` / `set_chat_description` | Edit chat info |
| `leave_chat` | Bot leaves the chat |

#### Bot commands
| Tool | Purpose |
|------|---------|
| `set_my_commands` / `get_my_commands` / `delete_my_commands` | Manage `/command` list shown in Telegram clients |

> ⚠️ Same confirmation rule as Path A — always confirm with the user before any send / delete / ban / restrict / promote action.

---

## Security notes

- `telegram-all` operates as the user's **personal account**. It can read all private chats — handle content with care; never log or store message content beyond the current conversation.
- `telegram-bot` operates as a public bot — its actions are visible to everyone in the chat. Treat bot tokens as secrets (they're stored in macOS Keychain).
- Always get explicit user confirmation before any send / delete / forward / ban action. Don't infer consent from earlier turns of the conversation.

## When tools fail

| Error pattern | Likely cause | Fix |
|---------------|--------------|-----|
| `Not authenticated` (telegram-all) | Auth not completed | Walk through `auth_run` flow above |
| `FLOOD_WAIT_X` | Rate limited by Telegram | Surface the wait time to the user; retry after X seconds |
| `Server not connected` | Server disabled in settings, or binary missing | Check `disabledMcpjsonServers` and the SessionStart hook output |
| Bot 401 / `Unauthorized` | Bot token wrong or revoked | Re-issue token via @BotFather and update Keychain |
