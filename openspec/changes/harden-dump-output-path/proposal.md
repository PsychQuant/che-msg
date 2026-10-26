## Why

`dump_chat_to_markdown` 對 `output_path` 只檢查父目錄存在且可寫（`validateOutputPath`）。它不要求絕對路徑（相對路徑以 server 的工作目錄解析，呼叫端看不到那個目錄）、不擋 `..`、不限副檔名，寫入又是暫存檔加 rename，會整個取代既有檔案。內容是聊天參與者寫的訊息原文，多行訊息的後續行會成為獨立的一行，所以被 prompt injection 的呼叫端可以讓 server 把一段 shell 指令寫進 `~/.zshrc` 這類會被載入的檔案（PsychQuant/che-msg#21）。

## What Changes

- **BREAKING**：`output_path` 必須是絕對路徑、不含 `..` 元件、以 `.md` 結尾（不分大小寫），否則在解析參數時就拒絕，不讀任何訊息。相對路徑與非 `.md` 路徑過去會照寫，現在會被拒絕。
- 新增選用的環境變數 `CHE_TELEGRAM_ALL_EXPORT_ROOT`：設了（非空字串）時，`output_path` 解析 symlink 後必須落在這個根目錄之內，否則拒絕；根目錄本身不是既存的絕對路徑目錄時，每一次 dump 都拒絕並說出根目錄，不會被略過。沒設就維持現狀。server 啟動時讀一次。
- 根目錄限制放在兩條 dump 寫入路徑共用的 `validateOutputPath`：TDLib 模式與另一個 process 持有 TDLib 時的本機快取讀取路徑。
- tool schema 的 `output_path` 說明、README（環境變數表與 tool 說明）、CHANGELOG 隨之更新。

以下三個預設是維護者不在時選的（default chosen while the maintainer was away），對應 #21 Diagnosis 的 Open questions：

1. 預設政策：照 Diagnosis 的建議，第 1 步（絕對路徑、無 `..`、`.md`）一律啟用，第 2 步（根目錄）opt-in；不設預設沙箱。
2. 適用範圍：取最小範圍，根目錄只限制 `dump_chat_to_markdown` 的兩條寫入路徑；`archive_chat_to_markdown` 與 `download_message_media` 不受限制（它們的 `output_dir` 由各 workspace 自訂）。
3. 環境變數名稱：`CHE_TELEGRAM_ALL_EXPORT_ROOT`，與既有的 `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` 一致。

## Non-Goals

- 不限制 `archive_chat_to_markdown`、`download_message_media` 的 `output_dir`，也不改 `telegram-all history --dump-markdown` 這個 CLI 旗標（使用者在終端機自己下的指令，路徑照舊）。
- 不設預設根目錄：沒設 `CHE_TELEGRAM_ALL_EXPORT_ROOT` 時，任何可寫位置的絕對 `.md` 路徑照舊可寫。
- 不改寫入方式（仍是暫存檔加 rename，既有檔案會被取代），也不改 Markdown 的內容格式。
- 不處理「呼叫端本來就被允許寫入、內容由聊天參與者塑形」的情境；那一道關卡是 MCP client 對每次 tool call 的授權，不在這個 repo。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `telegram-history-export`：「Output path validation and error reporting」改為兩段驗證：參數解析時的三條規則，與寫入前的父目錄檢查加上選用的根目錄限制；並寫明適用與不適用的工具。

## Impact

- 受影響的 spec：`telegram-history-export`
- 程式：`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/HandlerArgs.swift`（`parseDumpChatToMarkdownArgs`）、`che-telegram-all-mcp/Sources/TelegramAllLib/MarkdownExporter.swift`（`validateOutputPath`、`ExportError`、`ExportRoot`）、`che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalTDLibReader.swift`（`dumpChatToMarkdown`、`LocalCacheReading`）、`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift`（啟動時讀變數、兩個 handler 傳入、schema 說明）
- 測試：`che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ParseDumpArgsTests.swift`、`che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift`、`che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownExporterContractTests.swift`、`che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift`，以及實作 `LocalCacheReading` 的測試替身
- 文件：`che-telegram-all-mcp/README.md`、`che-telegram-all-mcp/CHANGELOG.md`
