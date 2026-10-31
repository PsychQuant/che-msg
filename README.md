# che-msg

Messaging MCP Servers — control Telegram and Slack (and more) through Claude.

Each MCP Server is an independent Swift Package. Pick the one that fits your use case.

## Claude Code plugins

This repository is also the `che-msg` Claude Code plugin marketplace:

```bash
claude plugin marketplace add PsychQuant/che-msg
claude plugin install che-telegram-mcp@che-msg    # both Telegram servers; binaries download on first use
claude plugin install che-slack-mcp@che-msg       # Slack as you, in every workspace you import
claude plugin install che-archive-lines@che-msg   # LINE macOS "Save chat" automation
```

See [plugins/che-telegram-mcp](plugins/che-telegram-mcp/), [plugins/che-slack-mcp](plugins/che-slack-mcp/) and [plugins/che-archive-lines](plugins/che-archive-lines/). che-slack-mcp needs the `slack-all` CLI, built from source, to import workspaces; its README explains how and what the risks are. che-telegram-mcp and che-archive-lines were published from psychquant-claude-plugins until che-telegram-mcp 1.4.1 and che-archive-lines 1.1.0; their READMEs give the switch-over steps.

## MCP Servers

| Server | Identity | Read Private Chats | Search History | Dependencies | Auth |
|--------|----------|-------------------|----------------|--------------|------|
| [che-telegram-bot-mcp](che-telegram-bot-mcp/) | Bot account | No | No | URLSession only | Bot token |
| [che-telegram-all-mcp](che-telegram-all-mcp/) | Personal account | Yes | Yes | TDLib (~300MB) | Phone + code |
| [che-slack-mcp](che-slack-mcp/) | Your Slack account, in every workspace you import | Yes (conversations you are in) | Yes | URLSession only | Browser session imported with `slack-all` |

**Not sure which one to use?**

- **Bot MCP** — You have a Telegram bot and want Claude to send messages, manage groups, or respond to updates through it. Lightweight, no personal data access.
- **All MCP** — You want Claude to operate as *you* — read all your chats, search message history, manage contacts. Full Telegram client via TDLib.
- **Slack MCP** — You want Claude to read, search, send and archive Slack messages as *you*, in workspaces whose administrators have not approved a Slack app. It uses your signed-in browser session; see the [plugin README](plugins/che-slack-mcp/README.md#risks) for the risks.

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
│   ├── CheTelegramBotMCP/          #   MCP Server (31 tools)
│   └── telegram-bot/               #   CLI tool (6 commands)
├── che-telegram-all-mcp/           # Telegram personal account via TDLib
│   ├── TelegramAllLib/             #   TDLib wrapper library
│   ├── CheTelegramAllMCP/          #   MCP Server (30 tools)
│   └── telegram-all/               #   CLI tool (10 commands)
├── che-slack-mcp/                  # Slack, signed in as you (browser session)
│   ├── SlackWebLib/                #   Slack Web API client (Foundation only)
│   ├── CheSlackMCPCore/            #   MCP tools and archive (9 tools)
│   ├── SlackAllCore/               #   Workspace import, status, remove
│   ├── CheSlackMCP/                #   MCP Server
│   └── slack-all/                  #   CLI tool (auth import / status / remove)
├── .claude-plugin/marketplace.json # The che-msg plugin marketplace
├── plugins/                        # Claude Code plugins (che-telegram-mcp, che-slack-mcp, che-archive-lines)
├── tests/                          # Plugin tests
└── ...                             # More messaging MCPs planned
```

## Roadmap

- [ ] LINE MCP
- [x] Slack MCP ([che-slack-mcp](che-slack-mcp/))
- [ ] Discord MCP

## License

MIT
