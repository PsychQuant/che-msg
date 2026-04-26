# che-telegram-all-mcp

Full Telegram client MCP Server powered by [TDLib](https://core.telegram.org/tdlib). Operate Telegram as **your personal account** — read all chats, send messages, manage groups, search history.

> **Looking for the simpler Bot-only version?** See [che-telegram-bot-mcp](../che-telegram-bot-mcp/).

## Bot vs All: What's the difference?

| Feature | `che-telegram-bot-mcp` | `che-telegram-all-mcp` |
|---------|----------------------|----------------------|
| Identity | Bot account | Your personal account |
| Read private chats | No | Yes |
| Read full chat history | No | Yes |
| Search messages | No | Yes |
| Contact list | No | Yes |
| Dependencies | URLSession only | TDLib (~300MB) |
| Auth | Bot token | Phone + verification code |

## Prerequisites

### 1. Get Telegram API Credentials

1. Go to [https://my.telegram.org](https://my.telegram.org)
2. Log in with your phone number
3. Go to **API Development Tools**
4. Create a new application → get `api_id` (number) and `api_hash` (string)

### 2. Build

Requires Swift 5.9+ and macOS 13+.

> **First build will download ~300MB** of TDLibFramework binary. This is normal.

```bash
git clone https://github.com/PsychQuant/che-msg.git
cd che-msg/che-telegram-all-mcp
swift build -c release
```

Binary location: `.build/release/CheTelegramAllMCP`

## Installation

### Option A: Claude Code CLI

```bash
claude mcp add che-telegram-all-mcp \
  -s user \
  -e TELEGRAM_API_ID=12345678 \
  -e TELEGRAM_API_HASH=your_api_hash_here \
  -- /path/to/che-telegram-all-mcp/.build/release/CheTelegramAllMCP
```

> With env vars set, API credentials are auto-configured on startup. You only need to authenticate your phone number once.

### Option B: Edit config directly

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "che-telegram-all-mcp": {
      "type": "stdio",
      "command": "/path/to/.build/release/CheTelegramAllMCP",
      "env": {
        "TELEGRAM_API_ID": "12345678",
        "TELEGRAM_API_HASH": "your_api_hash_here"
      }
    }
  }
}
```

### Option C: Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "che-telegram-all-mcp": {
      "command": "/path/to/.build/release/CheTelegramAllMCP",
      "env": {
        "TELEGRAM_API_ID": "12345678",
        "TELEGRAM_API_HASH": "your_api_hash_here"
      }
    }
  }
}
```

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TELEGRAM_API_ID` | Yes | Telegram API ID (numeric). Auto-fired when state is `waitingForParameters`. |
| `TELEGRAM_API_HASH` | Yes | Telegram API hash (string). Auto-fired alongside `TELEGRAM_API_ID`. |
| `TELEGRAM_PHONE` | No | Phone number in international format (e.g., `+886912345678`). Auto-fired when state is `waitingForPhoneNumber`. Useful for SSH / remote setup. |
| `TELEGRAM_2FA_PASSWORD` | No | 2FA password. Auto-fired when state is `waitingForPassword`. |

> SMS verification code is **never** auto-fired from environment — it must be supplied via `auth_run(code: "...")` or `auth_send_code(code: "...")` in a one-shot delivery.
>
> If env vars are not set, you can still drive the flow manually via `auth_run` (or the per-step `auth_set_parameters` / `auth_send_phone` / `auth_send_password` tools).

## Authentication Flow

Authentication is a **one-time process**. After the first login, TDLib stores the session locally and you won't need to authenticate again.

### Recommended: `auth_run` (single tool, repeat until ready)

Set env vars for the steps you want auto-fired (`TELEGRAM_API_ID` / `TELEGRAM_API_HASH` / `TELEGRAM_PHONE` / `TELEGRAM_2FA_PASSWORD`), then call `auth_run` repeatedly:

```
auth_run                 →  fires auto-set params (if env present)
auth_run                 →  fires auto-send phone (if env present)
auth_run(code: "12345")  →  caller MUST supply SMS code
auth_run                 →  fires auto-send 2FA password (if env present)
auth_run                 →  state == "ready"
```

Each call returns `{state, next_step, last_error}`. `next_step.required_args` tells you exactly which arg the next call needs. `last_error` surfaces auto-fire failures (e.g., `FLOOD_WAIT_30`).

### Legacy: per-step manual flow

```
Step 1: auth_set_parameters  →  Provide api_id and api_hash
Step 2: auth_send_phone      →  Provide your phone number (+886...)
Step 3: auth_send_code        →  Enter the code received in Telegram
Step 3b: auth_send_password   →  (Only if 2FA is enabled)
Done:   auth_status           →  Should show {state: "ready", next_step: null}
```

Session data is stored in: `~/Library/Application Support/che-telegram-all-mcp/tdlib/`

## Tools (27)

### Authentication (6)

| Tool | Description |
|------|-------------|
| `auth_set_parameters` | Set API credentials (api_id + api_hash) |
| `auth_send_phone` | Send phone number to start auth |
| `auth_send_code` | Enter verification code |
| `auth_send_password` | Enter 2FA password (if enabled) |
| `auth_status` | Check current auth state |
| `logout` | Log out and clear session |

### User Info (3)

| Tool | Description |
|------|-------------|
| `get_me` | Get your own profile |
| `get_user` | Get info about any user |
| `get_contacts` | List your contacts |

### Chat Operations (3)

| Tool | Description |
|------|-------------|
| `get_chats` | List recent conversations |
| `get_chat` | Get details about a chat |
| `search_chats` | Search chats by name |

### Messages (7)

| Tool | Description |
|------|-------------|
| `get_chat_history` | Read message history (single page, thin wrapper) |
| `dump_chat_to_markdown` | Export full chat history to a `.md` file (auto-paginates + date filter + sender resolve + Markdown format). Writes to `output_path`, returns summary metadata. |
| `send_message` | Send a text message |
| `edit_message` | Edit your message |
| `delete_messages` | Delete messages |
| `forward_messages` | Forward messages |
| `search_messages` | Search within a chat |

### Group Management (7)

| Tool | Description |
|------|-------------|
| `get_chat_members` | List group members |
| `pin_message` | Pin a message |
| `unpin_message` | Unpin a message |
| `set_chat_title` | Change chat title |
| `set_chat_description` | Change chat description |
| `create_group` | Create a new basic group |
| `add_chat_member` | Add a member to a group |

### Read State (1)

| Tool | Description |
|------|-------------|
| `mark_as_read` | Mark messages as read |

## Usage Examples

Once authenticated, you can ask Claude things like:

- "Show me my recent chats"
- "Read the last 20 messages from my chat with John"
- "Search for messages about 'meeting' in the team group"
- "Send 'I'll be late' to the family group"
- "Forward the last message from Alice to my Saved Messages"
- "Get my contact list"
- "Dump my chat with 培鈞 from 2026-04-01 to 2026-04-15 to `/tmp/pei-chun-chat.md`" → triggers `dump_chat_to_markdown`

### Dump chat to Markdown

The `dump_chat_to_markdown` tool writes a single Markdown file per invocation and returns summary metadata. Example AI-facing call shape:

```jsonc
dump_chat_to_markdown({
  "chat_id": 489601378,
  "output_path": "/tmp/pei-chun-chat.md",
  "max_messages": 5000,             // optional, default 5000
  "since_date": "2026-03-01",        // optional
  "until_date": "2026-04-15",        // optional
  "self_label": "我"                 // optional, default "我"
})
```

Response (summary metadata only — no Markdown body):

```jsonc
{
  "path": "/tmp/pei-chun-chat.md",
  "message_count": 327,
  "date_range": { "since": "2026-03-01", "until": "2026-04-15" },
  "senders": [{ "user_id": 12345, "display_name": "培鈞 徐" }, ...]
}
```

Output Markdown format (excerpt):

```markdown
# 對話：培鈞 徐 (chat_id=489601378)
匯出時間：2026-04-15 23:40:00　訊息數：327　since 2026-03-01　until 2026-04-15

