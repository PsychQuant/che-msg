## 1. 日檔格式

- [x] 1.1 依 design「每聊天每天一檔，錨點用 HTML 註解」與「時區以參數固定」，新增 `ArchiveDayFile`（`che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift`）：依 `utc_offset` 算出訊息的本地日期，輸出 frontmatter（`chat_id`、`date`、`utc_offset`）與訊息區塊（錨點、`**HH:mm 寄件人**：`、內文、空行），媒體內文為 `[<type>]` 加說明文字，滿足「Day file format」。驗證：`ArchiveDayFileTests` 的日檔範例逐字相符，並涵蓋有／無說明文字的媒體與 `+08:00`、`-05:00` 兩個 offset 的日期切分。
- [x] 1.2 依 design「合併後依 id 排序、原子覆寫」，`ArchiveDayFile` 解析既有日檔的區塊、只加入錨點不存在的訊息、依 id 遞增排序，並以同目錄暫存檔加 rename 寫入，滿足「Merge and idempotent rewrite」。驗證：`ArchiveDayFileTests` 涵蓋 30/50 加 40/50 得 30/40/50 且 50 只出現一次、無新訊息重跑位元相同、既有區塊原字保留。[after: 1.1]

## 2. 歸檔核心

- [x] 2.1 依 design「訊息來源抽象成一個介面」，新增 `ChatArchiver`（`che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift`）：由新到舊取頁，遇到 `after_message_id` 或 `since_date` 起點即停，依日期分組後交給 `ArchiveDayFile` 寫入，滿足「Only newer messages are fetched」。驗證：`ChatArchiverTests` 以假來源驗證只歸檔 id 大於書籤的訊息、`since_date` 起點、無界線時抓完整歷史。[after: 1.2]
- [x] 2.2 依 design「伺服器端寫檔、只回清單」與「書籤只在三個條件都成立時安全」，`ChatArchiver` 回傳清單（`files`、`new_messages`、`media_messages`、`newest_message_id`、`source`、`complete`、`bookmark_safe` 與條件欄位），滿足「Content-free manifest」與「Bookmark safety」。驗證：`ChatArchiverTests` 逐列通過書籤安全表四列，並斷言清單 JSON 不含任何訊息文字、說明文字或寄件人名稱。[after: 2.1]
- [x] 2.3 依 design「速率限制：短等一次、長則停」，`ChatArchiver` 對 `FLOOD_WAIT_<n>` 在 n ≤ 60 時等待後重試該頁一次，否則停止並回 `complete: false`、`stopped_reason: "flood_wait"`、`retry_after_seconds`，已寫日檔保留，滿足「Rate limits keep partial progress」。驗證：`ChatArchiverTests` 用可注入的等待函式驗證 `FLOOD_WAIT_30` 重試成功、`FLOOD_WAIT_420` 停止且先前頁面的日檔仍在。[after: 2.1]

## 3. MCP 工具與路由

- [x] 3.1 在 `Server.swift` 定義 MCP tool `archive_chat_to_markdown`，以 TDLib 單頁 `getChatHistory` 為來源、`resolveSenderNames` 解析寄件人、`TDLibSyncState` 判定是否同步，參數錯誤回 `isError: true` 且不寫檔，滿足「Archive tool parameters」。驗證：新增 `ArchiveToolTests`（CheTelegramAllMCPTests）涵蓋相對路徑 `output_dir` 被拒、`after_message_id` 優先於 `since_date`、`utc_offset` 格式錯誤被拒。[after: 2.2, 2.3]
- [x] 3.2 另一個 session 持有 TDLib 時，`archive_chat_to_markdown` 改以 `LocalCacheReading.getChatHistory` 為來源寫檔，回 `source: "local-cache"`、`bookmark_safe: false`，寄件人為 `User <id>`，滿足「Archive from the local cache」與修改後的「Tool routing while TDLib is held by another process」。驗證：`ToolRoutingTests` 把它列入快取回答的工具、斷言不建立 TDLib client，且 `testEveryOtherToolReportsTDLibInUse` 的 18 個工具不變。[after: 3.1]

## 4. archive-telegram skill

- [x] 4.1 依 design「skill 管設定與索引」，新增 `plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md`：讀 `.claude/.telegram/config.yaml`（缺檔或無 `chats` 時顯示範本並停止）、維護 `.claude/.telegram/state/archives/<slug>/index.json`（暫存檔加 rename）、逐一呼叫工具並帶入書籤、`since` 與記錄的 `utc_offset`，只在 `bookmark_safe` 時前進書籤，滿足「archive-telegram skill configuration and index」。驗證：`tests/che-telegram-mcp/test-plugin-layout.sh` 與 `claude plugin validate plugins/che-telegram-mcp` 在新 skill 存在時通過，並逐段審閱 SKILL.md 對照該需求的兩個 scenario。
- [x] 4.2 skill 結尾核對每份清單的檔案存在、frontmatter `chat_id` 相符、`newest_message_id` 的錨點存在，失敗時不前進該聊天書籤，並依聊天回報新訊息數、媒體數、書籤是否前進與原因、停止原因，不引用任何訊息內容，滿足「archive-telegram end-of-run check and report」。驗證：逐段審閱 SKILL.md 對照該需求的三個 scenario（含被速率限制的聊天與缺檔）。[after: 4.1]

## 5. 文件與驗收

