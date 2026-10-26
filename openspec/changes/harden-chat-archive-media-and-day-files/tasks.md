## 1. 日檔只讀一般檔案（#76 items 1、3）

- [x] 1.1 先寫失敗的測試（Requirement: Merge and idempotent rewrite 的 FIFO 與 symlink scenario）：名字像日檔的 FIFO 讓 `checkOffsets` 與 `write` 在 5 秒期限內回 `notRegularFile`（逾時時測試自己開寫入端放掉卡住的 open，再判失敗）；指向目錄外有效日檔的 symlink、懸空的 symlink、名字像日檔的目錄都回 `notRegularFile`，link 與目標位元組不變；`ChatArchiver` 遇到 symlink 日檔時一頁都沒讀就失敗、link 與目標不變（FIFO 的同一條路徑在 `ArchiveDayFile` 層以期限測）。驗證：`swift test --filter ArchiveDayFileTests` 與 `--filter ChatArchiverTests` 先失敗，且沒有卡住
- [x] 1.2 依設計「日檔以一個 helper 開啟」與「拒絕原因用兩個新的錯誤 case」實作 `readDayFile`（`O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`、`fstat` 要求 `S_IFREG`、讀前清掉 `O_NONBLOCK`）與 `WriteError.notRegularFile`，`checkOffsets` 與 `write` 都改用它。驗證：1.1 的測試與既有的 `ArchiveDayFileTests`、`ChatArchiverTests` 通過 [after: 1.1]

## 2. 含 carriage return 的日檔（#76 item 2）

- [x] 2.1 先寫失敗的測試（Scenario: Carriage return below the frontmatter）：LF frontmatter、內文有 CRLF 的日檔，以及內文有單獨 CR 的日檔，`write` 回 `carriageReturn` 且檔案位元組不變；`ChatArchiver` 遇到這種日檔時呼叫失敗、沒有任何訊息寫兩次；含 CR 的訊息內文與寄件人經 `render` 後不含 `\r`。驗證：`swift test --filter ArchiveDayFileTests` 與 `--filter ChatArchiverTests` 先失敗（`render` 那一項本來就通過，作為不會誤拒工具自己輸出的保證）[after: 1.2]
- [x] 2.2 依設計「含 CR 的日檔在合併時拒絕」在 `write` 讀到舊檔後以 `unicodeScalars` 檢查 `\r`，新增 `WriteError.carriageReturn`；三種日檔錯誤的文字都含 `cannot be merged into safely`。驗證：2.1 的測試通過，錯誤文字的測試確認三種都含那一句 [after: 2.1]

## 3. 媒體檔名（#76 item 5）

- [x] 3.1 補測試（Requirement: Media download into the archive 的 Scenario: Bidirectional formatting characters in a file name；依設計「預設選項（維護者不在時採用）」的 #76 item 5，只補測試）：檔名含 U+202E、U+2066、U+2069、U+061C、U+200E、U+200F 時都被去掉，`invoice` U+202E `fdp.exe` 存成 `invoicefdp.exe`。不改程式。驗證：`swift test --filter ArchiveMediaTests` 第一次就通過（Diagnosis 已確認現有過濾涵蓋 Cf）

## 4. 重試時訊息已不存在（#75 item 1）

- [x] 4.1 先寫失敗的測試（Requirement: Media retry by message id 的分類表與 Scenario: Retried message no longer exists）：`messageIsGone` 對 404、400 `Message not found` 為真，對 400 `Chat not found`、429 限流、`notAuthenticated`、其他錯誤為假；重試 `[7100, 7300]`、7100 回 404、7300 下載失敗時 `media_gone_ids` 為 `[7100]`、`media_failed_ids` 為 `[7300]`、`media_retried_ids` 為 `[]`，manifest JSON 有 `media_gone_ids`；沒有給 `retry_media_message_ids` 時 manifest 沒有這個欄位（Requirement: Content-free manifest）；本機快取路徑照舊把 id 放回 `media_failed_ids`。驗證：`swift test --filter ArchiveMediaTests` 先失敗
- [x] 4.2 依設計「重試的分類」實作：`retryMedia` 以 `do/catch` 保留錯誤，`messageIsGone` 為真時列入 `mediaGoneIds`；`archive` 最後從 `mediaFailedIds` 去掉 gone 的 id；`manifestJSON` 輸出 `media_gone_ids`。驗證：4.1 的測試與既有的重試測試通過 [after: 4.1]

## 5. 媒體的 quarantine 屬性（#75 item 2）

