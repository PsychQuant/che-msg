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

# Build the one you need
cd che-telegram-bot-mcp && swift build -c release
# or
cd che-telegram-all-mcp && swift build -c release
```

See each server's README for installation and configuration details.

## Structure

```
che-msg/
├── che-telegram-bot-mcp/    # Telegram Bot API (30 tools)
├── che-telegram-all-mcp/    # Telegram personal account via TDLib (28 tools)
└── ...                      # More messaging MCPs planned
```

## Roadmap

- [ ] LINE MCP
- [ ] Slack MCP
- [ ] Discord MCP

## License

MIT
