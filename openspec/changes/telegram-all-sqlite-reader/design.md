## Context

- `Server.init` 一啟動就建立 `TDLibClient`；`TDLibClient` 建立 TDLib client 後，auto-fire 在收到 `authorizationStateWaitTdlibParameters` 時送出參數，TDLib 隨即打開 `~/Library/Application Support/che-telegram-all-mcp/tdlib` 裡的 `td.binlog`（加 advisory 寫鎖）與 `db.sqlite`。之後一直開著到 process 結束。
- wrapper（`che-telegram-all-mcp-wrapper.sh`）在啟動 binary 前先拿自己的鎖：有 `flock` 指令時用 `~/.cache/che-telegram-all-mcp.lock.flock`，否則（macOS 預設）用 `mkdir ~/.cache/che-telegram-all-mcp.lock` 並寫 `owner.pid`。拿不到就回 JSON-RPC 錯誤並結束。
- TDLib 1.8.60（`cb863c16`）的本機快取格式，已在 PsychQuant/che-msg#58 的 Diagnosis comment 查證：
  - 空的 `databaseEncryptionKey` 被 TDLib 換成 `cucumber`（`TdDb::as_db_key`）；有金鑰時 SQLite 一律加密
  - SQLite 金鑰是隨機 32 bytes，存在 binlog 的 `sqlite_key`；binlog 以 AES-CTR 加密，金鑰由 `cucumber` 加上 binlog 開頭事件的鹽值經 PBKDF2-SHA256 推導（raw key 只迭代 2 次）
  - SQLite 為 WAL 模式、無獨占鎖；TDLibFramework 已匯出 `tdsqlite3_key` 等 SQLCipher 函式
  - `messages` 表有 `dialog_id`、`message_id`、`sender_user_id`、`text`、`data`（TDLib 內部序列化）；`dialogs` 表有 `dialog_id`、`dialog_order`、`data`；使用者存在 `common` 表，鍵為 `us<id>`。名稱、日期、訊息文字都在內部序列化資料裡
  - 可行性驗證 1.2（2026-10-09，本機一份實際資料庫的複本）實測：`messages` 2,586 筆，`text`、`search_id` 全部為空，`messages_fts` 0 筆；`data` 2,586 筆皆有值（平均 155 bytes）；`sender_user_id` 2,586 筆皆非 0。所以訊息文字只能從 `data` 解出，寄件人可直接取 `sender_user_id` 欄位
  - 可行性驗證 1.3（同一份複本）：所有 `us`、`gr`、`ch` 與 `messages.data` 的版本號皆為 57；使用者名字 243/243 解出；一般群組名稱 15 個解出 13 個、頻道名稱 4 個解出 2 個（任務 3.3 查明原因在查詢條件：`LIKE 'gr%'`、`LIKE 'ch%'` 把 TDLib 存完整資訊的 `grf<id>`、`chf<id>` 紀錄也撈進來，「13/15」裡有 5 筆是 `grf` 碰巧解成合法 UTF-8；改用精確 key 後群組 8/8、頻道 2/2 全部解出）；訊息 2,586 筆的 `message_id` 與寄件人和資料表欄位一致率 100%、97% 解到內容（2,283 筆文字訊息全部解出），73 筆停在內容前（72 筆頻道留言資訊、1 筆轉寄資訊）
  - 同一次驗證：以 `SQLITE_OPEN_READONLY` 打開 WAL 模式的資料庫後，`db.sqlite` 與 `db.sqlite-wal` 不變，`db.sqlite-shm` 的修改時間改變（大小不變）。這是 SQLite 讀取者在共享索引檔登記讀取狀態的標準行為
- 讀取類工具目前回傳 JSON（`chatToDict`、`messageToDict` 的欄位：`id`、`chat_id`、`title`、`type`、`unread_count`、`last_message`、`date`、`sender`、`is_outgoing`、`text`、`caption`）；錯誤回應是 `isError: true` 加 JSON 內容 `{"type":"tdlib_error","code":…,"message":…}`。

