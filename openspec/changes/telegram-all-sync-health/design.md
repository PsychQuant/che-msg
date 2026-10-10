## Context

#63：維護者 Mac 上的 TDLib 資料庫自 2026-04-30 起沒有任何新訊息，telegram-all 卻一切看似正常。2026-10-10 用資料庫複本實測（TDLib 1.8.60、log 等級 4）：授權狀態立即 `authorizationStateReady`，連線狀態 `connectionStateConnecting` → `connectionStateUpdating` 後 90 秒不變；`updates.getDifference` 7 次全部 `406 AUTH_KEY_DUPLICATED`，`GetConfig`、`GetDialogFilters` 也是；client 沒有收到任何 `error` 物件或授權狀態變化，`updateNewMessage` 為 0。

現況程式碼：`TDLibClient.handleUpdate` 只處理 `updateAuthorizationState`；`Server` 開 TDLib 時呼叫 `waitForAuthorizationToSettle(timeout: 30)` 後就開始回答；TDLib 路徑的讀取工具只回一段文字（本機快取路徑才有第二段 `localCacheNote`）；`auth_status` 由 `AuthResponses.authStatusResult` 組成 `{state, next_step, last_error}`，`state == ready` 時 `next_step` 必為 `null`；`logout` 只呼叫 `client.logOut()` 就回 `{"ok": true}`，之後 `TDLibLifecycle` 仍持有那個已關閉的 client。`TDLibLifecycle` 已有可注入的 `clock`。

## Goals / Non-Goals

**Goals:**

- 任何時候 TDLib 沒和 Telegram 同步，讀取的回答與 `auth_status` 都說出來，而不是靜靜回舊資料。
- 同步長期停滯時，指出最可能的原因（session 被 Telegram 作廢）與補救（`logout` → `auth_run`）。
- `logout` 在 session 已作廢時也能讓下一次登入從乾淨的資料夾開始。

**Non-Goals:**

- 不解讀 406 錯誤內容；`telegram-auth-error-reporting` 的 406 silent-ignore 不變。
- 不自動重新登入；不在 `logout` 之外搬動或刪除資料夾；任何情況都不刪除資料夾。
- 不改本機快取路徑（#58）的來源說明；不改 `telegram-all` CLI（#61）。
- 不跨 process 保存同步狀態：server 重啟後未同步時間從 0 起算（見 Risks）。

## Decisions

### 以連線狀態判斷同步，不解讀 406

維護者 2026-10-10 在三個做法中選 C。A（送一個需授權的請求、比對 `AUTH_KEY_DUPLICATED` 字串）與 B（只看錯誤碼 406）都要改寫 406 silent-ignore 規則，且 B 會把其他 406 誤判。C 只看 TDLib 自己公開的 `updateConnectionState`，同時涵蓋網路被擋、補資料卡住等其他「連得上卻不同步」的情形。代價：無法分辨「作廢」與「很慢」，所以用時間門檻並在文字上說「可能」。

### 未同步時間跨 idle close 累計

#58 讓 TDLib 閒置 600 秒就關閉。若只從本次開啟起算，已作廢的 session 每次重開都要再等 120 秒才被判定停滯，而 `auth_status` 往往正是重開後第一個呼叫。所以 server 在 process 內累計「TDLib 開著、自上次 Ready 以來」的秒數；TDLib 關閉期間不計，收到 Ready 歸零。狀態放在 server 層的 `TDLibSyncState`（不隨 `TDLibClient` 一起被丟棄）。

### 第一次使用最多等 10 秒，只等開啟它的那個呼叫

剛開 TDLib 時通常處於 Updating，立刻回答會給舊資料。等待只加在 lifecycle 的 open closure（`waitForAuthorizationToSettle` 之後、僅在授權 `ready` 時），所以只影響開啟 TDLib 的那一次；TDLib 已開時不等。10 秒是估計值：正常補一天份資料約數秒（apply 時以重新登入後的正常 session 量測確認，量測值寫回本段）。

### 停滯門檻 120 秒

`auth_status` 的 `sync_stalled` 與回答中的「可能已被作廢」文字都以 `unsynced_seconds >= 120` 為準。依據：作廢的 session 90 秒毫無進展；正常 session 補資料不應超過一分鐘。估計值，apply 時與 10 秒一起量測；若正常 session 開啟後的 Updating 時間接近 120 秒，提高門檻並記錄。

### 同步說明沿用 `localCacheNote` 的形式

第二段文字，第一行是機器可辨識的 `sync: not-synced`，其後是人看的說明，與 #58 的 `source: local-cache` 同一套慣例，呼叫端可以用第一行分辨。只附在成功的 TDLib 路徑回答；錯誤與本機快取回答不附。

### `logout` 以 30 秒為界，失敗時改名留存

（已由下一項取代，保留作為紀錄。）原做法：先送 TDLib `logOut`，30 秒內沒完成才關閉並改名。驗證第一輪（2026-10-10）指出：TDLibKit 的 `logOut()` 要等伺服器回覆、沒有逾時，離線時永遠不返回；有網路時已作廢的 key 很快拿到 406，TDLib 會完成登出並自己清掉本機資料庫。改名保存在兩個主要情境都碰不到。

### `logout` 只做本機重置，不向 Telegram 登出

**Supersedes**: telegram-all-sync-health / `logout` 以 30 秒為界，失敗時改名留存

