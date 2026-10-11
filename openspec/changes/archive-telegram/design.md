## Context

PsychQuant/che-msg#69：維護者想把指定的 Telegram 對話增量歸檔成本機 Markdown，比照 che-apple-mail-mcp 的 `/archive-mail`。維護者 2026-10-11 決定：只歸檔設定裡列出的 `chat_id`、寫到各專案資料夾、群組也可、第一次預設抓完整歷史、做成 skill。

現況（2026-10-11 讀程式碼）：

- `dump_chat_to_markdown`（`MarkdownExporter.dumpChatToMarkdown`）整檔重寫，訊息沒有 id，媒體說明文字遺失（#70）。
- `TDLibClient.getChatHistory` 由新到舊分頁；只給 `limit` 與 `fromMessageId`、不給 `maxMessages` 與日期時走單頁路徑。
- TDLib 錯誤由 `mapTDLibError` 轉成 `TDLibClient.Error.tdlibError(code:message:)`；速率限制：伺服器回 code 420 `FLOOD_WAIT_<n>`，但 TDLib 會自己等，超過它的上限才對 client 回 `429 "Too Many Requests: retry after <n>"`（見「驗證第一輪的修正」）。
- 另一個 session 持有 TDLib 時，`Server.handleToolCall` 改走本機快取：`LocalCacheReading.getChatHistory` 回傳 `LocalTDLibReader.Result`，其 `json` 是與 TDLib 模式同欄位的訊息陣列。
- `TDLibSyncState` 由 server 持有，`snapshot()` 回報目前的 `connection_state`。
- TDLibKit 提供 `downloadFile(fileId:limit:offset:priority:synchronous:) async throws -> File`，`synchronous: true` 時下載結束才回應，`File.local.path` 是 TDLib 快取裡的路徑。`TDLibClient.messageToDict` 目前只輸出媒體的類型、說明文字與檔名，沒有檔案 id。
- 實作中維護者追加（2026-10-11）：歸檔時下載所有媒體；同一個下載核心另開單則下載工具，解決 #17。

## Goals / Non-Goals

**Goals:**

- 一個伺服器端工具把聊天寫成「每聊天每天一檔」並帶 message id 錨點，重跑冪等、可中斷續跑，回傳不含訊息內容的清單。
- 一個 skill 管設定、書籤索引與結尾核對，書籤只在安全時前進。
- TDLib 被別的 session 持有時仍能歸檔，但不前進書籤。
- 歸檔時下載媒體，並提供單則訊息的媒體下載工具。

**Non-Goals:**

- 追蹤編輯與刪除、讀取端工具。
- 由本機快取下載媒體（快取沒有檔案內容）。
- 改動 `dump_chat_to_markdown` 的輸出（#70 另案）。
- 自動 commit 歸檔內容。

## Decisions

### 伺服器端寫檔、只回清單

大群組的完整歷史若經模型轉寫，會用盡 context 並把第三方訊息帶進對話紀錄。工具在伺服器端寫檔，回傳只含檔名、計數、最新 id、來源與兩個旗標。替代方案「skill 用 `get_chat_history` 自己寫檔」因此排除；它只適合小量，而維護者要的是預設完整歷史。

### 每聊天每天一檔，錨點用 HTML 註解

`<output_dir>/<chat_id>/YYYY-MM-DD.md`。以 `chat_id` 命名資料夾：標題會改、也不該出現在路徑裡。每則訊息前一行 `<!-- msg:<id> -->`：渲染時看不到、機器可解析。替代方案「每則一檔」（archive-mail 的做法）在聊天訊息量下會產生上千個小檔；「每聊天一檔」重寫成本隨歷史線性成長。

### 合併後依 id 排序、原子覆寫

分頁由新到舊，較舊的訊息會晚寫入；單純 append 無法維持順序，中斷後重跑也會重複。寫一個日檔時：解析既有區塊 → 只加入錨點不存在的訊息 → 依 message id 遞增排序 → 寫同目錄暫存檔再 rename。既有區塊原字不動，所以重跑在無新訊息時位元相同。日檔小，整檔重寫的成本可接受。

