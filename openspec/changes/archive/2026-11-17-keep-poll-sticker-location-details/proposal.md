## Why

`dump_chat_to_markdown` 與 `archive_chat_to_markdown` 把投票、貼圖、位置訊息寫成光禿禿的 `[poll]`、`[sticker]`、`[location]`，丟掉訊息本身帶的內容；同一則訊息在 `get_chat_history` 裡看得到投票問題、貼圖的 emoji 與座標（PsychQuant/che-msg#82）。兩個 writer 各有一份 renderer（`MarkdownExporter.messageBody` 與 `ArchiveDayFile.body`），都只讀 `text` 與 `caption`。對歸檔來說這不只是外觀：合併規則不改寫已經寫好的區塊，今天歸檔的投票就永遠是 `[poll]`，而歸檔是之後要搜尋、引用的長期紀錄（#80）。

訊息 JSON 也少一樣東西：`messageToDict` 有投票的 `question`，沒有選項，雖然 TDLibKit 的 `Poll.options[].text` 有。

## What Changes

- `messageToDict` 為投票多輸出 `options`：每個選項的文字，依投票裡的順序。`get_chat_history`、`search_messages` 等回傳訊息 JSON 的工具都看得到。
- 新增一個兩個 writer 共用的 renderer（`MessageBody`）。非文字訊息的「細節」定義一次：投票是問題，後面每個選項一行 `- <選項>`；貼圖是 emoji；位置是 `<緯度>,<經度>`，照 TDLib 給的值、不四捨五入、不用科學記號；其他型別是說明文字（caption）。細節是空的就只寫標籤。
- dump 與 archive 都呼叫它：dump 寫成 `[poll] 午餐？`、`[sticker] 😀`、`[location] 25.0478,121.5319`；archive 寫成 `[poll] 午餐？`、`[sticker](media/<id>/) 😀`、`[location] 25.0478,121.5319`。兩邊的標籤維持各自現在的樣子（dump 的 `[voice]`、archive 的 `[voice_note](media/<id>/)`）。
- `TelegramAllLib`：`ArchiveDayFile.body(type:text:caption:messageId:)` 改為 `ArchiveDayFile.body(of:messageId:)`，直接收訊息 JSON。
- 兩份 spec 用同一段文字描述細節的規則；`telegram-history-export` 另外寫明訊息 JSON 帶哪些細節欄位。

## Non-Goals

- 不替 `other` 型別（聯絡人、地點、骰子……）取更具體的標籤，`messageToDict` 也不輸出內容型別名稱（#82 Open question 1 的預設）。
- 不改寫已經寫好的區塊：v0.8.0 寫成 `[poll]` 的區塊照舊（只往前生效，Open question 3 的預設）。
- 本機快取讀出的訊息沒有這些細節（`LocalMessage` 只有 `text`），dump 與歸檔照舊是光禿禿的標籤；不擴充本機快取的解碼。
- 不輸出投票的票數、是否匿名、測驗的正確答案。
- dump 不像 archive 那樣替看起來像區塊標頭的行加反斜線（與文字、說明文字現況相同）。

## Defaults chosen while the maintainer was away

#82 的 Diagnosis 留了五個 Open questions；維護者不在，以下照 Diagnosis 的預設選項，並記在 design 與 commit message：

| 問題 | 採用的預設 |
|------|------------|
| Q1 兩個 writer 保留哪些細節 | 投票的問題與選項、貼圖 emoji、位置座標；`other` 照舊是 `[other]` |
| Q2 座標精度 | 照 TDLib 給的值，不四捨五入 |
| Q3 v0.8.0 已寫的 `[poll]`／`[sticker]`／`[location]` 區塊 | 只往前生效，不提供修補路徑 |
| Q4 兩個 writer 共用一個 renderer | 共用 |
| Q5 與 #70 的先後 | #70 先（已在本分支） |

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `telegram-history-export`：修改「Markdown output format」（非文字訊息的細節、本機快取沒有細節），新增「Message objects carry poll, sticker and location details」（訊息 JSON 的 `question`、`options`、`emoji`、`latitude`、`longitude`）。
- `telegram-chat-archive`：修改「Day file format」（區塊內文帶細節，與 dump 同一段規則；已寫的區塊與本機快取照舊）。

## Impact

- 受影響的 spec：`telegram-history-export`、`telegram-chat-archive`
- 程式：`che-telegram-all-mcp/Sources/TelegramAllLib/MessageBody.swift`（新）、`che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift`（`messageToDict` 的內容欄位抽成 `messageContentFields`，加 `options`）、`che-telegram-all-mcp/Sources/TelegramAllLib/MarkdownExporter.swift`（`messageBody`）、`che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift`（`body(of:messageId:)`）、`che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift`（`write`）
- 測試：`che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageBodyTests.swift`（新）、`MessageMediaFileTests.swift`、`MarkdownFormatTests.swift`、`ArchiveDayFileTests.swift`、`ChatArchiverTests.swift`、`LocalCacheArchiveTests.swift`
- 文件：`che-telegram-all-mcp/README.md`（dump 範例、歸檔區塊、本機快取那一句）、`che-telegram-all-mcp/CHANGELOG.md`
- 相容性：日檔格式只有內文的文字變了，舊 binary 讀新日檔照舊把區塊當不透明文字原樣保留；讀訊息 JSON 的呼叫端多一個 `options` 欄位。
