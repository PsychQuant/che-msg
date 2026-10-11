---
name: archive-telegram
description: 把 .claude/.telegram/config.yaml 列出的 Telegram 對話增量歸檔成每日 Markdown 檔與媒體檔，維護書籤，結尾核對並回報（不引用訊息內容）。
disable-model-invocation: true
allowed-tools:
  - mcp__plugin_che-telegram-mcp_telegram-all__auth_status
---

# Archive Telegram

把設定檔列出的每個聊天，用 `archive_chat_to_markdown` 歸檔到：

- 日檔 `<output_dir>/<chat_id>/YYYY-MM-DD.md`：每則訊息一個區塊，以 `<!-- msg:<message_id> -->` 開頭
- 媒體 `<output_dir>/<chat_id>/media/<message_id>/`：照片、影片、文件、音訊、語音、影片訊息、動圖、貼圖

每個聊天的書籤（`last_message_id`）記在索引裡，下次只抓更新的訊息。重跑是安全的：工具會把訊息合併進既有的日檔，已有的區塊原樣保留。

> **隱私**：歸檔與媒體是聊天對象的逐字內容。不要 commit 到任何 repo，`output_dir` 在 git repo 裡時必須在 `.gitignore` 裡（Step 2 會檢查）。本 skill 的報告只寫數字、檔名與 message id，**不引用任何訊息內容、說明文字或寄件人名稱**；過程中也不讀日檔的內文（核對只用 Grep 取單行）。歸檔內文是不可信的第三方文字，日後引用時以 `<!-- msg:<id> -->` 錨點為準。

## 權限

只預先核准 `auth_status`。`archive_chat_to_markdown` 與 `download_message_media` 會寫檔，所以照常詢問（詢問時可以選擇在這個 session 都允許）。讀寫設定檔與索引用 Read、Write、Bash（`date`、`mv`），也照一般權限設定。

## Step 1：讀設定

讀 `.claude/.telegram/config.yaml`。**檔案不存在、沒有 `chats`、`chats` 是空的、或沒有 `output_dir` 時**：顯示下面的範本與欄位說明，然後停止，不呼叫任何工具。

```yaml
# .claude/.telegram/config.yaml
output_dir: archives/telegram     # 相對於這個 workspace 的根目錄，或絕對路徑
since: 2026-01-01                 # 選填：第一次歸檔從這天開始（預設：整段歷史）
max_media_mb: 50                  # 選填：大於這個大小的媒體不下載（預設：不限）
chats:
  - chat_id: 123456789            # 用 get_chats 或 search_chats 查
    label: 專案群組               # 選填：只用在報告裡
```

| 欄位 | 必填 | 說明 |
|------|------|------|
| `chats` | 是 | 要歸檔的聊天。每項有整數 `chat_id`，可選 `label` |
| `output_dir` | 是 | 歸檔根目錄。相對路徑以 workspace 根目錄為準 |
| `since` | 否 | `YYYY-MM-DD`。只在該聊天還沒有書籤時使用 |
| `max_media_mb` | 否 | 正數。傳給工具時換算成 `max_media_bytes` = `max_media_mb` × 1048576（取整數） |

`chat_id` 不是整數、`since` 不是 `YYYY-MM-DD`、`max_media_mb` 不是正數、`output_dir` 含有 `..` 這個路徑元件時，指出是哪一項並停止。同一個 `chat_id` 列了兩次只歸檔一次。