### 時區以參數固定

日期切分依 `utc_offset`；未給時用伺服器當下的 offset。skill 把第一次用的 offset 記進索引、之後一律傳同一個值，避免機器時區改變後同一則訊息落到兩個日檔。

### 書籤只在三個條件都成立時安全

`bookmark_safe` = 分頁走到界線（`after_message_id`、`since_date` 起點、或對話開頭）且來源是 TDLib 且結束時 `connectionStateReady`。這三個條件分別防止：中斷造成的缺口、快取缺訊息、#63 那種停在舊資料的同步失效。書籤由 skill 寫，工具只回報。

### 速率限制：短等一次、長則停

TDLib 回報的速率限制（`429 "Too Many Requests: retry after <n>"`，或原樣傳來的 `FLOOD_WAIT_<n>`），n ≤ 60 時等 n 秒重試該頁一次；n > 60 或重試再失敗就停止並回 `complete: false`、`retry_after_seconds`。已寫的日檔保留，重跑時錨點會略過已寫的訊息。60 秒是估計值：讓工具呼叫不至於超過 MCP 用戶端的等待時間，待長歷史實際執行時確認。

### 訊息來源抽象成一個介面

`ChatArchiver` 接一個「取一頁訊息」的來源：TDLib 實作呼叫 `getChatHistory` 單頁路徑，快取實作呼叫 `LocalCacheReading.getChatHistory`。寄件人名稱由一個可選的解析函式提供：TDLib 路徑沿用 `resolveSenderNames`，快取路徑不解析（`User <id>`）。這讓兩條路徑共用合併、排序、清單與書籤邏輯，測試也能用假的來源。

### skill 管設定與索引

`.claude/.telegram/config.yaml` 與 `.claude/.telegram/state/archives/<slug>/index.json`，比照 archive-mail 的 `.claude/.mail/`。索引記每個聊天的 `last_message_id`、`utc_offset`、上次執行摘要；以暫存檔加 rename 寫入。`<slug>` 由 `output_dir` 把 `/` 換成 `-` 並去掉首尾的 `-` 與 `.` 得到（同 archive-mail）。

### 歸檔時預設下載所有媒體

維護者要「所有東西都可以下載」。TDLib 路徑上，每則帶檔案的訊息（照片、影片、檔案、音訊、語音、圓形影片、動圖、貼圖）都以 `downloadFile(synchronous: true)` 下載，再複製到 `<output_dir>/<chat_id>/media/<message_id>/`。複製而不是搬移，是為了不動 TDLib 自己的快取。目錄已有檔案就略過，所以重跑不重下。`max_media_bytes` 是可選上限，預設不限；超過的列在清單的 `media_skipped`。替代方案「只記佔位、另外手動下載」不符合要求。

### 媒體連結事先確定

日檔裡媒體那一行固定寫 `[<type>](media/<message_id>/)`，連到該則訊息的媒體目錄，不連到檔案本身。這個連結不需要知道檔名，所以本機快取先寫的日檔、或下載失敗的訊息，日後補下載時不必改寫那一行（日檔既有區塊不改的規則因此不必破例）。代價是渲染時圖片不會直接內嵌；點連結才看到。

**Supersedes**: archive-telegram / 每聊天每天一檔，錨點用 HTML 註解（只取代其中媒體內文的寫法：原本是 `[<type>] 說明文字`，改為帶連結）

### 媒體下載不影響書籤，失敗以 id 重試

書籤只管訊息文字是否完整；若讓媒體失敗擋住書籤，一個永久無法下載的檔案（過期、被刪）會讓之後每次都從舊書籤重抓。所以下載失敗只記進 `media_failed_ids`，skill 把它們存成該聊天的 `pending_media`，下次以 `retry_media_message_ids` 傳回；工具按 id 取回訊息（`getMessage`）再下載。由本機快取歸檔時不下載，但那次本來就不前進書籤，下次用 TDLib 時會重抓那些訊息並補下載。

### 單則下載工具共用下載核心