---

## 2026-04-14

**14:32 我**：
到了嗎

**14:33 培鈞 徐**：
我隨時出發

**14:35 培鈞 徐**：
[photo]
```

### CLI: dump from the command line

The same capability is exposed through `telegram-all history` flags — useful for scripting and testing outside MCP:

```bash
# Single page (original behavior, unchanged)
telegram-all history 489601378 --limit 50

# Auto-paginate and filter, print JSON
telegram-all history 489601378 --max-messages 5000 --since 2026-03-01 --until 2026-04-15

# Auto-paginate and dump to Markdown
telegram-all history 489601378 \
  --max-messages 5000 \
  --since 2026-03-01 \
  --until 2026-04-15 \
  --self-label "che" \
  --dump-markdown /tmp/pei-chun-chat.md
```

## Architecture

```
Sources/
├── CheTelegramAllMCP/
│   └── main.swift              # Entry point
├── CheTelegramAllMCPCore/
│   └── Server.swift            # MCP Server (27 tools + dispatch)
├── TelegramAllLib/
│   ├── TDLibClient.swift       # TDLib wrapper (auth + all operations)
│   ├── MessageFilters.swift    # Pagination + date-filter pure helpers
│   └── MarkdownExporter.swift  # dump_chat_to_markdown orchestrator
└── telegram-all/
    ├── TelegramAllCLI.swift    # ArgumentParser subcommands
    └── AuthHelper.swift
```

- **TDLib** via [TDLibKit](https://github.com/Swiftgram/TDLibKit) — native Swift wrapper
- MCP SDK for stdio transport
- Session persisted in `~/Library/Application Support/`

## Security Notes

- This MCP operates as **your personal Telegram account**. It can read all your private chats.
- API credentials and session are stored locally only.
- Use `logout` to clear your session if needed.
- Never share the TDLib database directory with others.

## License

MIT
