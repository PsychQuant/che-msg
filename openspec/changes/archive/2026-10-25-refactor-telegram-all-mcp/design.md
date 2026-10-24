## Context

本 design 在 2026-10-25 歸檔前補寫；change 本身已於 2026-04-13（commit `581bf2b`）完成，四組 task 全部勾選。當時的做法記在 proposal：把 `TDLibClient.swift` 從 `CheTelegramAllMCPCore` 拆成獨立的 `TelegramAllLib` target，新增 `telegram-all` CLI，並把 MCP SDK 升到 0.12.0。補寫的目的只有一個：記下歸檔前對 `telegram-all-lib` spec 的更正，讓三個月後讀到這份 change 的人知道 spec 與 4 月原稿為何不同。

## Goals / Non-Goals

**Goals:**

- `TelegramAllLib` 是 MCP server 與 CLI 共用的 TDLib wrapper，本身不依賴 MCP SDK
- `telegram-all` CLI 只依賴 `TelegramAllLib` 與 swift-argument-parser

**Non-Goals:**

- 不改變任何 MCP tool 的行為或 schema（沿用 proposal 的 Non-Goals）
- 本次更正不改程式碼，只改 spec 的敘述

## Decisions

### 歸檔前移除「TelegramAllLib preserves existing API surface」並把 lib 依賴更正為現況

2026-10-25 維護者在歸檔前選擇更正 spec，而不是照 4 月原稿寫進 `openspec/specs/`。對照當天的 `che-telegram-all-mcp/Package.swift`，有兩處已不成立：

1. 「Standalone TDLib wrapper library」原稿說 library 只依賴 Foundation 與 TDLibKit；現在還依賴 TDLibFramework，以及 #58 為本機 TDLib 快取讀取器加入的 `CTDLibSQLite` C target。更正後的 requirement 寫成現況，兩個 scenario（`CheTelegramAllMCPCore` 透過 `TelegramAllLib` 存取 `TDLibClient`；CLI 不依賴 MCP SDK）照原樣保留，當天也已核對成立：MCP core 的依賴是 `TelegramAllLib` 與 MCP，CLI 的依賴是 `TelegramAllLib` 與 ArgumentParser。
2. 「TelegramAllLib preserves existing API surface」要求 API 簽名一律不改、28 個 MCP tools 行為不變。這是 2026-04 搬檔時的驗收限制，不是持續性的規格；之後的 change 改過 `TDLibClient` 的 API，server 目前有 30 個 tools。照原樣寫進正式 spec，會留下一條現況就違反的 requirement，所以整條移除。

已完成的 task 1.2（「確保 TelegramAllLib preserves existing API surface」）與 4.3（「28 個 tools 全部保留」）保留原文，作為當時的驗收紀錄；proposal 也不改，維持 4 月的原貌。

替代方案：只歸檔不寫 spec（`--skip-specs`），或照原稿寫入。前者讓 CLI 與 lib 繼續沒有 spec，而 #61、#62 之後會改到這兩個元件；後者會寫入不成立的敘述。

## Implementation Contract

- 行為：`TelegramAllLib` 提供 `TDLibClient` 的公開方法（認證、聊天、訊息、聯絡人與使用者、群組、已讀、logout），MCP server 與 `telegram-all` CLI 都透過它存取 TDLib
- 介面：`telegram-all` 提供 `me`、`chats`、`history`、`search`、`send`、`contacts` 子命令，缺 `TELEGRAM_API_ID`／`TELEGRAM_API_HASH` 時報錯結束（見 `telegram-all-cli` spec）
- 依賴邊界：`TelegramAllLib` 不依賴 MCP SDK；CLI 的依賴圖不含 MCP SDK
- 驗證：當年由 task 3.3、4.1–4.3 驗收（`swift build` 全部 targets、CLI `--help`、server 啟動）；本次更正以 2026-10-25 的 `Package.swift` 核對依賴
- 範圍外：本次不改任何程式碼