- [x] 5.1 先寫失敗的測試（Requirement: Media download into the archive 的 Scenario: Saved media is quarantined）：`ensure` 新存的檔案有 `com.apple.quarantine`（以 `getxattr` 讀，並以 `URLResourceValues.quarantineProperties` 讀回類型 `LSQuarantineTypeInstantMessageAttachment`）；`downloadOne` 存的檔案也有；目錄裡已存在的檔案（`alreadyPresent`）不會被加上（依設計「預設選項（維護者不在時採用）」的 #75 Q3，只標新檔）。驗證：`swift test --filter ArchiveMediaTests` 先失敗
- [x] 5.2 依設計「quarantine：Foundation 的 quarantineProperties，設不上就不存檔」在暫存檔設好 0600 之後、rename 之前設屬性，失敗時走既有的 catch（移除暫存檔、回 `.failed`）。驗證：5.1 的測試與既有的 `ArchiveMediaTests` 通過 [after: 5.1]

## 6. 無日期的訊息計數（#75 item 3）

- [x] 6.1 先寫失敗的測試（Requirement: Archive from the local cache 的 Scenario: Cache record without a date；Requirement: Content-free manifest 的 Scenario: Manifest after a first run 的 `undated_messages_skipped`）：本機快取回 30 與沒有日期的 20 時，只寫 30，`undatedMessagesSkipped` 為 1、`new_messages` 為 1、manifest JSON 有 `undated_messages_skipped: 1`；一般的 TDLib 呼叫 manifest 有 `undated_messages_skipped: 0`。驗證：`swift test --filter LocalCacheArchiveTests` 與 `--filter ChatArchiverTests` 先失敗
- [x] 6.2 依設計「無日期的訊息：計數，不改書籤規則」實作計數與 manifest 欄位。驗證：6.1 的測試通過 [after: 6.1]

## 7. skill 與文件

- [x] 7.1 SKILL.md（Requirement: archive-telegram skill configuration and index、Requirement: archive-telegram end-of-run check and report）：Step 1 的 `output_dir` 三條規則（空白、`..`、`~`）、權限段落列出 `date`、`mv`、`mkdir`、`git` 與 Grep；Step 4 以「cannot be merged into safely」比對日檔錯誤並說明三種原因；Step 6 說明已刪除的 id 不在 `media_failed_ids` 裡、`last_run` 加 `media_gone` 與 `undated_messages_skipped`；Step 7 報告與範例加上這兩個數字。驗證：`for t in tests/che-telegram-mcp/*.sh; do bash "$t" | tail -1; done` 全過，人工核對 Scenario: Output directory under the home shorthand、Gone media leaves the pending list、Report names media that is gone 都有對應的步驟 [after: 4.2, 6.2, 2.2]
- [x] 7.2 工具說明（`Server.swift` 的 `archive_chat_to_markdown`）、all-mcp README 的 manifest 欄位、日檔拒絕條件與 quarantine、plugin README 的歸檔段落、兩份 CHANGELOG 的 `[Unreleased]`（各記 #75、#76）。驗證：人工核對 README 的欄位名稱與 `manifestJSON` 的鍵一致；`swift test --skip E2ETests` 全過 [after: 7.1]

## 8. Verify round 1 的修正

- [x] 8.1 quarantine 設不上的路徑要有測試（Requirement: Media download into the archive）：`ArchiveMedia.ensure` 的 quarantine 步驟改成可注入（預設是真的 `markQuarantined`），測試注入會丟錯的版本，確認回 `.failed`、暫存檔移除、目標不存在。驗證：`swift test --filter ArchiveMediaTests/testMediaThatCannotBeQuarantinedIsNotSaved` 通過，且把呼叫處的 `try` 改成 `try?` 時這個測試失敗
- [ ] 8.2 含 CR 的日檔只在這次呼叫真的要加訊息時才拒絕（Requirement: Merge and idempotent rewrite）：檔案已經有這一天這次要寫的每一則訊息時（CRLF 當成換行來讀錨點），不拒絕、不改檔；否則照舊拒絕。驗證：先寫的測試（CRLF 日檔已含要寫的訊息時 `write` 回空、檔案不變；`ChatArchiver` 重跑不會卡在這個檔）先失敗、改完通過 [after: 8.1]
- [ ] 8.3 `readDayFile` 的錯誤分類（Requirement: Merge and idempotent rewrite）：open 失敗時以 `lstat` 判斷名字本身是什麼，socket 回 `notRegularFile`，上層目錄 symlink 迴圈回 `unreadableOffset`。驗證：先寫的測試先失敗、改完通過 [after: 8.2]
- [ ] 8.4 文件：README 與 CHANGELOG 說明只有日檔本身不跟隨 symlink（上層目錄如 `<chat_id>/` 會跟隨）；CHANGELOG 與 README 拿掉「維護者不在時的預設」這種流程用語；`getMessage` 在 pin 的 TDLib 對不存在的訊息回 404 `Not Found`，400 `Message not found` 來自其他請求，照實寫；spec 與 skill 跟著 8.2 改。驗證：人工核對；plugin tests 與 `swift test --skip E2ETests` 全過 [after: 8.3]