## Goals / Non-Goals

**Goals:**

- 多個 Claude Code session 同時啟用 telegram-all 時，任何一個 session 都能讀 Telegram 的聊天列表、對話內容與搜尋結果
- 沒有在用 Telegram 的 session 不持有 TDLib
- 任何時刻最多一個 process 開著同一份 TDLib 資料庫
- 讀取器只讀不寫，金鑰不外流，遇到沒驗證過的格式時明確失敗

**Non-Goals:**

- 從未持有 TDLib 的 session 送訊息或做其他寫入（寫入仍只能由持有 TDLib 的 process 做）
- 讀取器支援 `get_me`、`get_user`、`get_contacts`、`get_chat`、`get_chat_members`（第一版回「此模式不支援」）
- 讀取器支援 TDLib 1.8.60（`cb863c16`）以外的版本
- 下載媒體檔案、讀取秘密聊天的內容
- 共用背景程式架構（使用者 2026-10-09 在 spectra-discuss 中選擇直接讀 SQLite，不採用）
- 在 TDLib 資料庫的複本上開離線 TDLib：複本帶同一份登入金鑰，只要連上 Telegram 就可能觸發 `AUTH_KEY_DUPLICATED`（Telegram 會讓該登入失效、必須重新登入），且 `setNetworkType` 只能在設定參數之後送出，無法保證不連線
- 修正 PsychQuant/che-msg#59（被擋下時的錯誤顯示）；那是另一張 issue

## Decisions

### 用到才開 TDLib、閒置釋放鎖

server 啟動時不建立 TDLib client。第一個需要 TDLib 的工具呼叫進來時才判斷：鎖空著就取得鎖並開 TDLib；之後每次呼叫重置閒置計時，閒置超過時限就關閉 TDLib（等到 `authorizationStateClosed`）再釋放鎖。時限預設 600 秒，可用環境變數 `CHE_TELEGRAM_ALL_IDLE_TIMEOUT`（秒）調整，`0` 代表不自動關閉（等同現行行為）。

開啟之後還有三點，都是任務 5.2 兩個 session 的實機驗證找到或確認的：

- 開 TDLib 後先等登入狀態穩定（最多 30 秒）才回應這次呼叫：已登入、已關閉、自動填入失敗，或停在環境變數無法提供的輸入（驗證碼，或沒設 `TELEGRAM_PHONE`／`TELEGRAM_2FA_PASSWORD` 時的電話與密碼）。判斷沿用既有的 `decideAutoFire`：它沒有東西可送時就算穩定。沒有這一步，第一個呼叫會在 TDLib 還在登入時回「Not authenticated」（實測如此；舊版 v0.5.0 在啟動後立刻呼叫也一樣，只是平常被 MCP 初始化的時間差蓋住）
- 整個 process 只用一個 `TDLibClientManager`：TDLib 只允許一條執行緒呼叫 `td_receive`，而每個 manager 都有自己的接收迴圈、每次最多卡在 `td_receive` 10 秒；閒置關閉後若用新的 manager 重開，新舊兩條迴圈會同時呼叫 `td_receive`，新 client 的回應可能被舊迴圈收走
- MCP 連線結束時，server 先取消閒置檢查、關閉 TDLib、釋放鎖，再讓 process 結束。原先交給 `TDLibClient` 的 deinit 關閉，而 deinit 會在閒置檢查的背景 task 放手時於另一條執行緒執行，和 process 結束同時進行；實測約每 6 次結束有 1 次在 TDLib 的 `Td::clear` 當機（segmentation fault）。改在主流程關閉後，連續 12 次都正常結束

替代方案：維持啟動即開、只在被擋時改走讀取器——但這樣「沒在用的 session 不佔住」的目標達不到，被擋的情況會照常發生。

