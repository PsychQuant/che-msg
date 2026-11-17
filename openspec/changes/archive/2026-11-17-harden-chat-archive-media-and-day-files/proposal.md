## Why

`archive_chat_to_markdown`（#69）上線後，verify round 3 留下兩組沒有擋住 release 的邊角，都不會丟資料，但會讓歸檔卡住、重複或留下不必要的風險（PsychQuant/che-msg#75、#76）：

- 媒體下載失敗的 id 每次都重試，訊息已經刪掉的也一樣，永遠不會從 `pending_media` 消失；存下來的媒體沒有 macOS 的 quarantine 屬性，從 Finder 打開別人傳來的 app 或腳本時 Gatekeeper 不會檢查；本機快取沒有日期的紀錄被略過時沒有任何計數（#75）。
- 日檔的前置檢查用 `FileHandle(forReadingAtPath:)` 開檔：一個名字像日檔的 FIFO 會讓呼叫卡在 open，而這時呼叫握著聊天的 `.archive.lock`，server 也因為有呼叫進行中而一直不關 TDLib，其他 session 只能拿到 `tdlib_in_use`；symlink 日檔會被跟隨，最後在 `replaceItemAt` 報出看不懂的 Cocoa 4；frontmatter 是 LF、內文是 CRLF 的日檔會通過檢查，而合併時找不到任何錨點，每則訊息都再寫一次。skill 對空的或 `~` 開頭的 `output_dir` 沒有定義，權限段落也少列了實際會跑的指令（#76）。

## What Changes

- 重試媒體時，TDLib 回答訊息不存在（`getMessage` 文件寫明的 404，或 400 且文字恰為 `Message not found`）的 id 改列在新的 manifest 欄位 `media_gone_ids`，不再列在 `media_failed_ids`。skill 照舊把 `pending_media` 設成 `media_failed_ids`，所以這些 id 自然不再重試；報告寫出數量。其他錯誤（含限流、`Chat not found`、下載失敗）照舊留在待重試。
- 新存的媒體檔在 rename 到定位之前設好 `com.apple.quarantine`（Foundation 的 quarantine properties，類型 `LSQuarantineTypeInstantMessageAttachment`）。設不上就不存檔，算下載失敗。已經存在的檔案不動。
- manifest 新增 `undated_messages_skipped`：範圍內因為來源沒有日期而沒寫入的訊息數（只有本機快取會出現）；skill 把它記進 `last_run`，不是 0 時寫進報告。
- 日檔一律以 `O_RDONLY | O_NONBLOCK | O_NOFOLLOW` 開啟並用 `fstat` 確認是一般檔案，前置檢查與合併時的讀取都用同一個 helper。FIFO、device、目錄與 symlink（含懸空的）都拒絕，錯誤說明「不是一般檔案」。
- 要合併的日檔只要含 `\r`（以 Unicode scalar 判斷）就拒絕，錯誤說明「含有 carriage return」；檢查放在合併時，只看這次會寫到的日檔。
- skill：`output_dir` 去掉前後空白後不得為空、不得含 `..`、不得以 `~` 開頭（skill 不展開 `~`），違反時指出欄位並停止；權限段落補上 `git`、`mkdir` 與 Grep；比對日檔錯誤改用新舊版 binary 都有的「cannot be merged into safely」。
- 媒體檔名的過濾不改：`CharacterSet.controlCharacters` 本來就涵蓋 Cc 與 Cf（雙向格式字元都在 Cf），只補一個釘住 U+202E、U+2066、U+061C 的測試，spec 寫明過濾的範圍。

## Non-Goals

- 不加每個 id 的失敗計數器：訊息還在但檔案永遠下載不了（例如媒體已過期）的情況照舊每次重試（#75 Open question 2，見下方預設）。
- 不回頭替已經存下來的媒體檔補 quarantine 屬性（#75 Open question 3）。
- 不在前置檢查裡讀完整個日檔找 `\r`（#76 Open question 1）。
- 不處理 `<chat_id>` 或 `media/` 目錄本身是 symlink 的情況（#69 round 2 已記錄為不改）。
- 不改本機快取讀不到寄件人、說明文字的問題（#72），也不改本機快取解不開的紀錄。

## Defaults chosen while the maintainer was away

兩個 issue 的 Diagnosis 都留了 Open questions；維護者不在，以下照 Diagnosis 的建議或預設選項，並記在 design 與 commit message：

| Issue | 問題 | 採用的預設 |
|-------|------|------------|
| #75 Q1 | 是否與 #76 合併成一個 change | 合併（本 change） |
| #75 Q2 | 只做精確分類，或也加失敗計數 | 只做精確分類（建議選項），不加計數 |
| #75 Q3 | quarantine 只加在新檔，或也補舊檔 | 只加在新檔 |
| #76 Q1 | 含 CR 的日檔在哪一步拒絕 | 合併時（只看這次會寫到的日檔） |
| #76 Q2 | 是否與 #75 合併 | 合併 |
| #76 item 5 | 媒體檔名 | 只補測試，不改過濾 |

另有一處依據查證修正 Diagnosis 的前提：#75 的 Strategy 寫「TDLib `400` 且文字為 `Message not found`」，但 TDLib 1.8.60-cb863c16 的 `td_api.tl`（TDLibKit 產生的 `GetMessage.swift` 照抄）寫的是「Returns a 404 error if the message doesn't exist」。所以分類同時接受 404 與 Diagnosis 寫的 400 `Message not found`，其餘一律留在待重試（見 design）。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `telegram-chat-archive`：修改七個 requirement——「Merge and idempotent rewrite」（不是一般檔案與含 CR 的日檔）、「Content-free manifest」（`media_gone_ids`、`undated_messages_skipped`）、「Archive from the local cache」（沒有日期的紀錄）、「Media download into the archive」（quarantine、檔名過濾的範圍）、「Media retry by message id」（訊息不存在的分類）、「archive-telegram skill configuration and index」（`output_dir` 規則、`pending_media` 不含已刪除的）、「archive-telegram end-of-run check and report」（報告的新數字）。

## Impact

- 受影響的 spec：`telegram-chat-archive`
- 程式：`che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift`、`che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift`、`che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift`、`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift`（工具說明）
- 測試：`che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift`、`ArchiveMediaTests.swift`、`ChatArchiverTests.swift`、`LocalCacheArchiveTests.swift`
- skill 與文件：`plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md`、`che-telegram-all-mcp/README.md`、`plugins/che-telegram-mcp/README.md`、`che-telegram-all-mcp/CHANGELOG.md`、`plugins/che-telegram-mcp/CHANGELOG.md`
- 相容性：舊 skill 配新 binary 時，已刪除的 id 不在 `media_failed_ids` 裡，一樣不再重試，只是報告不寫數量；新 skill 配舊 binary 時兩個新欄位不存在，當作沒有。
