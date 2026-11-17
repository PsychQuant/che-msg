## Problem

第 1 輪 verify（PsychQuant/che-msg#118 的 verify 報告）指出 `telegram-local-reader` 的兩處文字與事實不符：

1. 省略 `content_type` 的 12 個內部類型被寫成「依內容（payload）決定 constructor」，但 `PaidMessagesPrice`（74）是依聊天是不是廣播頻道決定。
2. Example「every internal content type has its type and name」寫「each has the `type` of TDLib mode」，而 TDLib 模式對單一表情的文字（`messageAnimatedEmoji`，#124）與照片為空的 `Photo`（`messageExpiredPhoto`）會回 `other`，讀取器仍回 `text`、`photo`。

另外兩個帶 spec-example 標記的測試沒有完整做到 Example：每種類型的測試沒有解碼內部編號 0 的記錄，分頁測試沒有逐頁比對。

## Root Cause

第一個 change 撰寫時把 12 個類型的原因一律寫成 payload，並把具名類型的對應寫成與 TDLib 模式全等；測試在編號 0 用了讀不出文字的記錄而改走捷徑，分頁測試只比對串接後的結果。

## Proposed Solution

- 修改 requirement「Reader answers five tools with the TDLib-mode JSON fields」：寫明 74 依聊天種類決定、其餘 11 個依內容決定；寫明 TDLib 模式對 `Text`、`Photo` 可能給 `other`，讀取器以內部類型回報。Example 的 THEN 改為直接列出對應，不宣稱與 TDLib 模式全等。行為不變。
- 每種類型的測試對編號 0 解碼一筆真的文字記錄；分頁測試逐頁斷言 `[7340032]`、`[6291456]`、`[5242880]`、`[]`。
- `TDLibContentTypeNames.swift` 註解、README、CHANGELOG 同步改寫（README 另修正「deleted chat photo」誤列與與 TDLib 模式全等的說法；CHANGELOG 修正 v0.8.0 寫的區塊不會被升級）。

## Non-Goals

- 不為 74 查聊天種類來給出名稱（解碼訊息時不讀聊天資料）。
- 不改任何程式行為。

## Success Criteria

- `spec-change.py links` 對 change 範圍回 `ok`；兩個測試在改之前的版本對應的錯誤情況會失敗（分頁測試在忽略 `limit` 時失敗），改之後通過。

## Impact

- Affected code:
  - Modified: che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibContentTypeNames.swift（註解）, che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderContentTypeTests.swift, che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift, che-telegram-all-mcp/README.md, che-telegram-all-mcp/CHANGELOG.md
  - New: (none)
  - Removed: (none)
- Affected specs: telegram-local-reader（修改 requirement「Reader answers five tools with the TDLib-mode JSON fields」的文字與一個 Example）
