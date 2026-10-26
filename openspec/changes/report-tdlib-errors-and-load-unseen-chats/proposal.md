## Why

剛登入的 TDLib 只認得少數聊天。對它還沒載入的聊天呼叫 `get_chat_history` 或 `get_chat`，回應是「The operation couldn’t be completed. (TDLibKit.Error error 1.)」，看不到 TDLib 自己的 `{"code":400,"message":"Chat not found"}`（PsychQuant/che-msg#71）。兩個原因：

1. `TDLibClient` 只在四個認證步驟把 `TDLibKit.Error` 轉成 `TDError.tdlibError`；其餘 28 個 TDLib 請求讓它原樣丟出。server 模組不依賴 TDLibKit，接不住這個型別，最後落到 `errorResultFromParse` 的 `localizedDescription`。CLI 共用同一個 client，問題相同。
2. TDLib 只讀它認得的聊天。封存工具在 #69 已經會先用 id 建立聊天（`loadChatForArchive`），其他接受 `chat_id` 的工具沒有。

## What Changes

- `TDLibClient` 的每一個 TDLib 請求（四個認證步驟除外）都經過同一個轉換：`TDLibKit.Error` 變成帶 TDLib code 與 message 的 `TDError.tdlibError`。code 406 照樣丟出錯誤，但 message 留空。server 對任何工具回 `{"type":"tdlib_error","code":…,"message":…}`，CLI 印出 `TDLib error <code>: <message>`。原本封存專用的 `archiveTDLibCall` 改名 `tdlibCall`，成為唯一的轉換點；一個讀原始碼的測試確認沒有請求繞過它。
- 每個接受聊天 id 的 `TDLibClient` 方法（`getChat`、`getChatHistory`、`searchMessages`、寫入類方法、`getChatMembers`、封存的讀取）在第一個請求前先讓 TDLib 認得這個聊天：`getChat`，回 400 時依 TDLib 的 id 範圍用 `createPrivateChat`／`createBasicGroupChat`／`createSupergroupChat` 建立。這段邏輯從 `loadChatForArchive` 抽出，封存與其他工具共用。
- 建立不了時（id 不在可建立的範圍，或建立請求回 400），丟出新的 `TDError.unknownChat`，帶原本 `getChat` 的 code 與 message。server 回 `tdlib_error` 並多一個 `hint` 欄位：說明 TDLib 沒有載入這個聊天、用 id 也載入不了，請先呼叫 `get_chats`（limit 要夠大）再重試。其他錯誤（rate limit、session 已關閉）原樣丟出。

## Non-Goals

- 不改四個認證步驟的錯誤處理（406 照舊靜默完成）。
- 不用 `loadChats` 逐頁載入聊天清單找目標聊天：`create*Chat` 對全新資料庫上的其他使用者與群組是否成功，要用維護者的帳號實測（Diagnosis Strategy 第 1 步）才知道；實測結果若顯示需要，另做。
- `get_user` 接受的是使用者 id，不是聊天 id，不在本次範圍。另一個 process 持有 TDLib 時的本機快取路徑也不變。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `telegram-auth-error-reporting`: 新增「每個 TDLib 請求都回報 TDLib 的 code 與 message」的要求；修改「Authentication scope of structured error contract」，讓原本限於認證步驟的範圍指向新要求。
- `telegram-all-lib`: 新增「接受聊天 id 的方法先用 id 載入 TDLib 沒見過的聊天，載入不了時帶原錯誤與提示」的要求。

## Impact

- 受影響的 spec：`telegram-auth-error-reporting`、`telegram-all-lib`
- 程式：`che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift`、`che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift`、新檔 `che-telegram-all-mcp/Sources/TelegramAllLib/TDLibRequests.swift`、`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ErrorResponses.swift`、`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift`、`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/AuthResponses.swift`
- 測試：`che-telegram-all-mcp/Tests/TelegramAllLibTests/`、`che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/`
- 文件：`che-telegram-all-mcp/README.md`、`che-telegram-all-mcp/CHANGELOG.md`
