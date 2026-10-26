## Context

歸檔的三個檔案各管一段：`ArchiveDayFile` 讀寫日檔（`checkOffsets` 是呼叫開始、讀任何訊息之前的前置檢查，只讀每個日檔的前 512 bytes；`write` 讀整個日檔、合併、以暫存檔 rename 取代），`ArchiveMedia.ensure` 把 TDLib cache 的檔案複製到 `media/<id>/`（暫存檔 → 0600 → rename），`ChatArchiver` 翻頁、寫日檔、下載媒體、重試 `retry_media_message_ids`，最後組 manifest。

現況的問題都在這幾個點上：

- `checkOffsets` 用 `FileHandle(forReadingAtPath:)`，`write` 用 `fileExists` + `String(contentsOf:)`：兩者都跟隨 symlink，開 FIFO 時會等寫入端。`fileExists` 對懸空的 symlink 回 false，`write` 因此走第一次寫入的分支，在 `moveItem` 失敗。
- `split` 用 `firstIndex(of: "\n")` 找行尾；Swift 的 `"\r\n"` 是一個 `Character`，不等於 `"\n"`，CRLF 的內文找不到任何錨點，`merged` 把整段舊內容當 preamble，再把每則訊息加一次。
- `retryMedia` 用 `try? await media.message(...)`，錯誤被丟掉，刪掉的訊息和暫時失敗分不出來。
- `ensure` 沒有設 quarantine。
- `write(_:...)` 遇到沒有日期的訊息直接 `continue`，沒有計數。

## Goals / Non-Goals

**Goals:**

- 日檔只讀一般檔案，開檔不跟隨 symlink、不等寫入端；不是一般檔案的日檔在讀任何訊息之前拒絕，錯誤說得出原因。
- 含 carriage return 的日檔不會被合併成重複的訊息。
- 訊息已經不存在的重試 id 會離開 `pending_media`，其他失敗照舊重試。
- 新存的媒體帶 quarantine 屬性。
- 被略過的無日期訊息有數字。

**Non-Goals:**

- 失敗計數器、舊檔補 quarantine、前置檢查全檔掃描 `\r`（三個 Open question 的非預設選項）。
- `<chat_id>`、`media/` 目錄本身是 symlink 的情況。
- 本機快取的解碼能力（#72）。

## Decisions

### 預設選項（維護者不在時採用）

#75 Q1／#76 Q2 合併成一個 change；#75 Q2 只做精確分類；#75 Q3 只標新檔；#76 Q1 在合併時拒絕含 CR 的日檔；#76 item 5 只補測試。每一項都是 Diagnosis 的建議或預設，理由在各自的 Diagnosis；下面只寫實作上的決定。

### 日檔以一個 helper 開啟：`O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`，再 `fstat`

`readDayFile(_:day:limit:)` 回傳檔案內容（`limit` 給前置檢查用的 512 bytes），檔案不存在時回 nil，其餘情況：

- `open` 因 `ELOOP` 失敗（最後一個元件是 symlink，不論目標存不存在）→ `notRegularFile`
- `fstat` 不是 `S_IFREG`（FIFO、device、目錄）→ `notRegularFile`
- 其他 `open`／`fstat`／讀取錯誤 → `unreadableOffset`（沿用「讀不到」的錯誤）

`O_NONBLOCK` 讓 FIFO 的 open 立刻回來（唯讀開 FIFO 不需要寫入端）；確認是一般檔案後用 `fcntl` 清掉這個旗標再讀，一般檔案的讀取本來就不受它影響，清掉只是不讓旗標留在之後的讀取上。前置檢查與 `write` 都用這個 helper：兩者之間檔案可能被換掉（鎖只擋其他歸檔），所以合併時要再確認一次。`write` 也改用它判斷「有沒有舊檔」，懸空的 symlink 因此在讀取時就被拒絕，不會走到 `moveItem`。

替代方案：`lstat` 後再開檔。兩個系統呼叫之間有空檔，FIFO 仍可能在 open 時卡住，捨棄。

### 拒絕原因用兩個新的錯誤 case，而不是延長原本的文字

Diagnosis 的 Strategy 寫「用既有錯誤、延長文字」。實作改成在 `ArchiveDayFile.WriteError` 加 `notRegularFile(day:)` 與 `carriageReturn(day:)`：使用者看到的錯誤直接說是哪一種、怎麼處理（把 symlink 換成檔案本身、改成 LF），不必從一串可能原因裡猜；三種錯誤的文字都包含「cannot be merged into safely」，skill 用這句比對，新舊 binary 都適用。`unreadableOffset` 的文字不變。`WriteError` 只在本 package 內被 switch（`errorDescription`），加 case 不影響其他 target。

