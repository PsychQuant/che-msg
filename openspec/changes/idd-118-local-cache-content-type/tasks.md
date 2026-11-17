## 1. 測試先行（每個 Example 一個測試，先看到它失敗）

- [x] 1.1 新增 `LocalReaderContentTypeTests`，標記 `spec-example: telegram-local-reader / every internal content type has its type and name`：對 0…85 每個內部編號斷言解碼出的 `type` 與 `content_type`（12 個依內容決定的編號沒有 `content_type`，62 個有 `get_message_content_object` 的 constructor 名稱，具名類型沒有）；在實作前跑 `swift test --filter LocalReaderContentTypeTests` 看到失敗
- [x] 1.2 Reader answers five tools with the TDLib-mode JSON fields：同一測試檔加測試，標記 `spec-example: telegram-local-reader / a cached contact carries its content type`：內部編號 8 的快取訊息經 `get_chat_history` 回出與 spec Example 相同的 JSON 物件（含 `"content_type":"messageContact"`）；實作前失敗
- [x] 1.3 同一測試檔加測試，標記 `spec-example: telegram-local-reader / a payload-dependent content type is omitted`：內部編號 41 的訊息物件是 `type` `other` 且沒有 `content_type` 鍵
- [x] 1.4 同一測試檔加測試，標記 `spec-example: telegram-local-reader / a cached audio message`：內部編號 2 的訊息經 `get_chat_history` 回出 spec Example 的 JSON 物件（`"type":"audio"`、沒有 `content_type`），從快取 dump 同一聊天時寫成 `[audio]`；實作前失敗
- [x] 1.5 Archive from the local cache：在 `LocalReaderContentTypeTests` 加測試，標記 `spec-example: telegram-chat-archive / cached audio counts as pending media`：經真的快取讀取器（`LocalTDLibReader` 讀一則內部編號 2 的訊息）歸檔時，日檔區塊內文是 `[audio](media/30/)`，manifest 的 `media_pending_local_cache` 是 1；實作前失敗（原本放 `LocalCacheArchiveTests` 的假讀取器，改用真讀取器，修正前就會失敗，見下方 ASSUMPTION）

  ASSUMPTION: 1.5 的測試放在 `LocalReaderContentTypeTests` 而不是 `LocalCacheArchiveTests`：後者的讀取器是直接給 `type` 字串的假物件，測不到解碼器把內部編號 2 交給歸檔這一段。

## 2. 實作

- [x] 2.1 照 design「名稱表放在獨立檔案，解碼器只記結果」新增 `TDLibContentTypeNames.apiName(forContentType:)`（`che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibContentTypeNames.swift`）：62 個單一 constructor 的內部編號回傳名稱，其他回 nil；以 1.1 的測試驗證 [after: 1.1]
- [x] 2.2 `LocalMessage.Kind` 加 `audio`，`kind(forContentType:)` 把 2 對到 `audio`；`TDLibMessageDecoder.Record` 與 `LocalMessage` 加 `contentType`，解碼器只在種類為 `other` 時填入，`LocalMessage.dictionary` 只在不是 nil 時寫 `content_type`；把 `LocalReaderMessageDecodingTests` 既有的種類對照表裡 2 → `other` 改成 2 → `audio`；以 1.1–1.5 的測試與 `swift test --skip E2ETests` 全部通過驗證 [after: 2.1]

## 3. 文件

- [ ] 3.1 README 改寫說快取的音訊讀成 `[other]` 的句子，並寫出快取回答的 `other` 何時帶 `content_type`、哪 12 種內部類型不帶；CHANGELOG `## [Unreleased]` 記一筆（引用 #118）；以內容審閱確認 README 裡不再有「快取音訊是 `[other]`」的說法（`grep -n "audio" che-telegram-all-mcp/README.md`） [after: 2.2]