### 鎖改由 server 以 flock 持有並承認舊版鎖目錄

TDLib 的鎖改由 server 在開 TDLib 前取得：對 `~/.cache/che-telegram-all-mcp.tdlib.lock` 做 `flock(LOCK_EX | LOCK_NB)`，成功後把自己的 PID 寫進同目錄的 `che-telegram-all-mcp.tdlib.owner`。process 結束時 kernel 自動釋放 flock，不會留下過期的鎖。判斷「是否被別人持有」時，同時檢查舊版 wrapper 的 `~/.cache/che-telegram-all-mcp.lock/owner.pid`：PID 還活著就視為被持有，避免新舊版本並存時兩個 process 同時開 TDLib。

舊版 wrapper 是在啟動自己的 server 之前才建立鎖目錄，所以 server 取得 flock 之後再檢查一次舊版鎖目錄；這段空窗內若出現存活的舊版 owner，就放掉 flock、視為被持有。

不處理舊版 wrapper 的 flock 模式：舊版只有在系統裝了 `flock` 指令時才改用 `~/.cache/che-telegram-all-mcp.lock.flock`（不記 PID），macOS 預設沒有這個指令（使用者機器 2026-10-09 確認沒有）。在裝了 `flock` 的機器上新舊版並存時，兩邊可能同時開 TDLib；只影響這種機器上新舊版並存的過渡期，舊版 session 重啟後就不再發生，所以接受（使用者 2026-10-09 同意寫為範圍外）。

替代方案：沿用 wrapper 的 mkdir 鎖——但 mkdir 鎖要靠 PID 判斷是否過期，而且 wrapper 拿鎖的時機在 server 啟動前，無法做到「用到才拿」。

### wrapper 拿不到鎖時不再拒絕

wrapper 不再取得任何鎖，也不再因為別的 session 而結束；它照現行的 fork + wait + trap 方式啟動 binary（保留結束時清理自己啟動的 binary）。lock-refused 的 JSON-RPC 錯誤路徑移除。舊版 wrapper 的鎖目錄只在新版 server 判斷時讀取，不再被建立。

同時移除 PID 追蹤裡「舊 PID 還活著就殺掉」的分支，並且不再使用共用的 `~/.cache/che-telegram-all-mcp.pid`。現行 wrapper 註解說明這個分支只是「被鎖擋住後就不會執行到」的保險；鎖拿掉之後，第二個 session 的 wrapper 會讀到第一個 session 的 binary PID（還活著、名稱相符）並把它殺掉。清理只需要 wrapper 自己記住的 `BIN_PID`，不需要共用 PID 檔。wrapper 只能對自己啟動的 binary 送訊號。

替代方案：保留共用 PID 檔但改成只記錄、不殺——仍會被多個 session 互相覆寫，對清理沒有用處，所以直接移除。

wrapper 只剩兩種情況會在啟動 server 前結束：Keychain 沒有 API 憑證，或取不到 binary（找不到 release asset、下載失敗）。這兩種情況沿用 #31 的做法，回應等待中的 `initialize` 請求一個 JSON-RPC 2.0 錯誤（`code` -32000、說明原因的 `message`、`data.docsUrl` 指向 plugin README 的「When telegram-all does not start」），讓 Claude Code 顯示原因，而不是籠統的 -32000。這也讓結構測試 check (j) 仍有 wrapper 的 `docsUrl` 可檢查——原本唯一的 `docsUrl` 在被移除的 lock-refused 錯誤裡，check (j) 要求 `bin/` 至少有一個。使用者 2026-10-09 同意。

### 本機讀取器直接解 binlog 與 SQLCipher

`TelegramAllLib` 新增唯讀的本機讀取器，分三層，各自可單獨測試：