### 含 CR 的日檔在合併時拒絕（#76 Q1 預設）

`write` 讀到舊檔後先看 `unicodeScalars` 有沒有 `\r`，有就丟 `carriageReturn`，在 offset 比對之前。用 scalar 而不是 `Character`，因為 `"\r\n"` 是一個 `Character`。這個檢查只對這次會寫到的日檔做；拒絕可能發生在同一次呼叫已經寫好別的日檔之後，那些日檔都是完整、有效的，保留不動。工具自己寫的日檔不會含 `\r`（`block` 把內文的 CR 換成 LF、寄件人的換成空白），所以這個拒絕不會因為工具自己的輸出觸發。

### 重試的分類：404，或 400 且文字恰為 `Message not found`

`retryMedia` 改成 `do/catch` 保留錯誤，交給 `ChatArchiver.messageIsGone(_:)`：

- `TDError.tdlibError(code: 404, _)` → gone。TDLib 1.8.60-cb863c16 的 `td_api.tl`（TDLibKit `Generated/Models/GetMessage.swift`）寫「Returns a 404 error if the message doesn't exist」。這是 TDLib 對 `getMessage` 公開的契約，Diagnosis 沒有查到這一層。
- `TDError.tdlibError(code: 400, "Message not found")`（完全相等）→ gone。這是 Diagnosis 在 `MessagesManager.cpp` 的 `getMessage` 系列找到的字串，保留以免 TDLib 在某條路徑用它回答。
- 其他一律不是 gone：`Chat not found`（同樣是 400）、限流、`notAuthenticated`、測試替身的任意錯誤。

分類只用在重試的「取得訊息」這一步；`media.message` 先 `loadChatForArchive` 再 `getMessage`，前者的錯誤是 400，不會被當成 gone。分類錯的方向只會是「該刪的沒刪」（id 留在待重試，和現在一樣），不會把還在的訊息踢掉。

一個 id 在翻頁時下載失敗、重試時又回 gone（兩次之間被刪）時，最後只列在 `media_gone_ids`。`media_gone_ids` 和 `media_retried_ids` 同時出現（TDLib 路徑、`retry_media_message_ids` 至少一個 id）。

### quarantine：Foundation 的 `quarantineProperties`，設不上就不存檔

在暫存檔設好 0600 之後、rename 之前：`URLResourceValues.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeInstantMessageAttachment"]`。用字串常數，不 import CoreServices。實測（本機 macOS，獨立的 Swift 程式）：屬性在同一個 volume 上 rename 後還在，xattr 為 `0081;<時間>;;<UUID>`，LaunchServices 也會在使用者的 `QuarantineEventsV2` 資料庫記一筆（agent 名稱是程序名稱、類型 3，沒有檔名或 URL），和瀏覽器下載的行為相同。

設定失敗（例如 volume 不支援 extended attribute）時不存檔、回 `.failed`：這樣「工具存下的媒體都有 quarantine」是一個沒有例外的保證。代價是這類 volume 上的媒體會一直列在 `media_failed_ids`；這種 volume 在 macOS 上很少見，而且失敗是看得到的。`download_message_media` 也走 `ensure`，一起適用。已存在的檔案（`alreadyPresent`）不改。

### 無日期的訊息：計數，不改書籤規則

`write(_:...)` 在 `messageDate` 為 nil 時把 `undatedMessagesSkipped` 加一。只有本機快取會產生這種訊息（`TDLibMessageDecoder` 解不開時只回表格欄位；TDLib 的 `messageToDict` 一定有 `date`），而本機快取的呼叫本來就 `bookmark_safe: false`，之後 TDLib 的呼叫會補上，所以不加新的 `bookmark_unsafe_reason`。欄位一律出現（0 也寫），和 `media_pending_local_cache` 一樣。

### skill

