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
- [ ] 7.3 維護者驗收（需維護者重新登入）：重新登入前 `auth_status` 顯示 `sync_stalled: true`、讀取回答有 `sync: not-synced`；維護者執行 `logout` 時記錄 TDLib 是否在 30 秒內完成、資料夾是否被改名（寫回 design.md「`logout` 以 30 秒為界，失敗時改名留存」一段）；重新登入後 `sync_stalled: false`、`get_chats` 出現 2026-04-30 之後的訊息（只記錄日期與數量）。驗證方式：結果貼到 #63（不含訊息內容） [after: 7.1, 7.2]
