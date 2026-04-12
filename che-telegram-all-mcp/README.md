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
git clone https://github.com/kiki830621/che-msg.git
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
| `TELEGRAM_API_ID` | Yes | Telegram API ID (numeric) |
| `TELEGRAM_API_HASH` | Yes | Telegram API hash (string) |
| `TELEGRAM_2FA_PASSWORD` | No | 2FA password (auto-entered if set) |

> If env vars are not set, you can still use the `auth_set_parameters` tool to provide credentials at runtime.

## Authentication Flow

Authentication is a **one-time process**. After the first login, TDLib stores the session locally and you won't need to authenticate again.

```
Step 1: auth_set_parameters  →  Provide api_id and api_hash
Step 2: auth_send_phone      →  Provide your phone number (+886...)
Step 3: auth_send_code        →  Enter the code received in Telegram
Step 3b: auth_send_password   →  (Only if 2FA is enabled)
Done:   auth_status           →  Should show "ready"
```

Session data is stored in: `~/Library/Application Support/che-telegram-all-mcp/tdlib/`

## Tools (28)

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

### Messages (6)

| Tool | Description |
|------|-------------|
| `get_chat_history` | Read message history |
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

## Architecture

```
Sources/
├── CheTelegramAllMCP/
│   └── main.swift              # Entry point
└── CheTelegramAllMCPCore/
    ├── Server.swift            # MCP Server (28 tools + dispatch)
    └── TDLibClient.swift       # TDLib wrapper (auth + all operations)
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
