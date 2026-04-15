## 1. Library 層 `getChatHistory` 擴充（TelegramAllLib/TDLibClient.swift）

- [x] [P] 1.1 撰寫單元測試 `TDLibClientBackwardCompatTests.swift`：Backward-compatible single-page retrieval — 既有三參數 `getChatHistory(chatId:limit:fromMessageId:)` call site 呼叫時僅執行一次 TDLib call 且回傳未經過濾的 raw JSON array，對應 design「Library 層單一 function 承擔兩種語意」的向後相容分支
- [x] [P] 1.2 撰寫單元測試 `TDLibClientPaginationTests.swift`：Bulk chat history retrieval with bounded termination — 涵蓋 `maxMessages` 達上限、對話起點（TDLib 回空陣列）、`sinceDate` early-terminate 三種終止情境，對應 design「分頁方向 newest → oldest + early-terminate」
- [x] [P] 1.3 撰寫單元測試 `TDLibClientDateFilterTests.swift`：Client-side date range filtering independent of pagination — 測試「單頁 + `sinceDate` 過濾」、「單頁 + `untilDate` 過濾」、「`maxMessages` + 雙邊界」，確認過濾與 `maxMessages` 獨立
- [x] 1.4 擴充 `TDLibClient.getChatHistory` signature 新增 `maxMessages: Int?` / `sinceDate: Date?` / `untilDate: Date?` optional 參數，實作自動分頁迴圈與 client-side date filter helper，使 1.1–1.3 測試通過

## 2. MCP tool 定義更新（CheTelegramAllMCPCore/Server.swift）

- [x] 2.1 撰寫單元測試 `ServerDumpChatToolTests.swift`：同時驗證兩件事 — (a) `dump_chat_to_markdown` MCP tool 註冊時 schema 含 `chat_id` / `output_path` / `max_messages` / `since_date` / `until_date` / `self_label` 六個 properties 且 `chat_id` 與 `output_path` 為 required；(b) `get_chat_history` MCP tool remains a thin wrapper — schema 仍只含 `chat_id` / `limit` / `from_message_id` 且 dispatch 路徑未改動，對應 design「既有 `get_chat_history` MCP tool 維持 thin wrapper 不加 flag」與「砍掉中間層 `get_chat_history_full` MCP tool」（確認沒有第三個 tool 被註冊）
- [x] 2.2 於 `Server.swift defineTools()` 與 dispatch `switch` 新增 `dump_chat_to_markdown` tool 定義與 case，委派到 `MarkdownExporter`（見任務 3.4），使 2.1 測試通過

## 3. Markdown 產生與 sender resolve（TelegramAllLib/MarkdownExporter.swift）

- [x] [P] 3.1 撰寫單元測試 `MarkdownFormatTests.swift`：Markdown output format — 驗證 level-1 heading、metadata line、按日 level-2 heading（`## YYYY-MM-DD` 按時序排）、`**HH:mm <sender>**：` 格式、連續同人訊息各自保留時間戳不合併、各種 media 型別對應 `[photo]` / `[voice]` / `[video]` / `[sticker]` / `[document]` / `[location]` / `[other]` placeholder
- [x] [P] 3.2 撰寫單元測試 `MarkdownSenderResolveTests.swift`：Batch sender resolution with fallback — 1000 訊息 / 3 unique sender 時 `getUser` 恰好被 call 3 次（cache 生效）、`getUser` throw 時對應訊息 fallback 為 `User <id>` 格式、整個 dump 不 abort，對應 design「Sender name 批次 resolve + cache」
- [x] [P] 3.3 撰寫單元測試 `MarkdownExporterContractTests.swift`：同時驗證 — (a) Output path validation and error reporting（父目錄不存在時 throw distinguishable error 且 `output_path` 在 error payload 內、未發出任何 TDLib call）；(b) Secret chat history warning（`chatTypeSecret` 時 response JSON 含 `warning` 欄位且 dump 不 abort）；(c) Self 訊息使用 `self_label`（預設 `"我"`、override 為其他字串時輸出 Markdown 內容隨之改變），對應 design「Markdown dump 必填 `output_path`，回 summary metadata」與「Self 訊息用可覆寫的 label 區分」
- [x] 3.4 實作新檔 `TelegramAllLib/MarkdownExporter.swift`：`dump_chat_to_markdown` 主流程 — output_path 預先驗證 → 呼叫 `TDLibClient.getChatHistory(maxMessages:sinceDate:untilDate:)` → 收集 unique sender id → 批次 `getUser` cache → 按日分組格式化 → 寫檔 → 組 summary metadata JSON（含 secret chat warning 分支），使 3.1–3.3 測試通過

## 4. CLI 擴充與文件

- [x] 4.1 擴充 `telegram-all/TelegramAllCLI.swift` 的 `history` subcommand 新增 `--max-messages <Int>` / `--since <YYYY-MM-DD>` / `--until <YYYY-MM-DD>` / `--dump-markdown <path>` / `--self-label <string>` flags，未指定 `--dump-markdown` 時印 JSON 陣列，指定時呼叫 `MarkdownExporter` 並印 summary metadata
- [x] [P] 4.2 更新 `che-telegram-all-mcp/README.md` 加入 `dump_chat_to_markdown` MCP tool 使用範例與 CLI `--dump-markdown` 範例；更新 `che-telegram-all-mcp/CHANGELOG.md` 新增版本條目（列出 library signature 擴充、新 MCP tool、CLI flags、向後相容性聲明）
- [ ] 4.3 執行 E2E 測試：在 `Tests/E2ETests/` 新增 `DumpChatToMarkdownE2ETests.swift`，使用真實 `TELEGRAM_API_ID` / `API_HASH` 對測試用 chat 執行完整 dump 流程，驗證分頁、sender resolve、markdown 寫檔、metadata 回傳四個環節；手動抽查輸出檔內容符合 Markdown output format
- [ ] 4.4 完成 `spectra archive add-chat-history-export` 後，在 GitHub close Issue #1 與 Issue #2 並於 closing comment 附上 `openspec/archive/<timestamp>-add-chat-history-export/` 路徑連結