維護者 2026-10-10 選定。`logout` 不送 `logOut`：關閉 TDLib（最多 30 秒，沒有網路往返，所以離線也不會卡住）→ 把資料夾改名為 `tdlib.invalidated-<UTC yyyyMMdd-HHmmss>` → 釋放 TDLib，下一次呼叫從新的空資料夾開始。本機資料永遠不刪。代價：舊 session 會留在帳號的裝置清單，要在 Telegram app 裡結束；回應與 README 都寫明這點，並警告改名後的資料夾裡的 key 仍有效，新 session 使用中時不可搬回。關不掉時失敗、資料夾不動；改名失敗時失敗、不釋放 TDLib，避免下一次呼叫在舊資料夾上重開。

### 只有補資料卡住才算停滯；登出要先問使用者

維護者 2026-10-10 選定。驗證第一輪指出：任何非 Ready 都累計會把離線、proxy 也判成停滯，而停滯的 `next_step` 指向會重置 session 的 `logout`，skill 又要模型照 `next_step` 做，違反「重新登入是維護者的操作」。改為：另記「更新中時間」（只累計 `connectionStateUpdating`，同樣跨 idle close、Ready 歸零），停滯 = 授權 ready 且目前在 Updating 且更新中時間 ≥ 120 秒；離線與 proxy 只在說明中提示檢查網路。`next_step` 的提示寫明先問使用者，skill 文件也這樣要求。計時改用單調時鐘（`ProcessInfo.systemUptime`），系統校時不影響、不出現負值。

### 同步說明只附在讀取工具

驗證第一輪指出原先附在所有 TDLib 路徑的成功回答，`auth_status` / `auth_run` 會多一段非 JSON 文字，寫入工具的「可能缺少新訊息」也不對。改為只附在十個讀取工具（`get_chats`、`search_chats`、`get_chat_history`、`search_messages`、`dump_chat_to_markdown`、`get_me`、`get_user`、`get_contacts`、`get_chat`、`get_chat_members`）。

## Implementation Contract

**Behavior**

- TDLib 路徑的成功回答，在未同步時多一段以 `sync: not-synced` 開頭的文字；同步時不變。
- `auth_status` 多 `connection_state`、`unsynced_seconds`、`sync_stalled` 三欄；`ready` 且停滯時 `next_step` 為 `{"tool":"logout","required_args":[],"hint":...}`；其他情形與現在相同。
- 開啟 TDLib 的那一次呼叫，授權 ready 時最多多等 10 秒。
- `logout` 不聯絡 Telegram：關閉 TDLib（最多 30 秒）→ 資料夾改名（不刪除）→ 釋放 TDLib；回應附上新名稱與「舊 session 要在 app 裡結束」。

**Interface / data shape**

- `TDLibSyncState`（`TelegramAllLib`，可注入 `clock`）：`func record(_ connectionState: String)`、`func tdlibOpened()`、`func tdlibClosed()`、`var connectionState: String?`、`var isSynced: Bool`、`var unsyncedSeconds: Int`、`func isStalled(threshold: Int = 120) -> Bool`。
- `TDLibClient`：`handleUpdate` 把 `.updateConnectionState` 與授權關閉交給 `TDLibSyncState`（狀態放在 server 層，不隨 client 丟棄）；`func waitForConnectionReady(timeout:isReady:) async -> Bool`；舊的 `logout() -> String` 移除。
- `TDLibLifecycle`：`func discardClosedClient() async`（狀態回 closed、釋放鎖）。
- `SyncNote.swift`（`CheTelegramAllMCPCore`）：`func syncNote(state: TDLibSyncState snapshot) -> String?`；`AuthResponses.authStatusResult` 增加三個參數。
- `auth_status` JSON 範例（停滯）：`{"state":"ready","next_step":{"tool":"logout","required_args":[],"hint":"..."},"last_error":null,"connection_state":"connectionStateUpdating","unsynced_seconds":130,"sync_stalled":true}`。

**Failure modes**

- 連線狀態一直沒有任何回報：`connection_state` 為 `null`，未同步時間仍累計（TDLib 開著即算）。
- 改名失敗（權限、目標已存在）：`logout` 回錯誤並說明資料夾未變動，不刪除任何東西。

**Acceptance / verification targets**

- `TDLibSyncStateTests`：Ready 歸零、跨 idle close 累計（spec 的範例表逐列）、門檻判定。
- `SyncNoteTests`：spec「sync note lines」範例逐列；同步時無說明；錯誤與本機快取路徑無說明。
- `AuthStatusNextStepTests`（既有檔案擴充）：spec「response shape」範例逐列，含 ready+130 秒。
- `LogoutResetTests`：stub client 不報 closed → 暫存目錄被改名、內容原封不動、`discardClosedClient` 被呼叫。
- 手動：維護者機器上重新登入前後的 `auth_status` 與 `get_chats`（proposal 的 Success Criteria）。

**Scope boundaries**

- In scope：`TDLibClient`、`TDLibLifecycle`、`Server`、`AuthResponses`、新 `TDLibSyncState` / `SyncNote`、測試、兩份 README 與 CHANGELOG。
- Out of scope：406 規則、`LocalTDLibReader` 與 `localCacheNote`、wrapper、CLI、自動重新登入。

## Risks / Trade-offs

- [正常 session 剛開時被標未同步] → 第一次呼叫最多等 10 秒；之後的說明文字說「可能缺少新訊息」而非「資料錯誤」。
- [server 重啟後停滯判定要再等 120 秒] → 接受；`auth_status` 仍顯示 `connection_state` 與 `unsynced_seconds`，README 說明如何辨識。
- [門檻是估計值] → apply 時量測正常 session 的 Updating 時間，若接近門檻就調整並記錄於本文件。
- [`logout` 改名後維護者以為訊息不見] → 回應寫出新資料夾名稱；README 說明它是備份、可手動刪除或還原。
