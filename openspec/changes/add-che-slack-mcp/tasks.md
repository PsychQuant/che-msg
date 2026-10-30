## 1. 唯讀實測

- [x] 1.1 在使用者的 Mac 上做唯讀實測，確認三件事，結論寫進 design.md 的 Open Questions：(a)「桌面版匯入：先實測再實作」——App Store 版 Slack 的 `Local Storage/leveldb` 是否經 Snappy 壓縮、`localConfig_v2` 是否在其中、`Cookies` 的 `d` 能否以 `Slack Safe Storage` 解開、新版 Chromium 的明文前綴、讀沙盒資料夾與 Keychain 時 macOS 跳出哪些授權；(b)「寫入 Keychain 不經過 argv」——對暫存 keychain 檔案以 `security -i` 從 stdin 寫入一個測試值，再用 `ps` 確認值不在 argv、用 `find-generic-password -g` 讀得回來；(c) Safari 的 console 有沒有 `copy()`。驗證：design.md 的 Open Questions 每一項都有結論；實測輸出只記長度、前綴與成功與否，不含任何 token 或 cookie 的值；若 (a) 做不到，開一張後續 issue 並以 `/spectra-ingest` 移除 Desktop import requirement 與 task 3.4。

## 2. Slack Web API client

- [x] 2.1 建立 `che-slack-mcp/` Swift package，比照 `che-telegram-bot-mcp/Package.swift`（macOS 13、swift-sdk from 0.12.0、swift-argument-parser from 1.5.0）拆成 `SlackWebLib`、`CheSlackMCPCore`、`CheSlackMCP`、`slack-all` 四個 target（task 3.3 再加上 `SlackAllCore`，共五個），`SlackWebLib` 只依賴 Foundation（「SlackWebLib 只依賴 Foundation」），傳輸層是可注入的 protocol；實作「以瀏覽器 session token 認證」的 Session token request authentication：POST 到 `https://slack.com/api/<method>`，token 在 form、cookie 在 `Cookie: d=` 標頭。驗證：`swift build -c release` 成功；以假傳輸層的測試斷言 body、標頭與 URL 不含憑證。
- [x] 2.2 [after: 2.1] 實作「Slack 錯誤分成五類」的 Slack error classification、Rate limit retry（依 `Retry-After`，最多 3 次）、「預設請求間隔與並行上限」的 Request pacing（350 ms、3，`SLACK_MCP_MIN_INTERVAL_MS` 與 `SLACK_MCP_MAX_CONCURRENCY` 可覆寫，超出範圍時警告並用預設值），以及 No credential in output（描述字串以 `<redacted>` 取代值）。驗證：以假傳輸層與可注入的時鐘測試 spec 的分類表、重試等待時間、兩個請求的間隔、並行上限與超出範圍的覆寫值；`String(describing:)` 的測試斷言不含憑證。

## 3. 憑證與匯入

