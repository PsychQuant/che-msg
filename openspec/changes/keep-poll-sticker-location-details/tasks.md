## 1. 訊息 JSON 的投票選項

- [x] 1.1 先寫失敗的測試（Requirement: Message objects carry poll, sticker and location details 的 Scenario: Poll options in the message JSON 與 Scenario: Location in the message JSON）：`messageContentFields(.messagePoll(...))` 有 `type: poll`、`question` 與依序的 `options`（一般投票與測驗都有），`messageContentFields(.messageLocation(...))` 有 `latitude`、`longitude`，回傳的字典沒有票數。驗證：`swift test --filter MessageMediaFileTests` 先失敗（`messageContentFields` 還不存在）
- [x] 1.2 依設計「`messageToDict` 的內容欄位抽成 `messageContentFields`」把 `switch msg.content` 抽成 internal 函式並加上 `options`，`messageToDict` 合併它的結果。驗證：1.1 的測試與既有的 `MessageMediaFileTests` 通過 [after: 1.1]

## 2. 共用的 renderer

- [x] 2.1 先寫失敗的測試（Requirement: Markdown output format 的 Scenario: Poll with its options、Sticker and location details、Coordinate near zero；Requirement: Day file format 的 Scenario: Media type without a file、Poll with its options、Sticker with its emoji、Poll question that looks like a block header、Poll archived from the local cache）：`MessageBodyTests` 涵蓋投票（有選項、沒選項、沒問題只有選項、空選項略過、選項內換行成空白、問題內換行保留）、貼圖（有 emoji、空 emoji）、位置（一般座標、`0.00001`、缺一個座標、非數字）、`plainDecimal`（`1e-05`、`1.5e-07`、`25.0`、`-0.5`）、文字與 caption 輸出不變、`other` 只有標籤；`MarkdownFormatTests` 檢查 dump 的三種內文；`ArchiveDayFileTests` 的 `body(of:messageId:)` 對每種型別給出連結與細節、像區塊標頭的問題行被跳脫；`ChatArchiverTests` 的日檔裡有投票、貼圖、位置區塊；`LocalCacheArchiveTests` 的本機快取投票是 `[poll]`。驗證：`swift test --filter MessageBodyTests`、`--filter MarkdownFormatTests`、`--filter ArchiveDayFileTests`、`--filter ChatArchiverTests`、`--filter LocalCacheArchiveTests` 先失敗 [after: 1.2]
- [x] 2.2 依設計「共用的是『細節』，標籤各自保留」與「細節的格式」實作 `MessageBody`（`render`、`detail(of:)`、`plainDecimal`）；`messageBody(_:)` 改呼叫 `MessageBody.render`；依設計「`ArchiveDayFile.body` 收整個訊息」以 `body(of:messageId:)` 取代 `body(type:text:caption:messageId:)`，`ChatArchiver.write` 傳整個訊息。驗證：2.1 的測試通過，既有的 caption 與標籤測試照舊通過（Scenario: Caption kept、Media without a caption、Block written before details were kept） [after: 2.1]

## 3. 文件

- [ ] 3.1 all-mcp README：dump 範例加一則投票與一則位置，說明細節的寫法與本機快取沒有細節；歸檔段落說明區塊內文帶細節、已寫好的區塊不補（只往前生效）。CHANGELOG `[Unreleased]` 記 #82（含 `options` 欄位與 `ArchiveDayFile.body(of:messageId:)` 的 API 變更，並依設計「預設選項（維護者不在時採用）」寫明 `other` 不改、座標不四捨五入、只往前生效是維護者不在時採用的預設）。驗證：人工核對 README 的範例與 `MessageBodyTests` 的期望輸出一致；`swift test --skip E2ETests` 全過 [after: 2.2]