1. binlog 解碼：讀 `td.binlog`，以 `cucumber` 經 PBKDF2-SHA256（依加密事件的鹽值與迭代次數）推導 AES-CTR 金鑰，逐一解出事件；只採用長度與 CRC 皆正確的完整事件；從 binlog PMC 事件取出 `sqlite_key`
2. SQLCipher 唯讀開檔：用 TDLibFramework 內建的 `tdsqlite3_open_v2`（`SQLITE_OPEN_READONLY`）與 `tdsqlite3_key` 打開 `db.sqlite`
3. 格式解析：依 `dialog_id` 的數值範圍判斷聊天類型（正數為私人對話、`-1000000000000` 到 `-2000000000000` 之間為頻道／超級群組、其餘負數為一般群組），名稱從 `common` 表的 `us<id>`、`gr<id>`、`ch<id>` 解出；`messages.data` 解成訊息日期、寄件人、是否自己送出、內容類型與文字。不需要解 `dialogs.data`（聊天列表與順序用 `dialogs` 表的 `dialog_id`、`dialog_order` 欄位）

替代方案見 Non-Goals（共用背景程式、離線 TDLib 複本）。

### 讀取器允許 SQLite 更新共享索引檔

讀取器直接以唯讀方式開 TDLib 資料夾內的 `db.sqlite`，不寫 `db.sqlite`、`db.sqlite-wal`、`td.binlog`，也不新增或刪除檔案；唯一例外是 SQLite 為多程序讀取維護的 `db.sqlite-shm`，讀取者會在上面登記讀取狀態。這是使用者在 2026-10-09 套用（apply）過程中選定的做法。

沒有持有者時另有處理：TDLib 正常關閉後 `db.sqlite-wal`、`db.sqlite-shm` 都不存在，這時唯讀連線會自己建立這兩個檔、而且無法刪除（任務 3.2 的測試實測），違反「不新增檔案」。所以讀取器在 `db.sqlite-wal` 不存在時改以 URI 參數 `immutable=1` 開檔：不加鎖、不建 -wal 與 -shm。`db.sqlite-wal` 存在時照常唯讀開檔，才讀得到持有者還沒寫回主檔的訊息。代價：以 immutable 開檔讀取的期間，若剛好有持有者開啟並把 WAL 寫回主檔，讀到的頁面可能不一致；讀取只有數十毫秒，接受。

替代方案：每次先把 `db.sqlite`、`-wal`、`-shm` 複製到私人暫存目錄、以 immutable 模式讀複本——TDLib 資料夾完全不被碰，但每次要複製約 12 MB（本機實測），且持有者正在寫入時可能複製到不一致的快照，所以不採用。

### 讀取器以逐筆解出的文字搜尋訊息

`messages_fts` 與 `messages.text` 實測為空，`search_messages` 改為逐筆解出訊息文字後比對查詢字串（不分大小寫的子字串比對），不依賴 TDLib 的全文索引。

### 測試資料拆成三種來源

原計畫用 Telegram 測試環境的兩個測試帳號產生完整的測試資料庫，但 Telegram 已停用測試帳號：TDLib 維護者在 tdlib/td#3083（2026-01-05）說明，測試環境現在要用真實手機號碼、並透過官方 App 建立帳號；任務 2.1 實測，測試號碼的固定驗證碼一律回 `PHONE_CODE_INVALID`（連線經確認只到測試環境 DC1 `149.154.175.10`）。使用者在 2026-10-09 選定改為三種來源：

1. 金鑰與開檔（binlog 解碼、SQLCipher 開檔、版本檢查）：用 TDLib 建立一個**從未登入**的資料夾——`td.binlog` 的加密事件與 `sqlite_key`、加密的 `db.sqlite` 與資料表結構都由 TDLib 產生，沒有任何個人資料，可以 commit
2. 格式解析（使用者、群組、頻道、訊息）：依 TDLib 1.8.60 原始碼的欄位順序手工組出位元組，期望值是固定字面值；需要整個資料庫的測試（5 個工具），把這些資料列插入第 1 種資料夾的資料庫複本（用同一把金鑰）
3. 獨立對照：一個只在設了環境變數時才執行的比對測試，讀本機真實的 TDLib 資料庫，和 TDLib 模式的輸出逐筆比對；不寫出、不 commit 任何資料

