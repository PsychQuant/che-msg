## Why

telegram-all 在 session 一啟動就開 TDLib（`Server.init` 建立 `TDLibClient`，auto-fire 隨即送出 TDLib 參數），一直持有 TDLib 資料夾的鎖到 session 結束。同一時間只有一個 Claude Code session 能用 telegram-all，輪到誰取決於誰先啟動，而不是誰需要 Telegram（PsychQuant/che-msg#58，2026-10-09 實際發生：要讀 Telegram 的 session 被一個不相關、約 50 分鐘前啟動的背景 session 擋下）。使用者的要求是 MCP 不要一直佔著，需要時直接讀本機的 TDLib 資料庫。

## What Changes

- telegram-all 的 MCP server 啟動時**不再**開 TDLib；第一次有工具被呼叫時才決定怎麼服務：
  - TDLib 的鎖沒人持有 → 取得鎖、開 TDLib、照現有方式服務；閒置一段時間沒有呼叫就關閉 TDLib、釋放鎖
  - 鎖被另一個 process 持有 → 讀取類工具改由「本機讀取器」直接讀 TDLib 的 SQLite 回應；寫入類工具回明確錯誤，指出持有鎖的 process
- 新增本機讀取器（`TelegramAllLib` 內）：從 `td.binlog` 解出 SQLite 的金鑰，以唯讀方式打開加密的 `db.sqlite`，解析聊天列表、使用者、訊息（含日期、寄件人、文字）
- 讀取器第一版涵蓋 5 個工具：`get_chats`、`search_chats`、`get_chat_history`、`search_messages`、`dump_chat_to_markdown`；其餘讀取工具在讀取器模式下回「此模式不支援」
- 讀取器只接受驗證過的 TDLib 版本；遇到其他版本明確報錯，不猜格式
- **BREAKING（行為）**：wrapper 拿不到鎖時不再拒絕啟動；第二個 session 的 telegram-all 會正常啟動，改由 server 在呼叫時處理鎖。依賴「第二個 session 一定被拒絕」的使用情境（README 的 Multi-session limitation 段）會改變
- 實作前先做三個可行性驗證（只在檔案複本上進行），作為是否繼續的關卡；任一項不通過即停止並回到討論

## Capabilities

### New Capabilities

- `telegram-tdlib-lifecycle`: TDLib 何時開、何時關、鎖被別人持有時各類工具如何回應（用到才開、閒置釋放、讀寫分流、寫入工具的錯誤內容）
- `telegram-local-reader`: 以唯讀方式讀取 TDLib 本機加密快取的契約——支援的工具與輸出、版本限制、安全規則（不寫入、不洩漏金鑰）、資料不完整時的行為

### Modified Capabilities

(none)

## Impact

- 受影響的程式：
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift（TDLib 改為延後開啟、可關閉）
  - che-telegram-all-mcp/Sources/TelegramAllLib/ 內新增讀取器相關檔案（binlog 解碼、SQLCipher 唯讀開檔、格式解析）
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift（啟動不開 TDLib；工具呼叫時分流）
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh（拿不到鎖時不再拒絕啟動）
  - che-telegram-all-mcp/Tests/TelegramAllLibTests、che-telegram-all-mcp/Tests/CheTelegramAllMCPTests、tests/che-telegram-mcp/（wrapper 測試）
- 依賴：不新增套件。TDLibFramework 已內建帶加密功能的 SQLite（匯出 `tdsqlite3_key`）
- 文件與發布：plugins/che-telegram-mcp/README.md 的 Multi-session limitation 段改寫；binary 新版 release，wrapper 的 `DESIRED_VERSION` 與 plugin 版本隨之更新
- 維護：讀取器依賴 TDLib 1.8.60（`cb863c16`）的內部格式；之後升級 TDLib 必須重新驗證讀取器
- 相關 issue：PsychQuant/che-msg#58（本 change）、PsychQuant/che-msg#59（被鎖擋下時只顯示 CONNECTION_CLOSED）
