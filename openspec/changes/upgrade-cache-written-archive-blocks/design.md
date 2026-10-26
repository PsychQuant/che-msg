## Context

`ArchiveDayFile.merged(existing:...)` 把舊日檔切成區塊（`split`：一行恰為 `<!-- msg:<digits> -->` 才算區塊開頭，`anchorId` 要求 id 後面直接接 ` -->`），每個舊區塊原樣保留，只在 `blocks[message.id] == nil` 時加新區塊；`write` 在沒有新增時不動檔案，否則以 0600 的暫存檔 rename 取代。`ChatArchiver` 有 `sourceKind`（`tdlib`／`localCache`），但沒有交給 `ArchiveDayFile`；`write(_:...)` 只把 `added` 算進 `newMessages`、`mediaMessages` 與 `files`。

本機快取寫的區塊少了名稱、說明文字、#82 的細節與音訊型別；快取的呼叫一定 `bookmark_safe: false`，所以下一次 TDLib 的呼叫會從舊書籤再走一次同一段範圍，只是合併規則不讓它改。

## Goals / Non-Goals

**Goals:**

- 快取寫的區塊被標記，之後 TDLib 的呼叫把它們換成完整版本。
- 舊 binary、skill 的錨點核對、#80 的搜尋都不必改就能讀帶標記的日檔。
- 沒有東西可升級時，重跑仍位元組不變。

**Non-Goals:**

- `refresh` 參數、移除快取路徑、猜測 v0.8.0 的快取區塊、反映編輯與刪除、快取解碼。

## Decisions

### 預設選項（維護者不在時採用）

#72 Q1 採標記並升級（建議選項），Q2 不加 `refresh` 參數。兩項都是 Diagnosis 的建議或預設。下面寫實作上的決定。

### 標記在錨點之後自己的一行，恰為 `<!-- provisional: local-cache -->`

Diagnosis 第 1 點：issue 原本提議把標記放進錨點（`<!-- msg:<id> provisional -->`），但 v0.8.0 的 `anchorId` 不認這種行，會把區塊黏到前一個區塊上、再把訊息當成新區塊加一次，安靜地重複。plugin 與 binary 分開更新（wrapper 的 pin 與已安裝的 binary），新日檔遇到舊 binary 是實際會發生的事。放在錨點之後自己的一行，錨點完全不變：

- 舊 binary 把整個區塊當不透明文字原樣保留，和現在一樣。
- skill 的結尾核對（`^<!-- msg:<id> -->$`）不必改。
- #80 的搜尋從錨點切區塊，看第二行就知道是不是暫時的。

內文以 `<!--` 開頭的行本來就會加反斜線（`ArchiveDayFile.block`），而第二行永遠是工具寫的（標頭或標記），所以訊息文字偽造不了標記。判斷一個區塊是否帶標記只看它的第二行是否恰為這個字串，不看其他位置。

替代方案：在 frontmatter 記一份暫時區塊的 id 清單。要讀寫兩處、兩處可能不一致，而且 #80 要另外解析 frontmatter，捨棄。

### 升級：TDLib 換掉帶標記的區塊，快取不換任何區塊

`merged` 多一個參數 `provisional: Bool`（這批訊息是否來自本機快取）：

| 舊區塊 | `provisional` | 結果 |
|--------|---------------|------|
| 沒有 | false | 加入，不帶標記（`added`） |
| 沒有 | true | 加入，帶標記（`added`） |
| 帶標記 | false | 換成這則訊息現在的區塊，不帶標記（`upgraded`） |
| 帶標記 | true | 原樣保留 |
| 不帶標記 | 任一 | 原樣保留 |

快取的呼叫不換帶標記的區塊：兩次快取讀出的內容一樣，換了也不會更好，反而破壞「重跑位元組不變」。`write` 在 `added` 與 `upgraded` 都是空的時候不動檔案；有升級時走同一條暫存檔 → 0600 → rename 的路徑。升級後的區塊不帶標記，所以第二次 TDLib 呼叫沒有東西可換，檔案位元組不變。

帶標記的區塊屬於工具：升級換掉整個區塊，使用者手動加在裡面的內容會消失。spec 寫明這點；沒有標記的區塊照舊一字不動。

### manifest：`upgraded_messages`，`files` 含升級的日檔

Diagnosis 第 3 點：`new_messages`、`media_messages`、`newest_message_file` 與書籤的意義不能因為升級而改變。所以升級另外計數，`upgraded_messages` 一律出現（0 也寫，和 `undated_messages_skipped` 一樣）。`files` 的定義從「加了訊息的日檔」改成「加了訊息或升級了區塊的日檔」：skill 的結尾核對檢查 `files` 裡每個檔案存在、frontmatter 是這個聊天的，被重寫過的日檔正是需要這項檢查的檔案。舊 skill 配新 binary 時，多出來的檔案一樣會通過核對（它們本來就是有效的日檔）。

### 介面