替代方案：使用者用自己的手機號碼建測試環境帳號——產生的資料庫含該手機號碼，不能放進公開 repo，CI 也跑不到，所以不採用。

### 讀取器只接受驗證過的 TDLib 版本

讀取器在開檔前檢查 TDLib 版本（讀 TDLibFramework 回報的版本字串，並比對 SQLite 的 `PRAGMA user_version` 與 binlog 的格式特徵）。只接受 `1.8.60`（`cb863c16`）與其 SQLite `user_version`；其他一律回 `local_reader_unavailable`，原因 `unsupported_tdlib_version`。解析途中遇到不認得的欄位旗標或型別時，該筆資料標為無法解析，不猜測內容。

### 讀取器模式的回應附加來源標記

讀取器回應的 JSON 內容與 TDLib 模式的欄位相同；另外在 MCP 結果加第二個文字內容項目，說明資料來自本機快取、持有 TDLib 的 PID、無法解析而略過內容的訊息數，以及結果涵蓋的每個對話在快取中最新一則訊息的日期，並註明快取只含 TDLib 載入過的訊息、Telegram 上可能有更新的內容。讀取器無法得知的欄位（例如 `unread_count`）直接省略，不填假值。

標出資料多舊是使用者在 2026-10-09 看到可行性驗證 1.3 的新鮮度結果後的決定（見 Risks）。

### 先做三項可行性驗證作為關卡

正式實作前，在 TDLib 資料夾的檔案複本上依序驗證：(1) 從 `td.binlog` 解出 `sqlite_key`；(2) 用該金鑰唯讀打開 `db.sqlite` 並讀出 `messages.text`；(3) 從 `dialogs.data`、`us<id>`、`messages.data` 解出聊天名稱、使用者名稱、日期、寄件人。任一項失敗，就停止實作、把結果記到 PsychQuant/che-msg#58，並重新討論方向。驗證只讀複本，不開原檔、不寫原資料夾。

## Implementation Contract

**行為**

- 啟用 telegram-all 的 session 啟動後不持有 TDLib；`~/.cache/che-telegram-all-mcp.tdlib.lock` 在第一次需要 TDLib 的呼叫前不被鎖住
- 需要 TDLib 的工具被呼叫、且沒有別的 process 持有鎖時：取得鎖、開 TDLib、照現行行為回應；閒置超過 `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` 秒（預設 600）後關閉 TDLib 並釋放鎖
- 鎖被別的 process 持有時：
  - `get_chats`、`search_chats`、`get_chat_history`、`search_messages`、`dump_chat_to_markdown` 由讀取器回應
  - `get_me`、`get_user`、`get_contacts`、`get_chat`、`get_chat_members` 回 `local_reader_unsupported`
  - 寫入工具（`send_message`、`edit_message`、`delete_messages`、`forward_messages`、`pin_message`、`unpin_message`、`set_chat_title`、`set_chat_description`、`mark_as_read`、`create_group`、`add_chat_member`）、`auth_*`、`logout` 回 `tdlib_in_use`
- 開 TDLib 後先等登入狀態穩定（最多 30 秒）再回應；MCP 連線結束時先關 TDLib、釋放鎖，再結束 process
- wrapper 不會因為別的 session 而拒絕啟動；只在缺 API 憑證或取不到 binary 時於啟動前結束，並以回應 `initialize` 的 JSON-RPC 錯誤說明原因（`data.docsUrl` 指向 README「When telegram-all does not start」）

**介面與資料格式**

