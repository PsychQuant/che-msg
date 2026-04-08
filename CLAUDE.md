# che-msg

即時通訊 MCP Server monorepo。

## 結構

| 目錄 | 說明 | 底層 |
|------|------|------|
| `che-telegram-bot-mcp` | Telegram Bot API | Swift + MCP SDK |
| `che-telegram-all-mcp` | Telegram 個人帳號 (MTProto/TDLib) | Swift + TDLibKit |

## 開發

每個 MCP 都是獨立的 Swift Package，各自有 `Package.swift`。

```bash
cd che-telegram-bot-mcp && swift build
cd che-telegram-all-mcp && swift build
```

## 未來擴展

- LINE MCP（目前 `che-archive-lines` 是純腳本自動化，待升級為 MCP）
- Slack / Discord 等即時通訊整合
