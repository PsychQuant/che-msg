# che-msg

Messaging MCP Servers — control Telegram (and more) through Claude.

Each MCP Server is an independent Swift Package. Pick the one that fits your use case.

## Claude Code plugins

This repository is also the `che-msg` Claude Code plugin marketplace:

```bash
claude plugin marketplace add PsychQuant/che-msg
claude plugin install che-telegram-mcp@che-msg    # both Telegram servers; binaries download on first use
claude plugin install che-archive-lines@che-msg   # LINE macOS "Save chat" automation
```

See [plugins/che-telegram-mcp](plugins/che-telegram-mcp/) and [plugins/che-archive-lines](plugins/che-archive-lines/). Both were published from psychquant-claude-plugins until che-telegram-mcp 1.4.1 and che-archive-lines 1.1.0; their READMEs give the switch-over steps.

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
git clone https://github.com/PsychQuant/che-msg.git
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
├── .claude-plugin/marketplace.json # The che-msg plugin marketplace
├── plugins/                        # Claude Code plugins (che-telegram-mcp, che-archive-lines)
├── tests/                          # Plugin tests
└── ...                             # More messaging MCPs planned
```

## Roadmap

- [ ] LINE MCP
- [ ] Slack MCP
- [ ] Discord MCP

## License

MIT
