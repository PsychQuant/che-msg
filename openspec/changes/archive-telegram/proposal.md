## Why

維護者想要把 Telegram 對話像 Apple Mail 一樣歸檔成本機 Markdown：設定一次要歸檔哪些對話，之後不帶參數重跑就只補新的訊息，並有索引防止重複（PsychQuant/che-msg#69，參考 che-apple-mail-mcp 的 `/archive-mail`）。目前 telegram-all 只有 `dump_chat_to_markdown`：每次呼叫整檔重寫、不記得上次匯出到哪、每則訊息沒有 message id，無法增量也無法去重。

維護者 2026-10-11 的決定：只歸檔設定裡逐一列出的 `chat_id`；寫到各專案自己的資料夾；群組也可歸檔、存放規則與一對一相同；第一次預設抓完整歷史、可用 `since` 指定起點；做成 skill `archive-telegram`。

實作中（2026-10-11）維護者追加：「我希望archive的時候所有東西都可以下載吧」，並指出 Telegram 內部有下載的程式可參考。決定：歸檔時預設下載所有媒體（可用 `max_media_mb` 設上限，超過的列在回報裡）；同一個下載核心另開一個單獨下載某則訊息媒體的工具，一併解決 #17（只能看文字、拿不到照片）。

決定實作方式的限制是「第一次抓完整歷史」：大群組可能有上千則訊息，若訊息以 `get_chat_history` JSON 經過模型、由 skill 自己寫檔，會用盡 context 並把第三方訊息內容帶進對話紀錄。archive-mail 遇到同樣問題，改由伺服器端批次寫檔、只回傳清單。本變更採同樣的分工。

## What Changes

- 新增 MCP tool `archive_chat_to_markdown`（`che-telegram-all-mcp`）：輸入 `chat_id`、`output_dir`、可選 `after_message_id` / `since_date` / `utc_offset`（切分日期用的時區，同一份歸檔固定不變）；只抓比書籤新的訊息，寫成「每聊天每天一檔」`<output_dir>/<chat_id>/YYYY-MM-DD.md`。每則訊息前有 `<!-- msg:<id> -->` 錨點；寫檔時讀出既有訊息、併入新訊息、依 message id 排序、以暫存檔加 rename 原子覆寫，重跑不重複。回傳只含清單（寫了哪些檔、新訊息數、最新 message id、媒體數、來源、`complete`、`bookmark_safe`），**不含任何訊息文字**。
- 速率限制：`FLOOD_WAIT` 不超過 60 秒時工具內重試一次；更長則停止並回 `complete: false`，已寫的檔保留，重跑時依錨點略過。
- 書籤安全：只有在走回到上一個書籤（或 `since_date`、或對話開頭）、TDLib 已同步、且來源是 TDLib 時才回 `bookmark_safe: true`。
- 另一個 session 持有 TDLib 時，工具改由本機快取讀取：照樣寫檔，但標 `source: local-cache` 且 `bookmark_safe: false`，寄件人名稱退回 `User <id>`。
- 新增 skill `plugins/che-telegram-mcp/skills/archive-telegram/`：讀 `.claude/.telegram/config.yaml`（`chats`、`output_dir`、`since`），維護 `.claude/.telegram/state/archives/<slug>/index.json`（每個聊天的 `last_message_id` 與上次執行摘要，原子寫入），逐一呼叫工具，最後核對清單上的每個檔都存在且含對應錨點，再回報。只有工具回 `bookmark_safe: true` 時才前進該聊天的書籤。
- 歸檔時下載媒體：照片、影片、檔案、音訊、語音、圓形影片、動圖、貼圖，用 TDLib 的 `downloadFile` 下載後複製到 `<output_dir>/<chat_id>/media/<message_id>/`；目錄已有檔案就不重下。日檔裡媒體那一行是 `[<type>](media/<message_id>/)` 加說明文字，連結事先就確定，所以檔案晚到也不必改寫那一行。可選 `max_media_bytes`（skill 設定 `max_media_mb`）設上限；超過的略過並在清單列出 message id 與大小；下載失敗的 message id 由 skill 記在索引，下次以 `retry_media_message_ids` 重試。媒體下載不影響書籤。由本機快取歸檔時無法下載，清單計數 `media_pending_local_cache`，下次用 TDLib 時補上。
- 新增 MCP tool `download_message_media`（`chat_id`、`message_id`、`output_dir`）：用同一個下載核心把單一則訊息的媒體存到與歸檔相同的位置，回傳路徑與大小、不含訊息文字；另一個 session 持有 TDLib 時回 `tdlib_in_use`。解決 #17。
- `TDLibClient` 的訊息 JSON 增加媒體檔案資訊（`file`：id、大小、檔名），照片取最大尺寸。
- 既有 `dump_chat_to_markdown` 的輸出不變；它遺失媒體說明文字的問題另由 #70 處理。

## Non-Goals (optional)

- 不追蹤歸檔後的編輯與刪除：歸檔是 append-only 紀錄。
- 不自動 commit 或 push 歸檔內容；歸檔是第三方逐字內容，是否進私人 repo 由各專案決定，絕不進本公開 repo。
- 不提供讀取端（搜尋、引用歸檔）的工具。

## Capabilities

### New Capabilities

- `telegram-chat-archive`: 增量歸檔工具 `archive_chat_to_markdown` 的檔案格式、去重與合併規則、媒體下載與重試、清單欄位、書籤安全條件；單則下載工具 `download_message_media`；以及 skill `archive-telegram` 的設定、索引與核對流程。

### Modified Capabilities

- `telegram-tdlib-lifecycle`: 「Tool routing while TDLib is held by another process」把 `archive_chat_to_markdown` 列為由本機快取回答的工具，`download_message_media` 列為回 `tdlib_in_use` 的工具。

## Impact

- Affected specs: `telegram-chat-archive`（新）、`telegram-tdlib-lifecycle`。`telegram-local-reader` 不變：歸檔工具只把快取讀取器既有的 `getChatHistory` 當訊息來源。
- Affected code:
  - New: che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift, che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift, che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift, che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift, che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift, che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift, plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - Modified: che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift, che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift, che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift, che-telegram-all-mcp/README.md, che-telegram-all-mcp/CHANGELOG.md, plugins/che-telegram-mcp/README.md, plugins/che-telegram-mcp/CHANGELOG.md, tests/che-telegram-mcp/test-plugin-layout.sh
- 發布：新版 binary 與 plugin（沿用 v0.7.0 / 1.6.0 的流程），在 #69 的 PR 合併時一起進行。
- 假設（unattended 下記錄，可被推翻）：工具名稱 `archive_chat_to_markdown`；`utc_offset` 未指定時用伺服器所在時區，skill 會把第一次用的 offset 記在索引裡、之後固定傳同一個值；60 秒的 `FLOOD_WAIT` 重試門檻是估計值，待實際長歷史執行時確認；媒體下載用 TDLib 同步下載（`synchronous: true`），一則一則下載，大檔案會讓單次工具呼叫變長，待實際執行時確認是否需要並行。
