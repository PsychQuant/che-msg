## Context

非文字訊息的內文現在有兩份寫法：

- `MarkdownExporter.messageBody(_:)`（dump）：依 `type` 回傳 `[photo]`、`[voice]`、`[poll]`……，後面接 `caption`（#70）。
- `ArchiveDayFile.body(type:text:caption:messageId:)`（archive）：有檔案的型別寫 `[<type>](media/<id>/)`，其他寫 `[<type>]`，後面接 caption。`ChatArchiver.write` 只把 `text` 與 `caption` 交給它。

兩份都只讀 `text` 與 `caption`。訊息 JSON（`TDLibClient.messageToDict`）對投票有 `question`、貼圖有 `emoji`、位置有 `latitude`／`longitude`，但沒有投票選項。本機快取的 `LocalMessage.dictionary` 只有 `text`，任何細節都沒有。

## Goals / Non-Goals

**Goals:**

- 投票、貼圖、位置的細節在 dump 與 archive 都寫出來，規則只定義一次。
- 訊息 JSON 帶投票選項。

**Non-Goals:**

- `other` 型別的標籤、內容型別名稱。
- 修補已經寫好的區塊。
- 本機快取的細節解碼。
- dump 的標頭形狀跳脫。

## Decisions

### 預設選項（維護者不在時採用）

#82 Q1 保留投票問題與選項、貼圖 emoji、位置座標，`other` 不改；Q2 座標不四捨五入；Q3 只往前生效；Q4 共用一個 renderer；Q5 #70 先（已在本分支，commit `4a07b4c`）。每一項都是 Diagnosis 的預設；下面只寫實作上的決定。

### 共用的是「細節」，標籤各自保留

`MessageBody.render(_ message:placeholder:)` 收訊息 JSON 與 writer 自己算好的標籤：文字訊息回傳 `text`；其他訊息回傳「標籤 + 空白 + 行內細節」（沒有行內細節就只有標籤），投票再接每個選項一行。dump 傳 `[voice]` 這類標籤，archive 傳 `[voice_note](media/<id>/)` 或 `[location]`。

標籤不合併：dump 的 `[voice]` 是 `telegram-history-export` 釘住的輸出，archive 的 `[voice_note](media/<id>/)` 已經寫進使用者的日檔、而且帶媒體連結（dump 沒有媒體目錄）。統一任何一邊都會改到已經發布的格式；Diagnosis 的第 3 點指出這是共用 renderer 的代價，這裡選擇只共用細節，代價因此不發生。兩份 spec 用逐字相同的一段文字描述細節，日後改規則只要改 `MessageBody` 與這段文字。

替代方案：`render` 也負責標籤（傳入 `.dump`／`.archive(id)`）。標籤表會跟著搬進共用檔案，但兩張表本來就不同，搬過去只是把兩份 switch 放在一起，捨棄。

### 細節的格式

| 型別 | 行內細節 | 之後的行 |
|------|----------|----------|
| `poll` | `question`（換行保留，與 caption 相同） | 每個非空選項一行 `- <選項>`，選項內的換行寫成空白 |
| `sticker` | `emoji` | — |
| `location` | `<latitude>,<longitude>`，兩個都是有限的數字才寫 | — |
| 其他非文字型別 | `caption` | — |

- 選項一行一個，而不是 `（A / B）` 這類行內分隔：分隔符可能出現在選項文字裡；一行一個在 Markdown 裡就是清單，#80 的搜尋也能逐行比對。選項的換行換成空白，確保「一行一個選項」不會被打破（TDLib 規定選項 1–100 字，實際上不會有換行）。
- archive 的 `ArchiveDayFile.block` 照舊對每一行內文做跳脫：問題裡以 `<!--` 開頭或像區塊標頭的行會加反斜線；選項行以 `- ` 開頭，不會被誤認。
- 座標用 Swift `Double` 的最短還原表示（`"\(value)"`，能還原成同一個 `Double` 的最少位數），也就是 TDLib 給的值、不四捨五入。這個表示對絕對值小於 1e-4 的數會用科學記號（`1e-05`），`MessageBody.plainDecimal(_:)` 把它改寫成一般小數（`0.00001`），只移動小數點、不改位數。`-0.0` 照寫。
- 細節是空字串、欄位不存在、型別不對（例如 `options` 不是字串陣列）時當作沒有，只寫標籤。這正是本機快取的情況：`LocalMessage.dictionary` 沒有這些欄位，寫出來就是光禿禿的標籤，不必另外判斷來源。

