## 2. 同步狀態追蹤

- [x] 2.1 依 design「以連線狀態判斷同步，不解讀 406」新增 `TDLibSyncState`（可注入 clock；只讀 `updateConnectionState`，不讀任何 406 訊息），滿足「Server tracks whether TDLib is synced with Telegram」：記錄連線狀態、Ready 歸零、TDLib 開著才累計、跨 idle close 累計、`isStalled(threshold:)`。驗證方式：`TDLibSyncStateTests` 逐列通過 spec「unsynced duration over time」範例表，含 Ready 歸零與關閉期間不計時兩個情境
- [x] 2.2 `TDLibClient.handleUpdate` 把 `.updateConnectionState` 交給注入的回呼；`Server` 在 lifecycle 開啟與關閉 TDLib 時呼叫 `tdlibOpened()` / `tdlibClosed()`，並把回呼接到 `TDLibSyncState.record`。驗證方式：`TDLibSyncStateTests` 以 stub 連線狀態序列驅動回呼，狀態與秒數符合預期；全套 `swift test --skip E2ETests` 通過 [after: 2.1]

## 3. 開啟時有上限地等待同步

- [x] 3.1 依 design「第一次使用最多等 10 秒，只等開啟它的那個呼叫」，lifecycle 的 open closure 在 `waitForAuthorizationToSettle` 之後、僅於授權 `ready` 時呼叫 `waitForConnectionReady(timeout: 10)`，滿足「First use waits a bounded time for TDLib to sync」；已開啟時的呼叫不等待。驗證方式：以注入 clock 的單元測試證明 Ready 在 2 秒時到達會提前返回、一直不到時於 10 秒返回、授權未 ready 時不等待 [after: 2.2]

## 4. 回答附同步說明

- [x] 4.1 依 design「同步說明沿用 `localCacheNote` 的形式」新增 `SyncNote.syncNote(...)` 並在 `Server` 的 TDLib 路徑成功回答後附第二段文字，滿足「Answers from TDLib state when TDLib is not synced」：首行 `sync: not-synced`、狀態名、秒數、可能缺少新訊息；滿 120 秒加註 session 可能被作廢與 `logout` → `auth_run`；同步時、錯誤時、本機快取回答都不附。驗證方式：`SyncNoteTests` 逐列通過 spec「sync note lines」範例表，並含錯誤與本機快取兩個不附說明的測試；`ToolRoutingTests` 既有測試不變仍通過 [after: 2.2]

## 5. auth_status 回報同步狀態

- [x] 5.1 `AuthResponses.authStatusResult` 增加 `connection_state`、`unsynced_seconds`、`sync_stalled`，`ready` 且停滯時 `next_step` 為 `{"tool":"logout","required_args":[],"hint":...}`，滿足修改後的「`auth_status` response includes structured next-step hint」；`Server` 的 `auth_status` 與工具描述同步更新。驗證方式：`AuthStatusNextStepTests` 逐列通過 spec「response shape」範例表（含 ready 0 秒、60 秒、130 秒三列），既有測試依新欄位更新後通過 [after: 2.2]

## 6. logout 重置

- [x] 6.1 `TDLibLifecycle` 新增 `discardClosedClient()`（狀態回 closed、釋放鎖）；`logout` 等待 TDLib 報告 closed（或回到等待參數 / 電話號碼）最多 30 秒，逾時則關閉 TDLib 並把資料夾改名為 `tdlib.invalidated-<UTC yyyyMMdd-HHmmss>`，回應附新名稱，任何情況都不刪除檔案，滿足「Logout resets a session that no longer syncs」。驗證方式：`LogoutResetTests` 以 stub client 與暫存目錄證明逾時時目錄被改名、檔案數與內容不變、`discardClosedClient` 被呼叫，完成時不改名；`TDLibLifecycleTests` 既有測試通過 [after: 2.2]

## 7. 文件與發布前驗收