`download_message_media(chat_id, message_id, output_dir)` 用同一個下載規則把單則訊息的媒體存到 `<output_dir>/<chat_id>/media/<message_id>/`，回傳路徑與大小。存放位置與歸檔相同，所以對歸檔目錄用它補單一檔案也不會不一致。這解決 #17：以前只能看到 `[photo]`，拿不到照片本身。TDLib 被別的 session 持有時回 `tdlib_in_use`，因為快取沒有檔案內容。

### 驗證第一輪的修正（2026-10-11）

六個審查來源（四個面向、Devil's Advocate、Codex）與 TDLib 原始碼核對後的決定：

- **速率限制的真實形狀**：TDLib 自己等掉伺服器的 `FLOOD_WAIT`，超過它的上限才回 `429 "Too Many Requests: retry after N"`（td `NetQueryDelayer.cpp`）。原本只認 `FLOOD_WAIT_<n>`，在正式環境不會命中；改為兩種都認，測試用真實形狀。
- **游標**：TDLib `getChatHistory` 在 offset 0 時不含 `from_message_id`（td `OrderedMessages::get_history`），審查中「包含游標」的推測不成立；兩個來源仍一律過濾 `id >= cursor`，讓介面約定不依賴底層細節。
- **快取寫入的區塊不會升級**：skill 在 `tdlib_in_use` 時預設停止，使用者明確要求才從快取歸檔；工具描述、README 與 spec 寫明這點。比較完整的解法（可被覆寫的暫定區塊）牽動錨點格式，另開 #72。
- **日檔安全**：開頭像錨點或像區塊標頭（`**HH:mm …**：`）的內文行加反斜線；用不同 `utc_offset` 合併既有日檔一律拒絕；目錄 0700、檔案 0600；每個聊天目錄在一次呼叫期間持有 `.archive.lock`，同時第二個呼叫直接失敗。
- **清單語意**：`files` 只列這次真的加入訊息的日檔；`media_messages` 只算帶檔案的類型；`media_failed_ids` 去重，同一次呼叫裡重試成功的 id 不列入；`<chat_id>/` 在呼叫開始時就建立；同一頁先寫文字再下載媒體。
- **索引沒有檔案清單**：issue 與 Diagnosis 原本設想索引記下所有檔案並核對；實作改由每次的清單逐檔核對（存在、`chat_id`、最新錨點），效果相同而索引較小。
- **skill 強化**：slug 不經 shell 計算；索引記錄的 `output_dir` 與設定不同時停止（避免 `a/b` 與 `a-b` 共用書籤）；`output_dir` 在 git repo 裡卻沒被 ignore 時停止；呼叫前先記下 `utc_offset`；核對 `chat_id` 只用 Grep 取單行。
- 其餘低風險項目另開 #73（快取讀取器的游標與 TDLib 不一致，既有程式）、#75（`pending_media` 老化、媒體的 quarantine 標記、無日期訊息計數）。

### 驗證第二輪的修正（2026-10-11）

