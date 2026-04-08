# che-telegram-bot-mcp

Swift native MCP Server for Telegram Bot API. Zero external dependencies beyond MCP SDK.

Through Claude, you can send/read messages, manage groups, pin messages, set bot commands, and more.

## Prerequisites

### 1. Create a Telegram Bot

1. Open Telegram, search for [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the instructions
3. Copy the bot token (format: `123456789:ABCdefGhIjKlMnOpQrStUvWxYz`)

### 2. (Optional) Enable Group Message Access

By default, bots can only see commands (`/start`, `/help`, etc.) in groups. To read all messages:

1. Open [@BotFather](https://t.me/BotFather)
2. Send `/mybots` → select your bot → **Bot Settings** → **Group Privacy** → **Turn off**

### 3. Build

Requires Swift 5.9+ and macOS 13+.

```bash
git clone https://github.com/kiki830621/che-telegram-bot-mcp.git
cd che-telegram-bot-mcp
swift build -c release
```

Binary location: `.build/release/CheTelegramBotMCP`

## Installation

### Option A: Claude Code CLI

```bash
claude mcp add che-telegram-bot-mcp \
  -s user \
  -e TELEGRAM_BOT_TOKEN=your_token_here \
  -- /path/to/che-telegram-bot-mcp/.build/release/CheTelegramBotMCP
```

> **Note**: `name` must come right after `add`. `-e` and `-s` go before `--`.

Verify:

```bash
claude mcp get che-telegram-bot-mcp
# Should show: Status: ✓ Connected
```

### Option B: Edit config directly

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "che-telegram-bot-mcp": {
      "type": "stdio",
      "command": "/path/to/.build/release/CheTelegramBotMCP",
      "env": {
        "TELEGRAM_BOT_TOKEN": "your_token_here"
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
    "che-telegram-bot-mcp": {
      "command": "/path/to/.build/release/CheTelegramBotMCP",
      "env": {
        "TELEGRAM_BOT_TOKEN": "your_token_here"
      }
    }
  }
}
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TELEGRAM_BOT_TOKEN` | Yes | Bot token from @BotFather |

## Tools (30)

### Bot Info

| Tool | Description |
|------|-------------|
| `get_me` | Get bot username, ID, and capabilities |

### Messages

| Tool | Description |
|------|-------------|
| `send_message` | Send text message (supports Markdown/HTML) |
| `forward_message` | Forward a message to another chat |
| `copy_message` | Copy a message without forward header |
| `edit_message_text` | Edit a previously sent message |
| `delete_message` | Delete a message |

### Updates

| Tool | Description |
|------|-------------|
| `get_updates` | Get incoming messages and events via long polling |

### Chat Info

| Tool | Description |
|------|-------------|
| `get_chat` | Get chat title, type, description, etc. |
| `get_chat_member_count` | Get number of members |
| `get_chat_member` | Get info about a specific member |
| `get_chat_administrators` | List all administrators |

### Member Management

| Tool | Description |
|------|-------------|
| `ban_chat_member` | Ban a user (with optional expiry) |
| `unban_chat_member` | Unban a user |
| `restrict_chat_member` | Set granular permissions for a user |
| `promote_chat_member` | Promote or demote an admin |

### Pin / Unpin

| Tool | Description |
|------|-------------|
| `pin_chat_message` | Pin a message (optionally silent) |
| `unpin_chat_message` | Unpin a specific message |
| `unpin_all_chat_messages` | Clear all pinned messages |

### Media

| Tool | Description |
|------|-------------|
| `send_photo` | Send photo by URL or file_id |
| `send_document` | Send document by URL or file_id |
| `send_video` | Send video by URL or file_id |
| `send_audio` | Send audio by URL or file_id |
| `send_location` | Send a map location (lat/lng) |
| `send_poll` | Create a poll (regular or quiz) |
| `send_sticker` | Send a sticker |

### Bot Commands

| Tool | Description |
|------|-------------|
| `set_my_commands` | Set the bot's command menu |
| `get_my_commands` | List current commands |
| `delete_my_commands` | Remove all commands |

### Chat Settings

| Tool | Description |
|------|-------------|
| `set_chat_title` | Change group/channel title |
| `set_chat_description` | Change group/channel description |
| `leave_chat` | Make the bot leave a chat |

## Usage Examples

Once connected, you can ask Claude things like:

- "Send a message to chat 123456 saying hello"
- "Get the latest updates from my bot"
- "Pin the message with ID 42 in chat -100123456"
- "Create a poll in chat 123456: What's for lunch? Options: Pizza, Sushi, Tacos"
- "Set bot commands: start - Start the bot, help - Show help"

## Architecture

```
Sources/
├── CheTelegramBotMCP/
│   └── main.swift              # Entry point
└── CheTelegramBotMCPCore/
    ├── Server.swift            # MCP Server (tool definitions + dispatch)
    └── TelegramAPI.swift       # HTTP client for api.telegram.org
```

- **No third-party dependencies** beyond MCP Swift SDK
- Uses `URLSession` to call Telegram Bot API directly
- All 30 tools map to official [Telegram Bot API](https://core.telegram.org/bots/api) methods

## Limitations

- **Bot API only**: Can only operate as a bot, not a personal account. For full account access, see `che-telegram-all-mcp` (planned).
- **No file upload**: Media tools accept URLs or `file_id`, not local file paths.
- **No webhook**: Uses `getUpdates` (polling), not webhook mode.

## License

MIT