- 環境變數 `CHE_TELEGRAM_ALL_IDLE_TIMEOUT`：非負整數秒；非數字或負數時使用預設 600 並在 stderr 印一行警告
- 鎖檔 `~/.cache/che-telegram-all-mcp.tdlib.lock`（flock），PID 檔 `~/.cache/che-telegram-all-mcp.tdlib.owner`
- 錯誤回應皆為 `isError: true`，內容是一個 JSON 文字項目：
  - `{"type":"tdlib_in_use","lock_holder_pid":<int 或 null>,"message":<string>}`
  - `{"type":"local_reader_unsupported","tool":<string>,"message":<string>}`
  - `{"type":"local_reader_unavailable","reason":"unsupported_tdlib_version"|"key_not_found"|"database_unreadable"|"not_authenticated","message":<string>}`
- 讀取器成功回應：第一個內容項目是與 TDLib 模式相同欄位的 JSON；第二個內容項目是文字，含 `source: local-cache`、持有鎖的 PID、略過的訊息數，以及每個涵蓋對話的「快取中最新訊息日期」（無快取訊息則註明），並說明 Telegram 上可能有更新的內容
- `TelegramAllLib` 對外提供 `LocalTDLibReader` 型別，方法對應上述 5 個工具（與 `TDLibClient` 同名同參數），回傳與 `TDLibClient` 相同欄位的 JSON 字串

**失敗模式**

- TDLib 版本不符、找不到 `sqlite_key`、資料庫打不開 → `local_reader_unavailable`，不退回任何部分結果
- 單筆訊息或聊天的 `data` 無法解析 → 該筆照常列出資料表欄位可得的值（訊息：`id`、`chat_id`、`sender`（來自 `sender_user_id`）；聊天：`id`），`type` 為 `unknown`；計入第二個內容項目的略過數。訊息的固定開頭（旗標、`message_id`、寄件人、日期）若解出、且 `message_id` 與欄位相符，另附解出的 `date` 與 `is_outgoing`；開頭含 1.8.60 未定義的旗標位元、版本較新、或 `message_id` 不符時，只列資料表欄位
- binlog 的 key-value 區沒有 `auth` = `ok`（從未登入或已登出）→ `local_reader_unavailable`，原因 `not_authenticated`
- binlog 檔尾不完整的事件 → 略過，不視為錯誤
- 讀取期間持有者關閉 TDLib → 本次照讀到的回應；下一次呼叫重新判斷鎖
- 關閉 TDLib 逾時（30 秒內沒收到 `authorizationStateClosed`）→ 不釋放鎖、在 stderr 記錄，下次閒置檢查再試

**驗收方式**

- `swift test --skip E2ETests` 通過，新增：binlog 解碼、金鑰推導、SQLCipher 唯讀開檔、三種格式解析的單元測試（測試資料依「測試資料拆成三種來源」，不含真實帳號資料）；鎖判斷（空鎖、別人持有、舊版鎖目錄 PID 存活／已死）；閒置計時；工具分流與三種錯誤 JSON
- `tests/che-telegram-mcp/test-wrapper-*.sh` 更新：wrapper 在別的 process 持有鎖時仍啟動 binary；另一個 wrapper 啟動的 `CheTelegramAllMCP` 還活著時，新 wrapper 不對它送任何訊號；wrapper 結束時只清理自己啟動的 binary
- 手動驗證（在使用者自己的機器上）：session A 呼叫一次 `get_chats` 讓它持有 TDLib；session B 啟動並呼叫 `get_chat_history`，得到 `source: local-cache` 的結果；session B 呼叫 `send_message` 得到 `tdlib_in_use`；A 閒置超過時限後，B 再呼叫 `get_chat_history` 改由 TDLib 回應
- 讀取器測試確認：除了 SQLite 自己維護的 `db.sqlite-shm` 之外，TDLib 資料夾內的檔案在讀取前後大小與修改時間不變、沒有新增或刪除；金鑰不出現在任何輸出與錯誤訊息中

**範圍**