- [x] 7.1 `che-telegram-all-mcp/README.md` 與 `plugins/che-telegram-mcp/README.md` 新增「telegram-all 不再同步」一節：怎麼從 `sync: not-synced` 與 `auth_status.sync_stalled` 辨識、可能原因（同一 session 同時在兩處使用）、補救（`logout` → `auth_run`、改名的資料夾是備份）；`che-telegram-all-mcp/CHANGELOG.md` 的 `[Unreleased]` 記錄行為變更。驗證方式：`tests/che-telegram-mcp/test-plugin-layout.sh` 與 `claude plugin validate plugins/che-telegram-mcp` 通過；內容審閱 [after: 4.1, 5.1, 6.1]
- [ ] 7.2 量測門檻：以正常（重新登入後）session 開啟 TDLib，記錄由開啟到 `connectionStateReady` 的秒數三次，與 10 秒 / 120 秒比較，量測值與結論寫進 design.md 對應兩段；若接近門檻則調整常數並更新 spec 與測試。驗證方式：design.md 含三次量測值與日期 [after: 3.1, 4.1, 5.1]
- [ ] 7.3 維護者驗收（需維護者重新登入）：重新登入前 `auth_status` 顯示 `sync_stalled: true`、讀取回答有 `sync: not-synced`；維護者確認後執行 `logout`，記錄 TDLib 是否在 30 秒內關閉、資料夾是否改名為 `tdlib.invalidated-*` 且檔案完整；重新登入後 `sync_stalled: false`、`get_chats` 出現 2026-04-30 之後的訊息（只記錄日期與數量）。驗證方式：結果貼到 #63（不含訊息內容） [after: 7.1, 7.2]

## 8. 驗證第一輪修正（2026-10-10；維護者選定：本機重置、只算補資料卡住）

- [x] 8.1 依 design「只有補資料卡住才算停滯；登出要先問使用者」，`TDLibSyncState` 另記「更新中時間」（只累計 `connectionStateUpdating`，跨 idle close、Ready 歸零），`isStalled` 改為「目前在 Updating 且更新中時間 ≥ 120」；計時改用單調時鐘並保證不為負；`reset()` 在已開且 Ready 時不開新段落，滿足修改後的「Server tracks whether TDLib is synced with Telegram」。驗證方式：`TDLibSyncStateTests` 新增「離線 200 秒再更新 30 秒 → 未同步 230、更新中 30、不停滯」、「Ready 時 reset 不累計」、時鐘倒退不出現負值三個測試，既有測試通過
- [x] 8.2 同步說明只附在十個讀取工具；離線與 proxy 狀態加一句檢查網路；停滯說明寫明先問使用者再 `logout` → `auth_run`，滿足修改後的「Answers from TDLib state when TDLib is not synced」。驗證方式：`SyncNoteTests` 逐列通過新範例表（含 WaitingForNetwork 300 秒不提 `logout`），並以 `shouldAttachSyncNote(tool:)` 測試十個讀取工具附、`auth_status` / `send_message` / `logout` 不附 [after: 8.1]
- [x] 8.3 `auth_status` 的 `sync_stalled` 改用更新中時間與目前狀態，停滯提示寫明先問使用者，滿足修改後的 `auth_status` 需求。驗證方式：`AuthStatusNextStepTests` 新增 ready + WaitingForNetwork 300 秒 → `sync_stalled: false`、`next_step: null`，停滯提示含「ask the user」，並補上 waitingForParameters / PhoneNumber / Password 三列的 `sync_stalled: false` 斷言 [after: 8.1]
- [x] 8.4 `logout` 改為本機重置（不送 `logOut`），取代 design「`logout` 以 30 秒為界，失敗時改名留存」：`TDLibSessionReset.reset` 關閉 TDLib → 改名；server 的 logout 流程抽成可測函式，成功時丟棄 client 並歸零同步狀態，關不掉或改名失敗時不丟棄 client，滿足「Logout resets the local session without contacting Telegram」；補足任務 6.1 原寫的驗證（`discardClosedClient` 是否被呼叫）並不成立的缺口。驗證方式：`LogoutResetTests` 以假 client 與暫存目錄證明成功時改名且檔案不變、丟棄與歸零各被呼叫一次；關不掉時目錄不動且不丟棄；目標已存在時兩個目錄都不動且不丟棄；全程沒有任何登出請求
- [x] 8.5 等待迴圈在 task 取消時立即返回；`TDLibClient` 在建立 TDLib client 前就通知同步狀態已開啟；`authStatusResult` 的序列化備援字串含三個新欄位。驗證方式：`TDLibSyncWaitTests` 新增取消後立即返回的測試；全套 `swift test --skip E2ETests` 通過
- [x] 8.6 文件：兩份 README 與 `plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md` 說明停滯只算補資料卡住、離線只提示網路、`logout` 是本機重置（不聯絡 Telegram、不刪資料、舊 session 要在 app 裡結束、改名資料夾的 key 仍有效不可搬回）且必須先經使用者確認；`che-telegram-all-mcp/CHANGELOG.md` 記錄 `TDLibClient.logout()` 移除與 `logout` 行為改變。驗證方式：`tests/che-telegram-mcp/*.sh` 與 `claude plugin validate plugins/che-telegram-mcp` 通過；內容審閱 [after: 8.2, 8.3, 8.4]

