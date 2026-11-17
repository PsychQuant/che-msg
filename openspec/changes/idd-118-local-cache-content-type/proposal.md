## Problem

另一個程序持有 TDLib 時，`get_chat_history`、`search_messages`、`get_chats`／`search_chats` 的 `last_message`、`dump_chat_to_markdown` 與 `archive_chat_to_markdown` 都從 TDLib 的本機快取回答（`LocalTDLibReader`）。這條路徑有兩個與 TDLib 模式不一致的地方（PsychQuant/che-msg#118）：

1. 本機讀取器表外的訊息一律回 `"type": "other"`，沒有任何欄位說明是哪一種內容。#117 讓 TDLib 模式的 `other` 帶 `content_type`（TDLib API 的 constructor 名稱）；快取回答沒有，所以代理看不看得到 `content_type`，取決於哪個程序持有 TDLib。
2. 音訊訊息在快取回答裡是 `other`、在 TDLib 模式是 `audio`；dump 寫成 `[other]`，歸檔沒有 `media/<id>/` 連結，也不算進 `media_pending_local_cache`。

## Root Cause

`TDLibMessageDecoder.kind(forContentType:)` 從 `messages.data` 讀出 TDLib 內部的 `MessageContentType` 編號，只列出 0、1、3、4、5、6、7、9、31、35、40，其餘 0…85 全部變成 `.other`；內部編號 2（`Audio`）不在表裡，`LocalMessage.Kind` 也沒有 `audio`。`LocalMessage` 只保留 `Kind`，編號在這一步就丟了，`dictionary` 之後無從寫出內容種類。

## Proposed Solution

- `LocalMessage.Kind` 新增 `audio`；內部編號 2 對到 `audio`。
- 新檔 `TDLibContentTypeNames.swift`：一張封閉的表，把內部編號對到 TDLib API constructor 名稱，內容逐一讀自 TDLib `cb863c16` 的 `get_message_content_object`（`td/telegram/MessageContent.cpp`）。只回傳一個 constructor 的 62 個編號給名稱；依內容決定 constructor 的 12 個編號（13、17、30、41、43、50、51、53、66、72、74、82）回 nil。
- 解碼器在種類是 `other` 時把名稱記在 `Record` 與 `LocalMessage` 的 `contentType`；`dictionary` 在它不是 nil 時寫 `content_type`。名稱不明（那 12 個編號）就不寫，照 spec 既有的「讀取器判斷不出的欄位省略」。
- spec `telegram-local-reader` 的訊息欄位清單加上 `content_type`。
- README 裡說快取的音訊讀成 `[other]` 的句子改寫；CHANGELOG `## [Unreleased]` 記一筆。

ASSUMPTION: 依內容決定 constructor 的 12 個編號省略 `content_type`，不解碼各自的內容（Diagnosis 的 Choice Default Record；維護者不在時取的預設）。之後要補，可在同一欄位上做，不改欄位意義。

## Non-Goals

- 不解碼那 12 個編號的內容，也不為 `other` 加 `content_type` 以外的欄位（#117 在 TDLib 模式為七種內容加的細節欄位，快取讀取器讀不到）。
- 不處理單一表情的文字在 TDLib 模式可能變成 `messageAnimatedEmoji` 的差異（#124）。
- 不改 dump 與歸檔的 `[other]` 標籤（它們不讀 `content_type`）。
- 不依賴 #117 的程式碼；欄位名稱與 constructor 名稱與 #117 相同，兩者合併後一致。

## Success Criteria

- 快取裡一則聯絡人訊息（內部編號 8）的 JSON 物件是 `type: "other"` 且 `content_type: "messageContact"`。
- 快取裡一則骰子訊息（內部編號 41）是 `type: "other"`，沒有 `content_type`。
- 快取裡一則音訊訊息（內部編號 2）是 `type: "audio"`，沒有 `content_type`；從快取 dump 時寫成 `[audio]`。
- 0…85 每個編號都有測試對到預期的種類與名稱。

## Impact

- Affected code:
  - Modified: che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibMessageDecoder.swift, che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalMessage.swift, che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderMessageDecodingTests.swift, che-telegram-all-mcp/README.md, che-telegram-all-mcp/CHANGELOG.md
  - New: che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibContentTypeNames.swift, che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderContentTypeTests.swift
  - Removed: (none)
- Affected specs: telegram-local-reader（修改 requirement「Reader answers five tools with the TDLib-mode JSON fields」）；telegram-chat-archive（修改 requirement「Archive from the local cache」：括號裡「讀取器給不出 `audio` 類型」不再成立，並加上快取音訊算待下載媒體的情境）
