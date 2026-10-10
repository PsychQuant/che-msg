## Problem

telegram-all 回答的資料可能早已過時，而且沒有任何提示（PsychQuant/che-msg#63）。維護者的 Mac 上，TDLib 資料庫從 2026-04-30 起就沒有收到任何新訊息；Telegram app 看得到的新對話，`get_chats`、`get_chat_history` 都讀不到。`auth_status` 卻回報 `{"state":"ready"}`，回答也沒有任何「資料可能不是最新」的說明。這次 #58 加上的本機快取說明只出現在「TDLib 被別的 process 佔用」的路徑；由 server 自己開 TDLib 時，回答一樣沒有說明。

## Root Cause

Telegram 已作廢這個 session 的登入金鑰：每一次 `updates.getDifference` 都回 `406 AUTH_KEY_DUPLICATED`（2026-10-10 以資料庫複本實測，90 秒內 7 次、全部失敗）。TDLib 1.8.60 遇到這個錯誤時不會登出、也不會把錯誤交給 client：授權狀態停在 `authorizationStateReady`，連線狀態停在 `connectionStateUpdating`，只在內部以退避方式一直重試。server 只看授權狀態（`TDLibClient.handleUpdate` 只處理 `updateAuthorizationState`），讀取工具又直接讀 TDLib 的本機資料庫，所以一切看起來正常。

## Proposed Solution

依連線狀態判斷「是否已與 Telegram 同步」，不解讀 406 的錯誤內容（維護者 2026-10-10 選定的做法 C）。

1. `TDLibClient` 記錄 `updateConnectionState`：目前狀態，以及「自何時起不是 Ready」。
2. 開 TDLib 後，在既有的「等授權穩定」之後，再最多等一段時間讓連線到達 `connectionStateReady`，避免剛開時就回答舊資料。
3. 由 TDLib 回答的讀取工具，若當下連線不是 Ready，在回答後附一段說明：尚未與 Telegram 同步、已持續多久、可能缺少新訊息。
4. `auth_status` 增加連線狀態欄位；不是 Ready 超過一段時間時，標為同步停滯並給下一步：session 可能已被 Telegram 作廢，需要重新登入。
5. `logout` 只做本機重置（2026-10-10 驗證第一輪後維護者選定）：不向 Telegram 登出，關閉 TDLib（最多 30 秒）→ 把資料夾改名留存（不刪除）→ 釋放 TDLib，下一次登入從新的資料夾開始。舊 session 留在帳號的裝置清單，要在 Telegram app 裡結束。停滯只算 `connectionStateUpdating` 的時間，離線不算；`next_step` 指向 `logout` 時提示先問使用者。
6. README 寫「telegram-all 不再同步」的辨識方式與恢復步驟。

**假設（unattended 下的決定，待 apply 實測）**：第一次使用最多等 10 秒、120 秒判定停滯。依據：正常補一天的資料只要幾秒；作廢的 session 在 90 秒的實測中毫無進展。兩個值都會在實作時以正常帳號量測後定案。

## Non-Goals

- 不解讀 406 的錯誤訊息；`telegram-auth-error-reporting` 的「406 silent-ignore」規則不變。
- 不自動重新登入、不自動刪除或搬移 TDLib 資料夾：重新登入會寄驗證碼並建立新 session，必須由維護者操作。資料夾只在維護者呼叫 `logout` 且 TDLib 無法自行完成時改名，且永不刪除。
- 不查明這次金鑰為何被判定重複（需要維護者其他裝置的資訊，記為 #63 的 residue）。
- 不改 `telegram-all` CLI（#61 另案）。

## Success Criteria

- `logout` 在 TDLib 30 秒內沒完成時改名資料夾、不刪除任何檔案，下一次登入從空資料夾開始（單元測試，暫存目錄）。
- 以 stub 模擬連線狀態一直停在 Updating：讀取工具的回答多一段說明，`auth_status` 在門檻後回報停滯與重新登入的下一步（單元測試）。
- 連線為 Ready 時，回答與 `auth_status` 的既有欄位不變（回歸測試）。
- 不是 Ready 時，第一次讀取最多等到門檻就回答，不會無限等待（單元測試，注入時鐘）。
- 406 的錯誤不出現在任何回答或 `auth_status` 中（既有測試維持通過）。
- 在維護者機器上：重新登入前 `auth_status` 回報停滯；重新登入後回報 Ready，`get_chats` 出現 2026-04-30 之後的訊息（手動驗收）。

## Impact

- Affected specs: `telegram-tdlib-lifecycle`（追蹤同步狀態、開啟後有上限地等待、讀取回答的同步說明、`logout` 重置已不同步的 session）、`telegram-auth-coordination`（修改 `auth_status` 回應：增加 `connection_state`、`unsynced_seconds`、`sync_stalled`，停滯時 `next_step` 指向 `logout`）。`telegram-auth-error-reporting` 不變（406 規則照舊）。
- Affected code:
  - Modified: che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift, che-telegram-all-mcp/Sources/TelegramAllLib/TDLibLifecycle.swift, che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift, che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/AuthResponses.swift, che-telegram-all-mcp/README.md, che-telegram-all-mcp/CHANGELOG.md, plugins/che-telegram-mcp/README.md
  - New: che-telegram-all-mcp/Sources/TelegramAllLib/TDLibSyncState.swift, che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/SyncNote.swift, che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibSyncStateTests.swift, che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/SyncNoteTests.swift, che-telegram-all-mcp/Tests/TelegramAllLibTests/LogoutResetTests.swift
  - Removed: (none)