- [x] 5.1 `che-telegram-all-mcp/README.md` 與 `plugins/che-telegram-mcp/README.md` 說明 `archive_chat_to_markdown`、`download_message_media`、`/archive-telegram` 的設定範例（含 `max_media_mb`）、媒體目錄與重試、書籤規則、超級群組遷移後要更新 `chat_id`，以及歸檔與媒體都是第三方內容、不得 commit 到公開 repo；兩份 CHANGELOG 的 `[Unreleased]` 記錄新功能並註明解決 #17。驗證：內容審閱，`grep` 兩份 README 都有 `archive_chat_to_markdown`、`download_message_media` 與隱私提醒。[after: 3.2, 4.2, 6.5, 6.6]
- [x] 5.2 全部測試與檢查通過：`swift test --skip E2ETests`（che-telegram-all-mcp）、`tests/che-telegram-mcp/*.sh`、`tests/che-archive-lines/*.sh`、`claude plugin validate .` 與 `claude plugin validate plugins/che-telegram-mcp`、`spectra analyze archive-telegram` 無 Critical。驗證：上述命令的輸出。[after: 5.1]
- [ ] 5.3 端對端驗收：以本機建置的 binary 對維護者自己的「Saved Messages」聊天（不含第三方內容）在暫存目錄跑兩次歸檔，確認第一次寫出日檔、媒體與清單，第二次 `new_messages` 與 `media_downloaded` 皆為 0 且檔案位元相同；另以 `download_message_media` 下載其中一則媒體並確認檔案存在；跑完刪除暫存目錄；結果只記錄檔數、訊息數與媒體數。驗證：兩次的清單 JSON 與 `shasum` 比對，記錄在 #69。[after: 5.2]
  - BLOCKED (2026-10-11): the maintainer's Saved Messages chat is empty (`get_chat` has no `last_message`; three `get_chat_history` calls return 0), so the data-dependent checks (day files, media, a byte-identical second run, `download_message_media` on a real file) cannot run without content the maintainer adds or approves sending. Verified end to end with the local release binary on that chat: TDLib path opens and loads a chat TDLib had not seen (`Chat not found` before the fix), the archive completes with `bookmark_safe: true` and a content-free manifest, `download_message_media` reports TDLib's error readably for a missing message (`{"code":404,…}`) and refuses a relative `output_dir`, nothing is written, temporary directories removed. Two bugs found and fixed on the way: TDLibKit errors (incl. `FLOOD_WAIT_<n>`) reached the archiver unmapped, and unseen chats failed with `Chat not found`.

## 6. 媒體下載（2026-10-11 實作中追加）

- [x] 6.1 補償 1.1：依 design「媒體連結事先確定」（取代「每聊天每天一檔，錨點用 HTML 註解」中的媒體內文寫法），`ArchiveDayFile.body` 對帶檔案的類型（`photo`、`video`、`document`、`audio`、`voice_note`、`video_note`、`animation`、`sticker`）輸出 `[<type>](media/<message_id>/)` 加說明文字，其他非文字類型維持 `[<type>]`，滿足修改後的「Day file format」。驗證：`ArchiveDayFileTests` 的日檔範例改為 `[photo](media/5243904/) menu` 後逐字相符，涵蓋 `[voice_note](media/6000/)` 與 `[location]`；`ChatArchiverTests` 的說明文字斷言隨之更新。[after: 2.1]
- [x] 6.2 `TDLibClient.messageToDict` 對帶檔案的訊息輸出 `file`（`id`、`size`、有原檔名時 `name`），照片取最大尺寸，供下載使用。驗證：以 TDLibKit 模型的 JSON 解碼建構照片與檔案訊息的單元測試，斷言 `file.id`、`file.size`（照片為最大尺寸）與檔名。
- [x] 6.3 依 design「歸檔時預設下載所有媒體」與「媒體下載不影響書籤，失敗以 id 重試」，新增 `ArchiveMedia`（下載器介面與檔名規則）並接入 `ChatArchiver`：TDLib 路徑下載、已有檔案不重下、`max_media_bytes` 上限、失敗列入 `media_failed_ids`、`retry_media_message_ids` 按 id 補下載、本機快取只計 `media_pending_local_cache`，清單加入媒體欄位，滿足「Media download into the archive」「Media retry by message id」與修改後的「Content-free manifest」。驗證：`ArchiveMediaTests` 以假下載器涵蓋上述各情境，並斷言下載失敗不改變 `bookmark_safe`、清單不含檔名與說明文字。[after: 2.2, 2.3, 6.1]
- [x] 6.4 `Server.swift` 的 `archive_chat_to_markdown` 接受 `max_media_bytes` 與 `retry_media_message_ids`，以 TDLibKit `downloadFile(synchronous: true)` 與 `getMessage` 實作下載器與按 id 取訊息。驗證：`ArchiveToolTests` 涵蓋兩個新參數的型別驗證（負數上限、非整數 id 被拒）。[after: 3.1, 6.2, 6.3]
- [x] 6.5 依 design「單則下載工具共用下載核心」，新增 MCP tool `download_message_media`（`chat_id`、`message_id`、`output_dir`），回傳 `message_id`、`type`、`path`、`size`；文字訊息回 `isError: true`；TDLib 被別的 session 持有時回 `tdlib_in_use`，滿足「Single message media download tool」與修改後的「Tool routing while TDLib is held by another process」。驗證：`ArchiveToolTests` 涵蓋文字訊息的錯誤與相對路徑被拒；`ToolRoutingTests` 斷言它在 TDLib 被持有時回 `tdlib_in_use`（回 `tdlib_in_use` 的工具由 18 個變成 19 個）。[after: 6.4]
- [x] 6.6 skill `archive-telegram` 讀 `max_media_mb` 並換算成 `max_media_bytes`，把每個聊天的 `media_failed_ids` 存成索引的 `pending_media`、下次以 `retry_media_message_ids` 傳回，回報下載、略過（含大小）與失敗的媒體數。驗證：逐段審閱 SKILL.md 對照「archive-telegram skill configuration and index」與「archive-telegram end-of-run check and report」修改後的內容。[after: 4.2]