- `ArchiveDayFile.provisionalMarker`（public static let）是標記字串，測試與文件都引用它。
- `block(_:offsetSeconds:provisional:)` 的新參數預設 false；`provisional` 時在錨點行之後插入標記行。
- `isProvisional(_ blockText:)`（internal）：第二行恰為標記。
- `merged(...provisional:)` 回傳 `(content, added, upgraded)`；`write(...provisional:)` 回傳 `(added, upgraded)`，仍是 `@discardableResult`。兩者都是 `TelegramAllLib` 的 public API 變更（回傳值多一個欄位），CHANGELOG 記一筆；套件內只有 `ChatArchiver` 呼叫 `write`。
- `ChatArchiver` 以 `provisional: sourceKind == .localCache` 呼叫 `write`，`Result.upgradedMessages` 累加 `upgraded.count`，有升級的日檔也放進 `files`。

### skill 與文件

- Step 3：`tdlib_in_use` 仍預設停止（快取路徑不下載媒體，而且寫出的區塊要等之後 TDLib 跑才會完整）；理由改寫成「暫時的、之後會換掉」，不再說「不會改寫」。
- Step 5：錨點核對不變；`files` 多了升級的日檔，照常核對。
- Step 6：`last_run` 加 `upgraded_messages`（manifest 沒有時記 0）。
- Step 7：報告在 `upgraded_messages` 大於 0 時寫出升級幾則；`local-cache` 那一列改寫成「之後透過 TDLib 跑同一段範圍時會換成完整版本」。
- 工具說明（`Server.swift`）與兩份 README 同步。

## Risks / Trade-offs

- [使用者在帶標記的區塊裡手動加的筆記，升級時會消失] → spec 與 README 寫明帶標記的區塊屬於工具；沒有標記的區塊不受影響。
- [升級寫的是 TDLib 當下的訊息，可能和快取讀到時不同（編輯過）] → 和第一次就透過 TDLib 歸檔的結果相同；歸檔本來就不追蹤編輯。
- [快取給的日期和 TDLib 不同時，TDLib 的訊息會落到另一天的日檔，原本那一天的暫時區塊不會被升級] → 兩者讀的是同一筆紀錄的 `date`，實際上不會發生；發生時是多一個區塊而不是遺失，訊息仍找得到。
- [舊 binary 透過 TDLib 跑時不升級] → 新 binary 之後的執行會升級，標記保留到那時。
- [v0.8.0 從快取寫的區塊沒有標記，永遠不會升級] → README 與 CHANGELOG 寫明只對新寫的快取區塊有效。

## Implementation Contract

- **行為**：
  - 來源是本機快取的呼叫加入的每個區塊，第二行是 `<!-- provisional: local-cache -->`；錨點行不變。
  - 來源是 TDLib 的呼叫，把這次讀到的訊息中帶標記的區塊換成不帶標記的現行寫法，並計入 `upgraded_messages`；不帶標記的區塊不動；來源是本機快取的呼叫不換任何區塊。
  - 沒有新增也沒有升級的日檔不寫；升級後的檔案仍是 0600、以暫存檔 rename 取代。
  - manifest 一律有 `upgraded_messages`；`files` 含有升級的日檔；`new_messages`、`media_messages`、書籤規則不變。
  - 內文行恰為標記字串時照舊加反斜線，不會被當成標記。
- **介面**：`ArchiveDayFile.provisionalMarker`；`ArchiveDayFile.block(_:offsetSeconds:provisional:)`；`ArchiveDayFile.isProvisional(_:)`（internal）；`ArchiveDayFile.merged(existing:chatId:day:utcOffset:messages:provisional:) -> (content: String, added: [Int64], upgraded: [Int64])`；`ArchiveDayFile.write(directory:chatId:day:utcOffset:messages:provisional:) -> (added: [Int64], upgraded: [Int64])`；`ChatArchiver.Result.upgradedMessages: Int`，manifest 鍵 `upgraded_messages`。
- **錯誤與邊界**：錯誤處理（offset、不是一般檔案、CR）與現在相同，升級前就會拒絕。同一批訊息裡同一個 id 出現兩次時只處理第一次。標記只認第二行；標記出現在其他位置的區塊不是暫時的。
- **驗收**：`ArchiveDayFileTests`（快取區塊的第二行是標記、`parseBlocks` 的 id 不因標記改變、TDLib 合併換掉帶標記的區塊、快取合併不換、不帶標記與 preamble 位元組不變、偽造的標記行被跳脫、升級後再寫一次位元組不變、升級後 0600）、`ChatArchiverTests`（TDLib 呼叫在快取呼叫之後升級：名稱、說明文字、`upgraded_messages`、`files`；快取呼叫在 TDLib 呼叫之後位元組不變；manifest 一般情況 `upgraded_messages: 0`）、`LocalCacheArchiveTests`（快取呼叫寫出標記）；`swift test --skip E2ETests` 全過；`tests/che-telegram-mcp/*.sh` 全過。
- **範圍外**：`refresh` 參數、移除快取路徑、猜測 v0.8.0 的快取區塊、編輯與刪除、快取解碼。
