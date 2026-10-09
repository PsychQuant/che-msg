## 1. 先做三項可行性驗證作為關卡

這三項只在 TDLib 資料夾的檔案複本上進行，複本放在 repo 外的暫存目錄，驗證完刪除，不 commit 任何真實帳號資料。

- [x] 1.1 驗證能從 `td.binlog` 的複本解出 `sqlite_key`（先做三項可行性驗證作為關卡的第一項；對應「本機讀取器直接解 binlog 與 SQLCipher」第 1 層）：以 `cucumber` 經 PBKDF2-SHA256 推導 AES-CTR 金鑰、解出 binlog 事件、找到 32 bytes 的 `sqlite_key`。驗證方式：一次性的 Swift 程式印出「找到 32 bytes 金鑰」（不印金鑰本身），並把結論記到 PsychQuant/che-msg#58
- [x] 1.2 驗證能用 1.1 的金鑰，以 `SQLITE_OPEN_READONLY` 和 TDLibFramework 內建的 `tdsqlite3_key` 打開 `db.sqlite` 複本，並讀出 `messages`、`dialogs`、`common`（`us<id>`）的筆數與 `data` 欄位是否有值，以及打開前後各檔案是否被修改。驗證方式：印出筆數與 `PRAGMA user_version`（不印內容），結論記到 #58 [after: 1.1]
- [x] 1.3 驗證能從 `common` 表的 `us<id>`、`gr<id>`、`ch<id>` 與 `messages.data` 解出聊天名稱、使用者名稱、訊息日期、寄件人與文字，並記下需要支援的內部欄位旗標數量。驗證方式：解析出的 `message_id` 與寄件人和資料表欄位逐筆一致、日期落在合理範圍、文字為合法 UTF-8，並統計解析成功率；結論與是否繼續記到 #58（TDLib 被另一個 session 持有時無法跑 TDLib 模式，與 `get_chat_history` 的逐筆比對移到 5.2）。任一項做不到就停止本 change，回到 `/spectra-discuss` [after: 1.2]

## 2. 測試資料

- [x] 2.1 產生可 commit、不含個人資料的測試資料（design：測試資料拆成三種來源，第 1 種）：用 TDLib 建立一個從未登入的資料夾（`useTestDc: true`、不送任何電話號碼），取得 TDLib 產生的 `td.binlog` 與加密的 `db.sqlite`，另存兩個變體——檔尾被截斷的 binlog、只剩加密事件（沒有 `sqlite_key`）的 binlog——以及記錄資料表清單與 `user_version` 的 `expected.json`。附上重新產生資料的腳本 `che-telegram-all-mcp/Tools/reader-fixtures/generate.sh`。驗證方式：產生器在寫出前掃描解密後的 binlog 與資料庫每一列，確認不含 API id 與 API hash；`expected.json` 的資料表清單含 `messages`、`dialogs`、`common`；重跑腳本得到相同的資料表清單與 `user_version` [after: 1.3]

## 3. 本機讀取器

- [x] 3.1 實作 binlog 解碼，滿足「Reader obtains the SQLite key from the binlog」：只採用長度與 CRC 正確的事件、略過檔尾不完整的事件、找不到 `sqlite_key` 時回 `key_not_found`。驗證方式：`TelegramAllLibTests` 新增測試，以 2.1 的測試資料取得金鑰、截斷檔仍取得金鑰、無 `sqlite_key` 的資料回 `key_not_found` [after: 2.1]
- [x] 3.2 實作唯讀開檔與版本檢查，滿足「Reader never writes TDLib files」與「Reader accepts only verified TDLib versions」（design：讀取器只接受驗證過的 TDLib 版本）：`SQLITE_OPEN_READONLY` 開檔、`user_version` 或 TDLib 版本不符時回 `unsupported_tdlib_version`。（design：讀取器允許 SQLite 更新共享索引檔）驗證方式：測試在讀取前後比對測試資料夾內除 `db.sqlite-shm` 外每個檔案的大小與修改時間不變、沒有新增或刪除檔案；竄改 `user_version` 的資料回 `unsupported_tdlib_version` [after: 3.1]
- [x] 3.3 解析聊天與使用者資料（依 `dialog_id` 範圍判斷類型，名稱取自 `us<id>`、`gr<id>`、`ch<id>`；列表與順序取自 `dialogs` 表的 `dialog_id`、`dialog_order`），供 `get_chats`、`search_chats` 使用；修正可行性驗證中 2 個群組與 2 個頻道名稱解不出的問題；滿足「Undecodable records are reported, not guessed」中聊天的部分：無法解析的聊天列為 `type: unknown`，無法得知的欄位（如 `unread_count`）省略。驗證方式：依 TDLib 1.8.60 原始碼欄位順序手工組出的 `us`／`gr`／`ch` 位元組（含有姓氏與沒有姓氏、新舊權限格式、含頭銜的成員身分）解出固定的名稱字面值；人為截斷的位元組回 `type: unknown` 並計入略過數 [after: 3.2]
- [x] 3.4 解析訊息資料（`messages.data`），供 `get_chat_history`、`search_messages` 使用，輸出 `id`、`chat_id`、`date`、`sender`、`is_outgoing`、`type`、`text`／`caption`，滿足「Undecodable records are reported, not guessed」中訊息的部分。驗證方式：手工組出的訊息位元組（純文字、含非 ASCII 文字、有編輯日期與 random_id 等選用欄位、轉寄資訊、頻道留言資訊）解出與 spec 範例相同的 JSON 欄位；含轉寄或頻道留言資訊等尚未支援欄位的訊息為 `type: unknown`、沒有 `text`、`sender` 來自 `sender_user_id` 欄位 [after: 3.3]
- [x] 3.5 提供讀取器的 5 個工具方法，滿足「Reader answers five tools with the TDLib-mode JSON fields」與「Reader never exposes the database key」：回傳與 `TDLibClient` 相同欄位的 JSON；`get_chat_history` 支援與 TDLib 模式相同的參數與日期篩選；`dump_chat_to_markdown` 產生 `telegram-history-export` 規定的 Markdown；`search_messages` 以逐筆解出的文字做不分大小寫的子字串比對（design：讀取器以逐筆解出的文字搜尋訊息）。驗證方式：測試把手工組出的聊天、使用者、訊息資料列插入 2.1 資料庫的暫存複本（用 binlog 裡的金鑰），逐一呼叫 5 個方法並比對固定的期望 JSON；另一個測試擷取所有回傳值、錯誤訊息與 stderr，確認不含金鑰的原始 bytes、hex 與 base64 形式 [after: 3.4]
- [x] 3.6 新增可選的真實資料比對測試（design：測試資料拆成三種來源，第 3 種）：只在設了環境變數 `CHE_TELEGRAM_READER_COMPARE_DIR`（指向一份 TDLib 資料夾的複本）時執行，讀取器讀出的每一則訊息，其 `message_id`、寄件人與資料表欄位一致、日期在合理範圍、文字為合法 UTF-8，並回報解析成功率；不寫出、不印出任何訊息內容。驗證方式：未設環境變數時測試顯示為略過；在使用者機器上以真實資料夾的複本執行一次，把成功率記到 #58 [after: 3.5]

