# che-msg

Messaging MCP Servers — control Telegram (and more) through Claude.

Each MCP Server is an independent Swift Package. Pick the one that fits your use case.

## MCP Servers

| Server | Identity | Read Private Chats | Search History | Dependencies | Auth |
|--------|----------|-------------------|----------------|--------------|------|
| [che-telegram-bot-mcp](che-telegram-bot-mcp/) | Bot account | No | No | URLSession only | Bot token |
| [che-telegram-all-mcp](che-telegram-all-mcp/) | Personal account | Yes | Yes | TDLib (~300MB) | Phone + code |

**Not sure which one to use?**

- **Bot MCP** — You have a Telegram bot and want Claude to send messages, manage groups, or respond to updates through it. Lightweight, no personal data access.
- **All MCP** — You want Claude to operate as *you* — read all your chats, search message history, manage contacts. Full Telegram client via TDLib.

## Quick Start

```bash
# Clone
git clone https://github.com/kiki830621/che-msg.git
cd che-msg

# Build MCP Server
cd che-telegram-bot-mcp && swift build -c release

# Or build CLI tool
swift build -c release --product telegram-bot
.build/release/telegram-bot --help
```

See each server's README for installation and configuration details.

## Structure

```
che-msg/
├── che-telegram-bot-mcp/           # Telegram Bot API
│   ├── TelegramBotAPI/             #   Pure HTTP client library
│   ├── CheTelegramBotMCP/          #   MCP Server (30 tools)
│   └── telegram-bot/               #   CLI tool (6 commands)
├── che-telegram-all-mcp/           # Telegram personal account via TDLib
│   ├── TelegramAllLib/             #   TDLib wrapper library
│   ├── CheTelegramAllMCP/          #   MCP Server (26 tools)
│   └── telegram-all/               #   CLI tool (10 commands)
└── ...                             # More messaging MCPs planned
```

## Roadmap

- [ ] LINE MCP
- [ ] Slack MCP
- [ ] Discord MCP

## License

MIT