- [x] 3.1 [after: 2.1] 實作「每個 workspace 一組 Keychain 項目加索引」：Keychain credential layout（account `che-slack-mcp`，`SLACK_WORKSPACES`、`SLACK_TOKEN_<team_id>`、`SLACK_COOKIE_<team_id>`）與 Credential lookup is bounded（比照 `che-telegram-all-mcp` 的 `SecurityCLICredentialSource`：`security find-generic-password -g`、stdin 接 null device、10 秒逾時、不快取、缺項時只報 service 名稱）。驗證：以暫存 keychain 檔案的測試涵蓋索引讀取、缺 token 時回報 `SLACK_TOKEN_T01`、逾時。
- [x] 3.2 [after: 3.1, 1.1] 實作 Keychain write keeps values off argv：以 `security -i` 從 stdin 寫入，寫入前檢查字元集，不合法時拒絕並點名 service。驗證：暫存 keychain 檔案的寫入後讀回測試；含 `"` 的值被拒且 keychain 未變；一個記錄子程序 argv 的測試斷言值不在 argv 中。
- [x] 3.3 [after: 2.2, 3.2, 1.1] 實作「剪貼簿匯入：console 一行複製全部 workspace」的 Clipboard import（兩次複製與 Enter、逐一 `auth.test`、只存驗證成功的、讀完清空剪貼簿、第一次讀到的不是 workspace 陣列時立即停止）、Workspace removal（`slack-all auth remove <workspace>`，接受 team id 或 domain）與 `slack-all auth status`；console 指令依 1.1 對 Safari 的結論決定用 `copy()` 或 `navigator.clipboard.writeText`。驗證：以假剪貼簿與假 client 的測試涵蓋 spec 的「兩個 workspace 一個驗證失敗」與「以 domain 移除」情境，並斷言 CLI 輸出不含憑證。
- [x] 3.4 [after: 1.1, 3.3] 實作 Desktop import（`slack-all auth import --from-desktop`）：依序尋找兩個 Slack 資料夾、以暫存副本讀 `Cookies` 與 `Local Storage/leveldb`、以 `Slack Safe Storage` 解密 `d`、讀 Keychain 前提示按「允許」不按「永遠允許」、結束時刪除暫存副本、失敗時點名失敗步驟並建議 `slack-all auth import`。驗證：以自行產生的合成 fixture（用測試金鑰加密的 cookie 資料庫與 LevelDB 檔案，不含任何真實 Slack 資料）測試解密與解析；「找不到資料夾」情境的測試；使用者在自己的 Mac 上手動跑一次，結果記在 #99。

## 4. MCP 工具

- [x] 4.1 [after: 2.2, 3.1] 實作「一個 process 管多個 workspace」的 Workspace selection（team id 或 domain、不分大小寫完全相符、多個時省略即報錯並列出、未匯入時建議 `slack-all auth import`）、Workspace and session tools（`list_workspaces`、`auth_status`）與 Tool error results（client 錯誤一律回 `isError: true` 的工具結果，`sessionInvalid` 附兩個重新匯入指令，`enterpriseRestricted` 建議官方 MCP）。驗證：MCP Core 的測試涵蓋 spec 的選擇結果表、`auth_status` 逐一回報、session 失效訊息含兩個指令。
- [x] 4.2 [after: 4.1] 實作 Conversation read tools（`list_conversations`、`get_conversation_history`、`get_thread_replies`、`get_user`，參數超出範圍時不呼叫 Slack）與 Message search（`search_messages`，query 原樣傳給 `search.messages`）。驗證：假 client 的測試涵蓋 `limit` 500 被拒、空白 query 被拒、各工具回傳的欄位。
- [x] 4.3 [after: 4.2] 實作 Send message（`send_message`，`text` 1 到 40000 字元，`thread_ts` 時回覆在 thread 中，回傳新訊息的 `ts`）。驗證：假 client 的測試斷言 `chat.postMessage` 收到 `channel`、`text`、`thread_ts`，以及空白 `text` 被拒。

## 5. 歸檔

- [x] 5.1 [after: 4.1] 依「歸檔格式對齊 telegram-chat-archive」實作 `archive_conversation_to_markdown` 的 Slack archive tool parameters、Slack day file format（`<output_dir>/<team_id>/<conversation_id>/<YYYY-MM-DD>.md`、frontmatter、`<!-- msg:<ts> -->`、回覆標頭 `↳ thread:<parent_ts>`、行首跳脫、0700／0600）與 Slack markup conversion，並依「第一版不下載檔案」把附件寫成 `[file: <name>](<permalink>)`。驗證：測試重現 spec 的 day file 範例（`1793498700.000100` 與 `1793498820.000200` 寫進 `T01/C01/2026-11-01.md`）、轉換表的每一列、相對路徑被拒、檔案權限。
- [x] 5.2 [after: 5.1] 實作 Incremental archive and manifest（`manifest.json` 不含內容、只抓比書籤新的主訊息、同一則訊息就地取代、無新訊息時重跑檔案逐 byte 相同）與「thread 回覆以回顧窗口補抓」的 Thread replies and lookback（`thread_lookback_days` 預設 30）。驗證：測試涵蓋「第二次執行沒有新訊息」與「窗口外 45 天的 thread 不抓回覆」兩個情境，並檢查 manifest 不含訊息文字、寄件者與檔名。
- [x] 5.3 [after: 5.2] 實作 Archive concurrency and partial progress：同一 workspace、同一 conversation、同一輸出目錄不得同時歸檔；被限流放棄時保留已寫入的檔案、書籤維持原值（不推進）、回傳非錯誤結果並說明重跑會重抓未完成的範圍。驗證：測試涵蓋並行呼叫被拒且未寫檔，以及 spec 的「限流中途停止」情境（書籤仍為 `1793451600.000100`）。