### `messageToDict` 的內容欄位抽成 `messageContentFields`

`messageToDict` 是 `TDLibClient` 的 instance method，測試要建 client 才能呼叫。把 `switch msg.content` 那一段抽成和 `mediaFileInfo(_:)` 並列的 internal 函式 `messageContentFields(_ content: MessageContent) -> [String: Any]`，`messageToDict` 合併它的結果；測試直接用 TDLibKit 的 model 建 `MessagePoll`。`options` 是 `poll.options.map { $0.text.text }`，只取文字（選項的 entities 只允許 custom emoji，純文字已足夠）。

### `ArchiveDayFile.body` 收整個訊息

`body(of message: [String: Any], messageId: Int64)` 取代 `body(type:text:caption:messageId:)`：要的欄位依型別而不同，逐一當參數傳會讓簽名跟著每種型別長。`messageId` 仍是參數（連結要用，`ChatArchiver` 已經解好）。這是 `TelegramAllLib` 的 public API 變更，CHANGELOG 記一筆；套件內只有 `ChatArchiver` 呼叫它。

## Risks / Trade-offs

- [位置是寄件人的精確位置，寫進長期保存的歸檔] → 照 Q2 的預設不降精度；README 的隱私段落本來就說歸檔是別人的訊息原文、不要上傳，位置一併適用。
- [投票問題與 emoji 是第三方文字，dump 可能被貼到別處] → 與文字、說明文字相同的處境，不另外處理。
- [已經寫成 `[poll]` 的區塊不會補上] → README 與 CHANGELOG 寫明只往前生效；#72 的升級只處理本機快取寫的區塊。
- [舊 binary 讀到新日檔] → 內文只是文字，舊 binary 照舊原樣保留區塊，沒有格式相容性問題。

## Implementation Contract

- **行為**：
  - TDLib 模式下，投票訊息的 JSON 有 `question` 與 `options`（選項文字的陣列，依投票順序）；貼圖有 `emoji`；位置有 `latitude`、`longitude`。
  - dump：投票寫成 `[poll] <問題>`，之後每個選項一行 `- <選項>`；貼圖 `[sticker] <emoji>`；位置 `[location] <緯度>,<經度>`；其他非文字型別照舊是標籤加 caption。
  - archive：同樣的細節接在 `[poll]`、`[sticker](media/<id>/)`、`[location]` 之後。
  - 細節不存在或是空的，只寫標籤；本機快取讀出的訊息因此照舊是光禿禿的標籤。已經寫好的區塊不改。
- **介面**：
  - `TelegramAllLib` 新增 internal `enum MessageBody`：`render(_ message: [String: Any], placeholder: String) -> String`、`detail(of message: [String: Any]) -> (inline: String?, lines: [String])`、`plainDecimal(_ value: Double) -> String`。
  - internal `messageContentFields(_ content: MessageContent) -> [String: Any]`，`messageToDict` 用它。
  - `ArchiveDayFile.body(of message: [String: Any], messageId: Int64) -> String`（public）取代 `body(type:text:caption:messageId:)`。
  - `messageBody(_:)`（dump）改為呼叫 `MessageBody.render`，標籤表不變。
- **錯誤與邊界**：緯度或經度缺一、不是數字、不是有限值時，位置沒有細節。投票沒有問題但有選項時寫 `[poll]` 後接選項行。空選項略過。文字訊息與有 caption 的媒體輸出與現在逐字相同。
- **驗收**：`MessageBodyTests`（三種細節、空細節、科學記號改寫、文字與 caption 不變、`other`）、`MessageMediaFileTests`（`messageContentFields` 的 `question`、`options`、座標）、`MarkdownFormatTests`（dump 的三種內文）、`ArchiveDayFileTests`（`body(of:messageId:)`、問題裡像區塊標頭的行被跳脫）、`ChatArchiverTests`（日檔裡的投票、貼圖、位置區塊）、`LocalCacheArchiveTests`（本機快取的投票是 `[poll]`）；`swift test --skip E2ETests` 全過。
- **範圍外**：`other` 的標籤、修補舊區塊、本機快取解碼、票數與測驗答案、dump 的跳脫。
