## 1. 測試（先看到它失敗）

- [x] 1.1 Reader answers five tools with the TDLib-mode JSON fields：`LocalReaderContentTypeTests.testEveryInternalContentTypeHasItsTypeAndName`（標記 `spec-example: telegram-local-reader / every internal content type has its type and name`）對內部編號 0 解碼一筆真的文字記錄（`LocalReaderRecords.message`），斷言 `type` 是 `text`、沒有 `content_type`；以 `swift test --filter LocalReaderContentTypeTests` 驗證
- [x] 1.2 `LocalReaderToolTests.testPagingWithTheLowestIdReturnsEachMessageOnce`（標記 `spec-example: telegram-local-reader / paging with the lowest id returned`）逐頁斷言 `[7340032]`、`[6291456]`、`[5242880]`、`[]`；先把斷言套在忽略 `limit` 的情況（暫時傳 `limit: 2`）看到它失敗，再改回 `limit: 1` 通過；以 `swift test --filter LocalReaderToolTests` 驗證

## 2. 文字

- [x] 2.1 `TDLibContentTypeNames.swift` 的註解、README、CHANGELOG 照修改後的 requirement 改寫：74 依聊天種類、其餘 11 依內容；README 不再說快取的 `type` 與 TDLib 模式全等，寫明 `Text`、`Photo` 的例外（#124），並把「deleted chat photo」改成只指內部類型 13；CHANGELOG 寫明 v0.8.0 從快取寫的區塊沒有標記、不會被升級；以 `grep -n "same \`type\` values\|chosen by the payload\|chooses from the payload" che-telegram-all-mcp/README.md che-telegram-all-mcp/CHANGELOG.md che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibContentTypeNames.swift` 沒有結果與內容審閱確認