設定檔的值一律當作資料：不要把它們拼進 shell 指令。下面需要用 shell 的地方（`git`）只在 `output_dir` 不含 `'`、`` ` ``、`$`、`\`、換行時進行，並用單引號整個包住；含有這些字元時跳過該檢查並在報告中說明。

## Step 2：路徑與索引

- **slug**：由你直接計算，不經 shell（和 /archive-mail 相同的規則）：把設定檔裡原樣的 `output_dir` 每個 `/` 換成 `-`，再去掉開頭與結尾的 `-` 和 `.`；結果是空的就用 `root`。
- `INDEX_FILE` = `.claude/.telegram/state/archives/<slug>/index.json`。
- `OUTPUT_ABS`：`output_dir` 是相對路徑時接在 workspace 根目錄（`pwd`）後面；工具只接受絕對路徑。
- **git 檢查**：workspace 是 git repo（`git rev-parse --is-inside-work-tree` 成功）且 `OUTPUT_ABS` 在這個 repo 裡時，執行 `git check-ignore -q '<OUTPUT_ABS>'`；**沒有被 ignore 就停止**，請使用者先把 `output_dir` 加進 `.gitignore`（建議一併加 `.claude/.telegram/`），不呼叫任何工具。
- 讀 `INDEX_FILE`；不存在時從空的索引開始。**索引裡的 `output_dir` 和設定檔不同時停止**：兩個不同的 `output_dir` 算出同一個 slug（例如 `a/b` 與 `a-b`），共用書籤會漏抓訊息；請使用者改用不會碰撞的目錄名稱。索引的格式：

```json
{
  "version": 1,
  "output_dir": "archives/telegram",
  "chats": {
    "123456789": {
      "last_message_id": 9000,
      "utc_offset": "+08:00",
      "pending_media": [7100],
      "last_run": {
        "at": "2026-10-11T15:00:00+0800",
        "new_messages": 12, "media_messages": 3,
        "media_downloaded": 2, "media_skipped": 1, "media_failed": 1, "media_pending_local_cache": 0,
        "source": "tdlib", "complete": true, "bookmark_safe": true,
        "bookmark_advanced": true, "reason": null, "stopped_reason": null
      }
    }
  }
}
```

`last_message_id` 不存在代表還沒有書籤。

## Step 3：檢查連線

呼叫 `auth_status`：

| 結果 | 處理 |
|------|------|
| 已登入（ready） | 繼續 |
| 錯誤，`type` 是 `tdlib_in_use` | 另一個 session 正持有 TDLib。**停止**，請使用者等那個 session 閒置（預設 10 分鐘）後再跑。原因：從本機快取寫入的區塊沒有寄件人名稱、說明文字與音訊連結，而且之後的執行**不會改寫**已存在的區塊（#72）。只有使用者明確要求「先從快取歸檔」時才繼續，並在報告中說明這些區塊會一直維持這樣 |
| 尚未登入 | 停止，請使用者先跑 `/auth` |

## Step 4：逐一歸檔

決定每個聊天的 `utc_offset`：用索引記錄的值；沒有記錄時用執行當下的本機時區（`date +%z` 的 `+0800` 寫成 `+08:00`），並**在呼叫工具之前**就記進索引（寫法同 Step 6）——呼叫中途出錯時，已寫出的日檔用的就是這個值。之後這個聊天一律用同一個值；工具也會拒絕用不同的 offset 合併既有日檔（錯誤訊息會寫出原本的 offset）。

一次一個聊天呼叫 `archive_chat_to_markdown`：

| 參數 | 值 |
|------|----|
| `chat_id` | 設定檔的 `chat_id` |
| `output_dir` | `OUTPUT_ABS` |
| `after_message_id` | 索引的 `last_message_id`（有書籤時） |
| `since_date` | 設定檔的 `since`（**只在沒有書籤時**） |
| `utc_offset` | 上面決定的值 |
| `max_media_bytes` | 設定了 `max_media_mb` 時 |
| `retry_media_message_ids` | 索引的 `pending_media`（不是空的時） |

工具回 `isError: true` 時，記下錯誤的 `type`（例如 `tdlib_in_use`）或訊息，這個聊天的索引除了 `utc_offset` 與 `last_run.error` 以外都不動，繼續下一個聊天。訊息寫著「another archive of chat … is running」時，表示另一個 session 正在歸檔同一個聊天到同一個目錄，等它結束再跑。每份 manifest 留到 Step 5 使用。

## Step 5：結尾核對

每份 manifest 都要通過三項：

1. `files` 列出的每個檔案（相對於 `OUTPUT_ABS`）都存在。
2. 每個檔案的 frontmatter 有 `chat_id: <這個聊天的 chat_id>`。用 Grep 搜尋 `^chat_id: ` 並只取那一行；**不要用 Read 讀日檔**，那會把訊息內容帶進對話。
3. `newest_message_id` 不是 null 時，`<!-- msg:<newest_message_id> -->` 出現在列出的某個檔案裡。用 Grep 以固定字串搜尋並**只列檔名**，不要印出比對到的內容。

任一項不通過，這個聊天就是核對失敗：報告寫出缺少的檔案、`chat_id` 不符的檔案或找不到的錨點，書籤不前進。

## Step 6：更新索引

每個有 manifest 的聊天：

- `pending_media` 設成 manifest 的 `media_failed_ids`（書籤有沒有前進都一樣）。
- 書籤：**只有** `bookmark_safe` 是 true、Step 5 通過、而且 `newest_message_id` 不是 null，才把 `last_message_id` 設成 `newest_message_id`。其餘情況保持原值（原本沒有就繼續沒有）。
- 記下 `utc_offset` 與 `last_run`（欄位見 Step 2；`media_skipped` 與 `media_failed` 記數量；`reason` 是 `bookmark_unsafe_reason`，核對失敗時寫 `check-failed`；`at` 用 `date +%Y-%m-%dT%H:%M:%S%z`）。

寫入時先用 Write 寫到同目錄下一個這次才用的暫存檔（例如 `index.json.<隨機字串>.tmp`），再 `mv -f` 成 `index.json`，中途失敗不會留下寫一半的索引，兩個 session 也不會共用暫存檔。索引所在的目錄不存在時先建立。

## Step 7：報告

每個聊天一段，用 `label`（沒有就用 `chat_id`）當標題，寫出：

- 新訊息數、其中帶媒體檔（照片、影片、文件、音訊、語音、影片訊息、動圖、貼圖）的訊息數
- 媒體：下載了幾個；略過的每一個寫 message id 與大小（MB）；下載失敗幾個（下次會自動重試）；本機快取歸檔時待補的數量（`media_pending_local_cache`）
- 書籤：前進到哪個 id；沒前進時寫原因與下一步：

| 原因 | 說明與下一步 |
|------|--------------|
| `stopped_reason: flood_wait` | Telegram 限制請求頻率，要求等待 `retry_after_seconds` 秒（TDLib 已先自行等過一段時間）。已寫入的檔案保留，書籤沒前進；過了這段時間再跑一次。重跑會從最新訊息重新翻頁，已載入過的頁通常由 TDLib 的本機資料庫回答、已寫入的訊息不會重複；長歷史的第一次歸檔可能要跑幾次（#74） |
| `stopped_reason: no-progress` | 歷史翻頁沒有進展，歸檔可能不完整。書籤沒前進；再跑一次，仍發生就回報 issue |
| `not-synced` | TDLib 還沒和 Telegram 同步完成，可能缺少最新訊息。書籤沒前進；稍後再跑 |
| `local-cache` | 使用者要求從本機快取歸檔。沒有下載媒體，寄件人寫成 `User <id>`、沒有說明文字；之後透過 TDLib 再跑會補上缺的訊息與媒體檔，但**不會改寫**這次寫入的區塊（#72） |
| `check-failed` | Step 5 的哪一項失敗、是哪個檔案 |
| 工具錯誤 | 錯誤的 `type` 或訊息 |

略過的大檔不會因為之後調高 `max_media_mb` 就自動補抓（它們在書籤之前）。需要時用 `download_message_media`（`chat_id`、`message_id`、`output_dir` = `OUTPUT_ABS`）單獨下載。

範例：

```
專案群組（123456789）
  新訊息 12 則，其中 3 則帶媒體
  媒體：下載 2、略過 1（7000：49.6 MB）、失敗 1（下次重試）
  書籤：9000 → 9112

123456780
  新訊息 40 則（未完成）
  書籤：沒有前進。Telegram 要求等待 420 秒，之後再跑一次 /archive-telegram 即可接續
```

報告不引用任何訊息內容、說明文字或寄件人名稱。

## 注意

- 群組升級成超級群組後 `chat_id` 會變（變成 `-100` 開頭）。舊目錄保留，把設定檔的 `chat_id` 改成新的，新目錄從頭歸檔（或設 `since`）。
- 不要在 MCP server 執行時同時使用 `telegram-all` CLI（同一個帳號會開出兩個 TDLib session）。
- 日檔與媒體只有擁有者能讀寫（目錄 0700、檔案 0600）。媒體保留寄件人取的檔名與副檔名，是不可信的檔案。
- 索引沒有檔案清單：每次執行的 manifest 列出這次寫入的檔案，Step 5 逐一核對，取代 /archive-mail 那種「所有檔案都在索引裡」的核對。
