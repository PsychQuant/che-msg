## Why

目前 `che-telegram-all-mcp` 的 `get_chat_history` MCP tool 是 TDLib `getChatHistory` 的 1:1 thin wrapper，單次呼叫最多回傳 ~100 筆訊息，且欄位是 TDLib 原始 schema（`sender.user_id`、Unix timestamp、TDLib message type）。兩個實際使用情境因此不可行：

1. **抓完整對話**（GitHub Issue #1）— AI agent 要自己迴圈呼叫並維護 `fromMessageId`，每輪 round-trip 一次，context 被大量 pagination 訊息佔滿。實測抓 300 筆訊息要 3 輪 tool call。
2. **匯出對話為可讀 Markdown**（GitHub Issue #2）— 目前只能 `get_chat_history` → JSON → 由 AI 在 context 內逐筆解析格式化（Unix timestamp、sender id → 人名、is_outgoing → 我/對方、media placeholder），token 浪費且結果不一致。

兩者互為前提：沒有完整抓取就 dump 不完整（Issue #2 明確標注 depends on #1）。

## What Changes

- **新增 MCP tool `dump_chat_to_markdown`**：一個 tool 完成「抓完整範圍訊息 → resolve sender name → 格式化 → 寫入指定 `.md` 檔」全流程，回傳摘要 metadata（不回傳 markdown 全文，避免爆 context）。
- **擴充 `TelegramAllLib.TDLibClient.getChatHistory()` library method**：新增 optional 參數 `maxMessages: Int?`、`sinceDate: Date?`、`untilDate: Date?`。`maxMessages == nil` 保持既有單頁行為（向後相容）；`maxMessages != nil` 時內部自動分頁直到達上限或 early-terminate。`sinceDate` / `untilDate` 在 client-side 過濾，單頁 + 過濾組合合法。
- **既有 MCP tool `get_chat_history` 不變**：保持 thin wrapper 語意（`chat_id`、`limit`、`from_message_id` 三參數），不 expose `maxMessages` / `sinceDate` / `untilDate`，避免 tool 語意混雜。
- **CLI `telegram-all history` 擴充**：新增 `--max-messages` / `--since` / `--until` / `--dump-markdown <path>` flags，呼叫同一個 library method 並選擇性走 markdown 格式化路徑。
- **不**新增 `get_chat_history_full` MCP tool：討論結論認定此中間層（回 JSON array 到 MCP response）在實務上 AI 總會再轉 markdown，等於 dead tool。Library 層由擴充後的 `getChatHistory` 單一 function 承擔「thin peek」與「full fetch」兩種語意。

## Non-Goals (optional)

Non-Goals 寫在 `design.md` 的 Goals/Non-Goals 區塊。

## Capabilities

### New Capabilities

- `telegram-history-export`: 定義 Telegram 完整對話歷史抓取（自動分頁、日期過濾、rate limit 處理）與 Markdown 匯出（sender resolve、timestamp 本地化、media placeholder）的行為契約。此 capability 同時規範 library 層（`TDLibClient.getChatHistory` 擴充）和 MCP server 層（`dump_chat_to_markdown` tool、既有 `get_chat_history` tool 不變的約束）。

### Modified Capabilities

None. This change introduces the first formal capability; no existing capability is being modified.

## Impact

- **受影響程式碼**：
  - `che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift`（擴充 `getChatHistory` signature、新增分頁/過濾 helper、新增 `dumpChatToMarkdown` method）
  - `che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift`（新增 `dump_chat_to_markdown` tool 定義與 dispatch case）
  - `che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift`（擴充 `history` subcommand flags）
  - `che-telegram-all-mcp/Tests/`（新增 unit tests：分頁、日期過濾、markdown 格式化；E2E test 抓真實對話 dump 驗證）
  - `che-telegram-all-mcp/CHANGELOG.md`（新增版本條目）
  - `che-telegram-all-mcp/README.md`（新增 `dump_chat_to_markdown` 使用範例）
- **受影響依賴**：無新增外部依賴，沿用既有 TDLibKit、MCP SDK、ArgumentParser
- **向後相容**：既有 `get_chat_history` MCP tool 和 CLI `history` 預設行為完全不變；library 層 `getChatHistory` 新增的全為 optional 參數，既有 call site 無需修改
- **GitHub Issues**：close #1、#2（change archive 後一起 close）