- 範圍內：TDLib 延後開啟與閒置關閉、server 端的鎖、wrapper 移除鎖、本機讀取器（5 個工具）、錯誤格式、README Multi-session limitation 段、新版 binary release 與 `DESIRED_VERSION`／plugin 版本更新
- 範圍外：讀取器支援其他工具或其他 TDLib 版本、從非持有者寫入、媒體下載、秘密聊天、PsychQuant/che-msg#59、telegram-bot server、舊版 wrapper 的 flock 模式鎖檔（`~/.cache/che-telegram-all-mcp.lock.flock`，見「鎖改由 server 以 flock 持有並承認舊版鎖目錄」）、照片／影片／文件的 `caption`（存在媒體物件之後，需解析檔案描述；讀取器省略此欄位）

## Risks / Trade-offs

- [TDLib 內部格式比預期複雜，日期或寄件人解不出來] → 由可行性驗證關卡提前發現；失敗即停止並回到討論，不做半成品
- [升級 TDLib 後讀取器失效] → 版本檢查讓它明確報錯；升級 TDLib 時必須重跑讀取器測試並更新支援的版本
- [讀 binlog 時 TDLib 正在寫入] → 只採用 CRC 正確的完整事件；`sqlite_key` 在登入後就不再變動
- [讀取器取得整份快取的金鑰] → 金鑰只受公開常數 `cucumber` 保護，本機能讀這些檔案的程式本來就能取得，不算新增暴露面；讀取器不記錄、不快取、不輸出金鑰，測試檢查輸出不含金鑰
- [新舊版 telegram-all 並存（另一個 session 還在跑舊版 wrapper）] → 新版判斷鎖時承認舊版鎖目錄的存活 PID；舊版 flock 模式（只在裝了 `flock` 指令的機器上）不在範圍內，該情況下仍可能兩邊同時開 TDLib，直到舊版 session 重啟
- [閒置關閉後下一次呼叫要重開 TDLib，回應變慢] → 用 `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` 調整，`0` 恢復現行常駐行為
- [可行性驗證用到真實帳號資料的複本，內含登入金鑰與第三方私訊] → 複本只放在 repo 外的暫存目錄，驗證後刪除，絕不 commit；要 commit 的測試資料依「測試資料拆成三種來源」產生，不含任何個人資料
- [手工組出的格式測試資料與解析程式出自同一份對 TDLib 原始碼的解讀，讀錯時兩者一起錯] → 以可選的真實資料比對測試，以及 5.2 手動驗證時與 TDLib 模式逐筆比對，作為獨立的對照
- [快取只含 TDLib 載入過的訊息，可能比 Telegram 上舊很多] → 可行性驗證 1.3 實測：有快取訊息的 30 個對話，最新一則全部超過 90 天（最新到 2026-04-30）；另一個 session 的 TDLib 執行一個半小時，`td.binlog` 持續寫入但 SQLite 沒有被寫（該期間是否有新訊息未確認）。原先「持有者持續同步、讀到的就是最新」的假設不成立。使用者決定照原方向繼續，以第二個內容項目逐對話標出快取中最新訊息的日期，讓呼叫者知道資料多舊

## Migration Plan

1. 發布新版 binary（含延後開啟、server 端鎖、讀取器）
2. 同一版 plugin 更新 wrapper（移除鎖）、`DESIRED_VERSION`、README、CHANGELOG
3. 使用者更新 plugin 後，各 session 重啟即生效；舊版 session 持有的鎖目錄由新版承認，舊 session 結束後自然消失
4. 回復：重裝上一版 plugin（wrapper 恢復鎖、`DESIRED_VERSION` 指回上一版 binary）

## Open Questions

- （已解決，任務 3.5）`search_chats` 的名稱比對：以不分大小寫的子字串比對聊天標題（私人對話的標題就是對方姓名，與 TDLib 的組法相同），範圍是快取知道的所有對話（含封存）；username 不在讀取器解析的欄位內，不比對