- **`newest_message_file`**：第一輪把 `files` 改成只列加入訊息的日檔後，重跑（最新訊息早已寫入）時 skill 在 `files` 裡找不到最新錨點，書籤永遠不前進，長歷史的第二輪也一樣。清單新增 `newest_message_file`（最新訊息所在日檔，不論這次是否寫入；與 `newest_message_id` 同為 null 或同不為 null），skill 對 `files` 加上它做核對。`files` 維持「這次寫入的」語意。
- **offset 在讀訊息前整目錄檢查**：原本逐日檔在寫入途中檢查，字典順序可能先用新 offset 寫出新日檔才拒絕，留下混用兩種 offset、兩邊都被拒的目錄。改為呼叫開始（取得鎖後、讀任何訊息前）掃描 `<chat_id>/*.md` 的 frontmatter；以秒數比較（`-00:00` 等於 `+00:00`）；讀不到 offset 的日檔一律拒絕；錯誤訊息只回顯解析成功的 offset。skill 收到不符時改用記錄的 offset 重試一次。
- **skill 的 git 檢查與 shell**：對目錄底下的檔案路徑（`<dir>/0/2000-01-01.md`、`<dir>/0/media/0/file`）做 `check-ignore`，在 `output_dir` 最近既有上層目錄所屬的 repo 裡判定；非 0 一律停止。所有 shell 路徑一律單引號包住、`'` 寫成 `'\''`，不再有「跳過檢查」的分支。核對只用列檔名的 Grep：`\A---\nchat_id: <id>\n` 與整行 `^<!-- msg:<id> -->$`。
- 小項：鎖檔以 `O_NOFOLLOW | O_CLOEXEC` 開啟，只有 `EWOULDBLOCK` 回報「另一個歸檔進行中」；`retry after` 後沒有數字時改試 `FLOOD_WAIT_`，數字過大視為 14 天（TDLib 的上限）；檔名去掉 U+2028/U+2029 等換行字元、後備檔名也限 255 bytes；內文行只要以 `**` 加時間開頭就加反斜線。
- 記錄、不改：兩個 `/archive-telegram` 同時跑同一個 workspace 時索引會互相覆蓋（skill 文件提醒不要這樣做）；`media/<id>` 本身是 symlink、修正前建立的 0755/0644 項目（只存在於開發分支）；錯打的 `chat_id` 會留下空的 `<chat_id>/`。

## Implementation Contract

**Behavior**

- 呼叫 `archive_chat_to_markdown` 後，`<output_dir>/<chat_id>/` 下的日檔包含所有比書籤新的訊息，每則一個錨點，依 id 排序；回傳一個 JSON 清單，不含訊息文字、說明文字或寄件人名稱。
- `/archive-telegram` 不帶參數時讀設定、逐一歸檔、核對、回報；書籤只在 `bookmark_safe` 且核對通過時前進。

**Interface / data shape**

- 工具參數：`chat_id`（必填整數）、`output_dir`（必填絕對路徑）、`after_message_id`（選填整數）、`since_date`（選填 `YYYY-MM-DD`）、`utc_offset`（選填 `±HH:MM`）、`max_media_bytes`（選填整數）、`retry_media_message_ids`（選填整數陣列）。
- `download_message_media`：`chat_id`、`message_id`、`output_dir`（皆必填）；回傳 `{"message_id","type","path","size"}`。
- 訊息 JSON（TDLib 路徑）的媒體增加 `file`：`{"id","size","name"?}`，照片取最大尺寸。
- 媒體位置：`<output_dir>/<chat_id>/media/<message_id>/<檔名>`；檔名：照片 `photo.jpg`、有原檔名用原檔名（去掉路徑分隔與開頭的點）、其他為類型加 TDLib 檔案的副檔名。
- 清單：`{"files":[…],"new_messages":N,"media_messages":M,"newest_message_id":ID|null,"newest_message_file":"<chat_id>/<day>.md"|null,"source":"tdlib"|"local-cache","complete":bool,"bookmark_safe":bool}`，加上條件欄位 `stopped_reason`、`retry_after_seconds`、`bookmark_unsafe_reason`（`incomplete`／`local-cache`／`not-synced`），以及媒體欄位 `media_downloaded`、`media_skipped`（`[{message_id,size}]`）、`media_failed_ids`、`media_pending_local_cache`、`media_retried_ids`。
- 日檔：frontmatter `chat_id`、`date`、`utc_offset`；訊息區塊 `<!-- msg:<id> -->`、`**HH:mm 寄件人**：`、內文、空行；帶檔案的媒體內文為 `[<type>](media/<message_id>/)` 加空格加說明文字，其他非文字類型為 `[<type>]` 加說明文字。
- 設定 `.claude/.telegram/config.yaml`：`chats: [{chat_id, label?}]`、`output_dir`、`since?`、`max_media_mb?`。索引 `.claude/.telegram/state/archives/<slug>/index.json`：`{"version":1,"chats":{"<chat_id>":{"last_message_id":…, "utc_offset":"+08:00","pending_media":[…],"last_run":{…}}}}`。

**Failure modes**

