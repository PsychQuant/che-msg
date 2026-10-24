## 1. 拆出 TelegramAllLib（standalone TDLib wrapper library）

- [x] 1.1 建立 standalone TDLib wrapper library：建立 `Sources/TelegramAllLib/` 目錄，將 `TDLibClient.swift` 從 `Sources/CheTelegramAllMCPCore/` 搬入
- [x] 1.2 更新 `Package.swift`：新增 `TelegramAllLib` target（依賴 TDLibKit，不依賴 MCP SDK），確保 TelegramAllLib preserves existing API surface
- [x] 1.3 更新 `CheTelegramAllMCPCore` target：加入 `TelegramAllLib` 依賴，`Server.swift` 加 `import TelegramAllLib`

## 2. 升級 MCP SDK + 修 deprecated API

- [x] 2.1 [P] `Package.swift` 中 MCP SDK 從 `from: "0.10.2"` 改為 `from: "0.12.0"`
- [x] 2.2 [P] 修正 `Server.swift` 中 deprecated `.text()` 呼叫為 `.text(text:annotations:_meta:)`

## 3. 新增 telegram-all CLI（CLI subcommands cover core read and write operations）

- [x] 3.1 `Package.swift` 新增 `swift-argument-parser` 依賴和 `telegram-all` executable target
- [x] 3.2 建立 CLI executable for personal Telegram operations：`Sources/telegram-all/TelegramAllCLI.swift`，實作 CLI subcommands cover core read and write operations：me、chats、history、search、send、contacts（CLI reads environment variables for authentication）
- [x] 3.3 [P] 驗證 CLI 不依賴 MCP SDK（`swift build --target telegram-all` 成功且 dependency graph 無 MCP）

## 4. 驗證

- [x] 4.1 `swift build -c release` 全部 targets 零 error 零 warning
- [x] 4.2 `.build/release/telegram-all --help` 顯示正確的 subcommands
- [x] 4.3 `.build/release/CheTelegramAllMCP` 啟動正常，28 個 tools 全部保留
