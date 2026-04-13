## Why

`che-telegram-all-mcp` 目前將 TDLib wrapper（`TDLibClient.swift`）和 MCP server 邏輯混在同一個 `CheTelegramAllMCPCore` target 裡。這導致無法在 MCP 之外重用 Telegram 個人帳號的功能（例如 CLI 工具）。`che-telegram-bot-mcp` 已完成同樣的三層拆分，all-mcp 需要對齊架構一致性。同時 MCP SDK 需升級至 0.12.0 以修復 Swift 6.3 的 concurrency 相容性問題。

## What Changes

- 從 `CheTelegramAllMCPCore` 拆出 `TelegramAllLib` target：只包含 `TDLibClient.swift`，依賴 TDLibKit，不依賴 MCP SDK
- `CheTelegramAllMCPCore` 改為依賴 `TelegramAllLib` + MCP SDK 的薄殼層
- 新增 `telegram-all` CLI executable target（依賴 `TelegramAllLib` + ArgumentParser）
- MCP SDK 從 `from: "0.10.2"` 升級至 `from: "0.12.0"`（修 Swift 6.3 `NetworkTransport` data race error）
- 修正 `Server.swift` 中 deprecated `.text()` API 為新的 `.text(text:annotations:_meta:)` 簽名
- 全部 28 個 MCP tools 保留不變

## Non-Goals

- 不精簡或移除任何現有 tool
- 不改變 TDLib 的連線模式（保持預設連網）
- 不改變認證流程
- 不改變 MCP tool 的行為或 schema

## Capabilities

### New Capabilities

- `telegram-all-lib`: 獨立的 TDLib wrapper library，可被 MCP 和 CLI 共用
- `telegram-all-cli`: 命令列工具，直接操作個人 Telegram 帳號

### Modified Capabilities

（無 — 現有 MCP 功能不變）

## Impact

- 受影響的檔案：
  - `che-telegram-all-mcp/Package.swift`（新增 targets + dependencies）
  - `che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/TDLibClient.swift` → 搬到 `Sources/TelegramAllLib/`
  - `che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift`（加 `import TelegramAllLib`，修 deprecated API）
  - 新增 `che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift`
- 依賴變更：新增 `swift-argument-parser`，MCP SDK 升級至 0.12.0