## 4. TDLib 生命週期

- [x] 4.1 實作 server 端的鎖，滿足「Lock ownership honors the legacy wrapper lock」（design：鎖改由 server 以 flock 持有並承認舊版鎖目錄）：`flock` `~/.cache/che-telegram-all-mcp.tdlib.lock`、寫入 `che-telegram-all-mcp.tdlib.owner`、舊版鎖目錄的 `owner.pid` 活著時視為被持有。驗證方式：`TelegramAllLibTests` 測試四種情況——鎖空著、另一個 process 持有 flock、舊版 `owner.pid` 活著、舊版 `owner.pid` 已死 [after: 1.3]
- [x] 4.2 改為用到才開 TDLib、閒置釋放鎖，滿足「TDLib opens on first use, not at startup」與「TDLib closes after an idle period and releases the lock」：`Server.init` 不建立 `TDLibClient`；第一次需要 TDLib 的呼叫才取得鎖並開啟；閒置超過 `CHE_TELEGRAM_ALL_IDLE_TIMEOUT`（預設 600 秒，`0` 不關閉，非法值用預設並警告）後等 `authorizationStateClosed` 再釋放鎖；30 秒內沒關好就保留鎖並重試。驗證方式：單元測試以可注入的時鐘與假的 TDLib 介面驗證啟動不開、第一次呼叫開啟、閒置關閉、關閉逾時保留鎖、spec 的逾時設定範例表 [after: 4.1]
- [x] 4.3 實作工具分流與錯誤格式，滿足「Tool routing while TDLib is held by another process」與「Reader marks its results as coming from the local cache」（design：讀取器模式的回應附加來源標記）：依 spec 的分流表回應；`tdlib_in_use`、`local_reader_unsupported`、`local_reader_unavailable` 三種錯誤 JSON；讀取器結果附第二個內容項目（`source: local-cache`、持有者 PID、略過數、每個涵蓋對話在快取中最新訊息的日期，以及「Telegram 上可能有更新內容」的說明，依 spec 的 freshness 範例表）。驗證方式：`CheTelegramAllMCPTests` 對分流表每一列各測一個工具，並檢查三種錯誤 JSON 與來源說明的內容 [after: 4.2, 3.5]

## 5. wrapper、文件與發布

- [x] 5.1 修改 wrapper，滿足「Wrapper starts the server regardless of other sessions」（design：wrapper 拿不到鎖時不再拒絕）：移除鎖與 lock-refused 錯誤路徑、移除「舊 PID 還活著就殺掉」的分支與共用 PID 檔，只清理自己啟動的 binary；同時改寫 plugins/che-telegram-mcp/README.md 的 Multi-session limitation 段說明新行為與 `CHE_TELEGRAM_ALL_IDLE_TIMEOUT`。驗證方式：更新 `tests/che-telegram-mcp/test-wrapper-mcp-error.sh` 與 `test-wrapper-pid.sh`——第二個 wrapper 啟動時第一個 binary 仍存活、wrapper 結束只終止自己的 binary；`test-plugin-layout.sh` 與其 mutation 測試仍全過（README 的 docsUrl anchor 若改名，wrapper 的 `docsUrl` 一併更新）[after: 4.2]
- [ ] 5.2 手動驗證兩個 session 的情境（design 的驗收方式）：session A 呼叫 `get_chats` 後持有 TDLib；session B 呼叫 `get_chat_history` 得到 `source: local-cache`、呼叫 `send_message` 得到 `tdlib_in_use`；A 閒置超過時限後 B 改由 TDLib 回應；再對同一個對話比對讀取器與 TDLib 模式的 `get_chat_history` 輸出，快取涵蓋範圍內的訊息逐筆一致（`id`、`date`、`sender`、`type`、`text`）。驗證方式：把每一步的結果與比對的一致筆數（不含訊息內容）記到 #58 [after: 4.3, 5.1]
- [ ] 5.3 經使用者同意後發布：新版 binary release、wrapper 的 `DESIRED_VERSION`、plugin 版本與 CHANGELOG、`.claude-plugin/marketplace.json` 同步。驗證方式：`claude plugin validate .` 與兩個 plugin 的 validate 通過；`tests/che-telegram-mcp/*.sh` 全過；新版 wrapper 能從 release 下載到新 binary [after: 5.2]
