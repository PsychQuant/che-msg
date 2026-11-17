## Context

快取讀取器在 `TDLibMessageDecoder.readContent` 讀到內部 `MessageContentType` 編號後，交給 `kind(forContentType:)` 轉成 `LocalMessage.Kind`；編號本身不保留。TDLib 模式的 `other` 由 #117 加上 `content_type`（TDLibKit enum 的 case 名稱）。快取沒有 TDLibKit 物件，只有內部編號，所以要一張從內部編號到 API constructor 名稱的表。表的內容逐一讀自 TDLib `cb863c16`（套件鎖定的版本）`td/telegram/MessageContent.cpp` 的 `get_message_content_object`，`Invoice` 另看 `InputInvoice::get_message_invoice_object`，`TopicEdit` 另看 `ForumTopicEditedData::get_edited_data_message_content_object`。

## Goals / Non-Goals

**Goals:**

- 快取回答的 `other` 在 TDLib 只給一種 constructor 時帶 `content_type`，名稱與 TDLib 模式相同。
- 音訊在快取回答裡是 `audio`。

**Non-Goals:**

- 解碼依內容決定 constructor 的 12 個編號的內容。
- 為 `other` 加 `content_type` 以外的欄位。
- 處理 `Text` 與 `Photo` 這兩個已對到具名類型、但 TDLib 偶爾給第二種 constructor 的編號（#124）。

## Decisions

### 依內容決定 constructor 的內部類型省略 content_type

12 個編號（13、17、30、41、43、50、51、53、66、72、74、82）的 constructor 取決於內容，讀取器不解碼內容，所以不寫 `content_type`。另一個選項是逐一解碼這 12 種內容的序列化；它要為每一種寫解析器，且 TDLib 版本一變就要重核。省略與 spec「判斷不出的欄位省略」一致，之後要補不必改欄位意義。這是維護者不在時取的預設（issue #118 的 Choice Default Record）。

### 名稱表放在獨立檔案，解碼器只記結果

`TDLibContentTypeNames.swift` 放一個函式 `TDLibContentTypeNames.apiName(forContentType:) -> String?`，以 switch 列出 62 個編號；其他編號（具名類型、12 個依內容決定的、範圍外）回 nil。解碼器在種類是 `other` 時呼叫它，把結果放進 `Record.contentType` 與 `LocalMessage.contentType`。不把內部編號存在 `LocalMessage` 再於 `dictionary` 轉名稱：`LocalMessage` 是 JSON 的形狀，存結果比存原料清楚。

### 音訊是具名類型

`LocalMessage.Kind` 加 `audio`（raw value `audio`），`kind(forContentType:)` 把 2 對到它。dump 已把 `audio` 寫成 `[audio]`，歸檔的 `ArchiveDayFile.fileTypes` 已含 `audio`，兩者不用改程式。

## Implementation Contract

- **Behavior**：快取回答（`get_chat_history`、`search_messages`、`get_chats`／`search_chats` 的 `last_message`）裡，內部編號 2 的訊息是 `"type":"audio"`；`type` 為 `other` 的訊息在名稱表有值時多一個 `"content_type":"<constructor>"`，沒有值時不出現這個鍵。具名類型的訊息從不帶 `content_type`。快取 dump 把音訊寫成 `[audio]`；快取歸檔把音訊寫成 `[audio](media/<id>/)` 並算進 `media_pending_local_cache`。
- **Interface / data shape**：`LocalMessage` 新增 `let contentType: String?`（預設 nil 的初始化參數，既有呼叫端不必改）；`LocalMessage.Kind` 新增 `audio`；`TDLibMessageDecoder.Record` 新增 `contentType: String?`；新增 `enum TDLibContentTypeNames { static func apiName(forContentType: Int32) -> String? }`。
- **Failure modes**：表沒有值時安靜省略欄位（不是錯誤）。超過 85 的編號照舊讓解碼停在內容之前、類型為 `unknown`。
- **Acceptance criteria**：`LocalReaderContentTypeTests` 對 0…85 每個編號斷言種類與名稱（含 12 個 nil、具名類型沒有名稱）；聯絡人、骰子、音訊的 JSON 物件與 spec Example 相同；快取 dump 寫出 `[audio]`；快取歸檔的音訊區塊與 `media_pending_local_cache`。全部在 `swift test --skip E2ETests` 下通過。
- **Scope boundaries**：只改 `LocalReader/` 底下的解碼與模型、對應測試、README 與 CHANGELOG。不碰 `TDLibClient.messageToDict`（#117 的範圍）、`MarkdownExporter`、`ChatArchiver`。

## Risks / Trade-offs

- [手抄 62 列的表抄錯一列，名稱就靜默地錯] → 表逐一讀自鎖定版本的原始碼，測試列出每一個編號的預期名稱，與原始碼對照時一列一列比。
- [TDLib 升版改了編號或 constructor] → 解碼器只接受 1.8.60 的記錄版本與 0…85 的編號；升版時這張表和 `newestContentType` 一起重核。
- [#117 與本 change 都改 README 與 CHANGELOG] → 後合併的那一個改寫 #117 README 裡「快取回答還沒有 `content_type`（#118）」那句。