- 參數錯誤 → `isError: true`、訊息點名參數、不寫檔。
- TDLib 錯誤（非速率限制）→ `isError: true`，已寫的日檔保留。
- 速率限制長等待 → 非錯誤，清單 `complete: false`。
- 快取來源 → 非錯誤，`bookmark_safe: false`。
- 設定檔不存在 → skill 顯示範本、不呼叫工具。
- 單一媒體下載失敗 → 非錯誤，id 進 `media_failed_ids`。`download_message_media` 對無檔案的訊息回 `isError: true`。

**Acceptance criteria**

- `ArchiveDayFileTests`：日檔範例逐字相符；合併 30/50 + 40/50 得 30/40/50；無新訊息重跑位元相同；媒體有無說明文字兩種。
- `ChatArchiverTests`（假來源）：只抓比 `after_message_id` 新的訊息；`since_date` 起點；書籤安全表四列；速率限制（真實形狀 `retry after 30` 重試成功、`retry after 420` 停止且保留已寫檔，`FLOOD_WAIT_n` 仍可辨識）；清單不含文字。
- `ToolRoutingTests`：TDLib 被持有時 `archive_chat_to_markdown` 走快取、`source: local-cache`、不建立 TDLib client；把它列入快取回答的工具後，回報 `tdlib_in_use` 的其餘工具在 3.2 時仍是 18 個；6.5 加入 `download_message_media` 後是 19 個（`testEveryOtherToolReportsTDLibInUse`）。
- `ArchiveMediaTests`（假下載器）：照片存成 `photo.jpg`、已有檔案不重下、超過上限列入 `media_skipped`、下載失敗列入 `media_failed_ids` 且不影響 `bookmark_safe`、`retry_media_message_ids` 補下載、本機快取來源只計 `media_pending_local_cache`、檔名去掉路徑分隔與開頭的點。
- 訊息 JSON 的 `file` 欄位：以 TDLibKit 模型的 JSON 解碼建構照片、檔案訊息，斷言 `file.id` 與大小（照片取最大尺寸）。
- `download_message_media`：文字訊息回錯誤；TDLib 被持有時回 `tdlib_in_use`。
- `tests/che-telegram-mcp/test-plugin-layout.sh` 涵蓋新 skill 的 frontmatter 與必要段落。
- 測試只用合成訊息，不含任何真實聯絡人或訊息內容。

**Scope**

- In scope：`TelegramAllLib` 的歸檔核心、日檔格式、媒體下載；訊息 JSON 的 `file` 欄位；`Server.swift` 的兩個工具與路由；skill、README 與 CHANGELOG、測試。
- Out of scope：由本機快取下載媒體、`dump_chat_to_markdown` 的輸出、發布（在 PR 合併時依既有流程進行）。

## Risks / Trade-offs

- [超級群組遷移會換 `chat_id`] → 舊設定會歸檔到一個不再更新的聊天；README 說明遷移後要更新設定。
- [歸檔後的編輯與刪除不反映] → 刻意的 append-only；Non-Goal 已載明。
- [整檔重寫的成本] → 日檔只含一天的訊息，量小。
- [快取執行可能缺訊息] → `bookmark_safe: false`，下次用 TDLib 時從舊書籤重抓，錨點去重。但快取寫入的區塊沒有寄件人名稱與說明文字，而合併規則不改寫既有區塊，所以它們會一直維持那樣；skill 因此在 TDLib 被持有時預設停止（見「驗證第一輪的修正」），完整解法另開 #72。
- [長歷史的第一次歸檔被長時間限速打斷] → 書籤不前進、下次從最新訊息重翻；TDLib 的訊息資料庫是開著的，已載入的頁應由本機回答，尚未在真實資料上確認（5.3），需要時另做 #74 的接續參數。
- [第三方逐字內容] → 清單與回報不含內容；skill 與 README 提醒不得 commit 到公開 repo。媒體檔同樣是第三方內容，適用同一規則。
- [大檔案與磁碟用量] → 預設不限（維護者決定），`max_media_mb` 可設上限；一則一則同步下載，大量媒體時單次工具呼叫會較久，待實際執行時量測。