- `output_dir` 三條規則寫在 Step 1 的驗證段：去掉前後空白後為空、含 `..`、以 `~` 開頭，都指出 `output_dir` 並停止。`~` 不展開，因為 skill 的其他路徑規則（單引號、不經 shell 算 slug）都假設值是字面路徑。
- 權限段落列出實際用到的 Bash 指令（`date`、`mv`、`mkdir`、`git`）與 Grep。
- Step 4 比對日檔錯誤改用「cannot be merged into safely」，涵蓋三種日檔錯誤與舊 binary 的文字。
- `pending_media` 的規則不變（設成 `media_failed_ids`），補一句說明已刪除的 id 不在裡面；`last_run` 加 `media_gone` 與 `undated_messages_skipped`；報告的媒體那一行加「訊息已刪除、不再重試 N」，無日期的訊息不是 0 時另列一行。

## Risks / Trade-offs

- [刻意用 symlink 放日檔的使用者會被拒絕] → 錯誤說明要把 symlink 換成檔案本身；README 寫明。
- [用 Windows 編輯器改過的日檔會被拒絕] → 只在這次要寫到那一天時才拒絕，錯誤說明要改成 LF。
- [TDLib 改了 404 的語意或 400 的文字] → 分類失敗時退回現在的行為（留在待重試），方向是安全的。
- [不支援 extended attribute 的 volume 上媒體存不下來] → 失敗列在 `media_failed_ids`，看得到；比起存下沒有標記的檔案，選擇不存。
- [測試會在使用者的 `QuarantineEventsV2` 資料庫留下幾筆紀錄] → 和瀏覽器下載相同的副作用，紀錄裡沒有內容；測試只用合成檔案。

## Implementation Contract

- **行為**：
  - 日檔（`<chat_id>/YYYY-MM-DD.md`）不是一般檔案（symlink、懸空 symlink、FIFO、device、目錄）時，呼叫在讀任何訊息之前失敗，錯誤是 `WriteError.notRegularFile(day:)`，不寫任何檔案；開 FIFO 不會等待。
  - 要合併的日檔含 `\r` 時，該次 `ArchiveDayFile.write` 丟 `WriteError.carriageReturn(day:)`，該檔位元組不變；同一次呼叫先前寫好的日檔保留。
  - 重試時取得訊息的錯誤是 404，或 400 且文字恰為 `Message not found`，該 id 列在 `media_gone_ids`、不在 `media_failed_ids`；其他錯誤照舊列在 `media_failed_ids`。
  - `ArchiveMedia.ensure` 新存的檔案有 `com.apple.quarantine`；設不上時回 `.failed`，暫存檔移除，目標不存在。
  - manifest 一律有 `undated_messages_skipped`；TDLib 路徑且 `retry_media_message_ids` 至少一個 id 時有 `media_gone_ids`。
- **介面**：
  - `ArchiveDayFile.WriteError` 新增 `notRegularFile(day: String)`、`carriageReturn(day: String)`；三種日檔錯誤的 `errorDescription` 都包含 `cannot be merged into safely`。
  - `ArchiveDayFile.readDayFile(_ file: URL, day: String, limit: Int? = nil) throws -> Data?`（internal）。
  - `ChatArchiver.Result` 新增 `mediaGoneIds: [Int64]?`、`undatedMessagesSkipped: Int`；`ChatArchiver.messageIsGone(_ error: Error) -> Bool`（internal static）。
  - `ArchiveMedia.quarantineProperties`（internal static，`["LSQuarantineType": "LSQuarantineTypeInstantMessageAttachment"]`）。
- **錯誤與邊界**：檔案在前置檢查與合併之間消失時，前置檢查照舊算讀不到（`unreadableOffset`），合併時算第一次寫入。非 UTF-8 的日檔在合併時算讀不到（`unreadableOffset`）。`media_gone_ids` 與 `media_failed_ids`、`media_retried_ids` 不重疊。已存在的媒體檔不加屬性。
- **驗收**：`ArchiveDayFileTests`（FIFO 在 5 秒期限內被拒、symlink 與懸空 symlink 與目錄被拒且目標不變、內文 CRLF 與單獨 CR 被拒且位元組不變、工具自己的輸出不含 `\r`）、`ChatArchiverTests`（CR 日檔讓呼叫失敗且不重複訊息、FIFO 日檔在讀任何頁之前被拒）、`ArchiveMediaTests`（gone 的分類表、`media_gone_ids` 的 JSON、quarantine 屬性、已存在的檔不加、雙向格式字元檔名）、`LocalCacheArchiveTests`（無日期紀錄的計數）；`swift test --skip E2ETests` 全過；`tests/che-telegram-mcp/*.sh` 全過。
- **範圍外**：失敗計數器、舊檔補 quarantine、前置檢查全檔掃描 `\r`、目錄層級的 symlink、本機快取解碼（#72）。