## 6. Plugin、文件與驗收

- [x] 6.1 [after: 4.3, 5.3, 3.4] 依「獨立的 che-slack-mcp plugin」新增 `plugins/che-slack-mcp/`：wrapper 以 `DESIRED_VERSION` pin 本 repo 下一個 release 並下載 binary、不 export 任何憑證；README 寫安裝指令（`marketplace add …/che-msg` 與 `install che-slack-mcp@che-msg`）、匯入步驟、Enterprise Grid 與條款風險，免確認表依「send_message 不列入免確認清單」排除 `send_message` 與 `archive_conversation_to_markdown` 並寫明 auto 模式的行為與 ask 規則；在 `.claude-plugin/marketplace.json` 加條目；新增 `tests/che-slack-mcp/` 的結構與 wrapper 測試；更新根 `README.md` 的伺服器表與待辦清單、`CLAUDE.md` 的結構表與開發指令；建立 `openspec/LANGUAGE.md` 記下 workspace、conversation、session token。驗證：`bash tests/che-slack-mcp/*.sh`、`claude plugin validate plugins/che-slack-mcp`、`claude plugin validate .` 全部通過，既有的 `tests/che-telegram-mcp/*.sh` 與 `tests/che-archive-lines/*.sh` 仍通過，wrapper 測試斷言環境中沒有 Slack 憑證。
- [x] 6.2 [after: 6.1] 端對端驗收：以本機 build 的 binary，在使用者自己的 workspace 依序執行桌面版匯入（`--from-desktop`；使用者只用 Slack 桌面版、瀏覽器沒有登入 Slack，剪貼簿匯入無法真機驗證，其流程由 `SlackAllCoreTests` 的單元測試涵蓋，說明與錯誤訊息的改善追蹤於 #103）、`list_workspaces`、`get_conversation_history`、`search_messages`、對自己的 DM 執行 `send_message` 一次、`archive_conversation_to_markdown` 兩次（第二次檔案不變）。驗證：`cd che-slack-mcp && swift test --skip E2ETests` 全部通過；手動結果（不含訊息內容與憑證）以 comment 記在 #99。

## 7. Review 修正

- [ ] 7.1 [after: 5.3] 依 Incremental archive and manifest 與 Archive concurrency and partial progress 的修訂，在 `manifest.json` 記下未走完那一段的起點與已寫到的最舊 `ts`；下一次呼叫先以該 `ts` 為 `latest` 接著往舊的方向抓，走到下界才把書籤推進到那一段的頂端；被頁數上限或限流中斷時都記錄接續點。驗證：spec 情境「Unfinished walk continues on the next call」（12000 則、第一次停在 50 頁、第二次只抓更舊的並補齊 2000 則後才設書籤）與修訂後的「限流中途停止」（manifest 記下 `1793498700.000100`）的測試，以及既有歸檔測試全數通過。
- [ ] 7.2 [after: 7.1] 依 Thread replies and lookback 的修訂，`conversations.replies` 以 manifest 記錄的回覆 `ts` 為 `oldest`，長 thread 分次補齊。驗證：spec 情境「Long thread continues on the next call」（1300 則回覆，第一次 1000 則、第二次只抓之後的 300 則）的測試。
- [ ] 7.3 合併桌面版匯入讀 `Slack Safe Storage` 時複製的子程序逾時處理（`SlackAllCore` 的 `BoundedChild`）與 `SlackWebLib` 的 `runBounded`／`OutputCollector`，改用 `package` 存取層級共用一份，`formatSeconds` 一併共用；行為不變。驗證：`swift test` 全數通過，`SafeStorageReaderTests` 的期望值不變。

