## Context

`TDLibClient`（`TelegramAllLib`）是 MCP server 與 `telegram-all` CLI 共用的 TDLib 包裝。#64 之後每個請求都經過 `openClient`（先檢查 client 沒有被 TDLib 關閉），一個讀原始碼的測試（`TDLibClosedClientTests`）確認沒有繞過它。錯誤轉換卻只有兩處：四個認證步驟的 `mapTDLibError`（406 靜默完成），以及封存檔案私用的 `archiveTDLibCall`（406 丟出、message 留空）。`TDLibClient.swift` 其餘 28 個請求讓 `TDLibKit.Error` 原樣丟出；`CheTelegramAllMCPCore` 不依賴 TDLibKit，`handleWithTDLib` 只接得住 `TDError.tdlibError`，其餘落到 `errorResultFromParse` 的 `localizedDescription`。

TDLib 只讀它認得的聊天。封存的 `loadChatForArchive` 在 `getChat` 回 400 時依 id 範圍建立聊天；#69 task 5.3 只對帳號自己的 Saved Messages 驗證過。TDLibKit（TDLib 1.8.60）的文件說 `createBasicGroupChat`／`createSupergroupChat` 回傳「a known」群組的聊天，`searchChats` 只搜尋「already known chats」（離線方法），`getChats` 不給清單時讀主清單（main chat list）。TDLib 原始碼（td 在 cb863c16）：`getChat` 對沒載入的聊天回 400「Chat not found」、對無效 id 回 400「Invalid chat identifier specified」（`MessagesManager::load_dialog`）；建立請求（`MessagesManager::create_dialog`）在 TDLib 對使用者或群組毫無資訊時回 400「Chat info not found」，有資訊但不能讀時回 400「Can't access the chat」，`force: false` 且聊天未載入時向 server 查詢。

## Goals / Non-Goals

**Goals:**

- 任何工具、任何 CLI 指令遇到 TDLib 的錯誤，都看得到 TDLib 的 code 與 message。
- 接受聊天 id 的工具對 TDLib 沒見過的聊天先試著用 id 載入；載入不了時，清楚說明下一步。
- 結構上確保新的請求不會漏掉錯誤轉換。

**Non-Goals:**

- 不改認證步驟（406 靜默完成仍只限它們）。
- 不加 `loadChats` 逐頁載入：要等實測（Diagnosis Strategy 第 1 步）。
- 不改另一個 process 持有 TDLib 時的本機快取路徑。

## Decisions

### 轉換放在 `TelegramAllLib` 的請求邊界，每個請求各自包一次

`archiveTDLibCall` 改名 `tdlibCall`，移到新檔 `TDLibRequests.swift`，四個認證步驟以外的每一個 `openClient.` 請求都寫成 `tdlibCall { try await openClient.… }`，同一行。server 接不到 `TDLibKit.Error`（沒有依賴），在 server 端修只修得到 MCP，CLI 照舊；在 client 邊界修兩邊都好。每個請求各包一次而不是整個方法包一次，是為了讓讀原始碼的測試能逐行檢查：每一行含 `openClient.` 的程式碼，不是 `tdlibCall { try await openClient.`，就是四個認證請求之一。測試掃 `Sources/TelegramAllLib` 底下所有 Swift 檔，新增的檔案也在範圍內。

替代方案是把 `openClient` 改成同時做狀態檢查與錯誤轉換的 `request { client in … }`：結構更緊，但要改 #64 的 `openClient` 與它的測試，捨棄。

### 406 在一般請求照樣丟出，message 留空

認證步驟的 406 可以當成完成（要的只是狀態前進）；讀取與寫入的呼叫端需要一個結果，靜默完成等於回一個沒有的結果。所以沿用封存的規則：丟出 `tdlibError(code: 406, message: "")`。TDLib 規定 406 的 message 不得顯示，留空即符合。

### 載入聊天：抽成可測的純函式，失敗時回報原錯誤

`loadChatForArchive` 的邏輯抽成檔案層級的泛型函式 `loadChat(_:get:createPrivateChat:createBasicGroupChat:createSupergroupChat:)`：`getChat` 與三個建立請求以閉包傳入，閉包的參數就是 TDLib 自己的參數（`force` 與 id），所以哪一種 id 送哪一個請求、`force: false`，都在純函式裡決定、可以測；`TDLibClient.knownChat(_:)` 的閉包只把參數原樣交給 `openClient`，一個讀原始碼的測試釘住這四行。每個接受聊天 id 的方法在第一個請求前、不帶條件地呼叫它（`getChat` 與 `getChatMembers` 直接用它回傳的 `Chat`；封存的 `page` 每一頁都呼叫，`getChat` 對已知聊天是本機查詢）。id 分類 `ArchiveChatID` 改名 `TDLibChatID`，移到同一個新檔，改成 failable init：不在可建立範圍的 id 回 nil。secret chat 不在範圍內是選擇：TDLib 有 `createSecretChat`，但這個 client 以 `useSecretChats: false` 開 TDLib。

失敗時依 TDLib 的回答分四種，只有一種加提示：(1) `getChat` 回 400 以外的錯誤（rate limit、session 已關閉）原樣丟出，不建立；(2) `getChat` 回 400 而 id 不在可建立範圍，原樣丟出 `getChat` 的錯誤、不加提示，因為 `get_chats` 變不出一個不存在的 id；(3) 建立請求回 400「Chat info not found」（TDLib 對這個使用者或群組毫無資訊），丟 `unknownChat`，帶 `getChat` 的錯誤（呼叫端問的是聊天），server 加提示：`get_chats` 載入主清單的聊天時會帶來它們的資訊；(4) 建立請求的其他錯誤原樣丟出、不加提示：「Can't access the chat」（已離開或被封鎖的私人 supergroup／頻道）比「Chat not found」說得更多，`get_chats` 也幫不上；rate limit 照舊讓封存等待。第一版把建立請求的每個 400 都換成「Chat not found」加提示，第 (4) 種的資訊因此不見，提示也幫不上忙。

### `unknownChat` 是 `TDError` 的新 case，server 加 `hint` 欄位

新 case `unknownChat(chatId:code:message:)` 與既有的 `sessionClosed` 一樣是 client 自己的錯誤種類；`TDError.hint` 給出提示文字（只有這個 case 有）。server 回同樣的 `type: "tdlib_error"`、`code`、`message`，外加 `hint`，既有依 `type` 與 `code` 分支的呼叫端不受影響。CLI 由 `errorDescription` 印出 code、message 與提示。替代方案是把提示接進 `message`：會改寫 TDLib 的原文，捨棄。

提示只提 `get_chats`，不提 `search_chats`：TDLib 的 `searchChats` 是只搜尋已知聊天的離線方法，對沒見過的聊天沒有幫助（issue 的 Expected 兩個都提，這裡依 TDLib 文件只留前者）。提示也說 `get_chats` 只讀主清單，在 Telegram 裡封存（archived）的聊天不會因此載入。

## Risks / Trade-offs

- [`create*Chat` 對全新資料庫上沒見過的使用者或群組回 400「Chat info not found」] → 這時工具回 `unknownChat` 與提示，行為誠實；是否需要 `loadChats` 由實測決定，結果記在 issue。
- [寫入工具在送出前先建立聊天] → 只改 TDLib 的本機狀態，不送訊息、不改聊天；spec 明寫。
- [`getChat` 的 400 不一定是「沒見過」（例如 id 0 的「Invalid chat identifier specified」）] → id 不在可建立範圍時原樣丟出 TDLib 的錯誤，不加提示。
- [依 TDLib 的訊息文字「Chat info not found」判斷] → TDLib 說訊息「subject to future changes」；TDLibKit 與 TDLibFramework 釘在 1.8.60-cb863c16，測試釘住這個字串。訊息若在升級後改變，建立請求的錯誤會原樣回報、沒有提示：少了提示，但不會誤導。
- [讀原始碼的測試依賴「一行一個請求」的寫法] → 測試的失敗訊息指出那一行，改寫成同一行即可；跨行寫法會被當成沒有轉換而失敗，方向是安全的。

## Implementation Contract

- **行為**：`TDLibClient` 的每個 TDLib 請求（`setParameters`、`sendPhoneNumber`、`sendAuthCode`、`sendPassword` 的請求除外）把 `TDLibKit.Error` 轉成 `TDError.tdlibError(code:message:)`，406 的 message 為空字串；其他錯誤原樣丟出。server 對 `tdlibError` 回 `{"type":"tdlib_error","code","message"}`，對 `unknownChat` 回同樣三個欄位加 `hint`，`isError: true`。每個接受聊天 id 的方法（`getChat`、`getChatHistory`、`searchMessages`、`sendMessage`、`editMessage`、`deleteMessages`、`forwardMessages` 的來源與目的、`getChatMembers`、`pinMessage`、`unpinMessage`、`setChatTitle`、`setChatDescription`、`addChatMember`、`markAsRead`、封存的 `page`（每一頁，不論游標）與 `message`）在第一個請求前、不帶條件地單獨一行呼叫 `knownChat`。
- **介面**：`TelegramAllLib` 新增 `internal func tdlibCall<T>(_:)`（取代 `archiveTDLibCall`）、`internal enum TDLibChatID`（`user`、`basicGroup`、`supergroup`，`init?(_ chatId: Int64)`，取代 `ArchiveChatID`）、`let tdlibChatInfoNotFound = "Chat info not found"`、`internal func loadChat<Found>(_ chatId: Int64, get:, createPrivateChat: (Bool, Int64), createBasicGroupChat: (Int64, Bool), createSupergroupChat: (Bool, Int64))`（參數順序同 TDLib）、`TDLibClient.knownChat(_:) -> Chat`（取代 `loadChatForArchive`）；`TDLibClient.TDError` 新增 `case unknownChat(chatId: Int64, code: Int, message: String)` 與 `public var hint: String?`。`CheTelegramAllMCPCore` 新增 `tdlibErrorResult(for: Error) -> CallTool.Result?`，`tdlibErrorResult(code:message:hint:)` 的 `hint` 預設 nil；`handleWithTDLib` 的 catch 改用前者。
- **錯誤與邊界**：`getChat` 回 400 以外的錯誤時不建立聊天、原樣丟出。`TDLibChatID` 為 nil 時不送建立請求，原樣丟出 `getChat` 的錯誤。建立請求回 400「Chat info not found」時丟 `unknownChat`（`getChat` 的錯誤）；建立請求的其他錯誤（含其他 400）原樣丟出。`unknownChat` 不會成為 `lastAutoFireError`。
- **驗收**：`TDLibRequestTests`（原始碼：每個非認證請求都經過 `tdlibCall`；每個接受聊天 id 的方法都在第一個請求前、不帶條件地單獨一行呼叫 `knownChat`；`knownChat` 的四行把參數原樣交給 `openClient`；CLI 的錯誤文字）、`UnseenChatTests`（每種 id 送的請求與 `force: false`、四種失敗、`unknownChat` 的 `hint` 與 `errorDescription`）、`ArchiveTDLibErrorTests`（改用 `tdlibCall`、`TDLibChatID` 的 id 範圍）、`CheTelegramAllMCPTests` 的 `TDLibErrorResultTests`（`tdlibError`、`unknownChat` 的 JSON，其他錯誤回 nil）；`swift test --skip E2ETests` 全過；`TDLibClosedClientTests` 仍通過。
- **範圍外**：`loadChats`、`get_user`、本機快取路徑、認證步驟。實測（全新資料庫、群組與 Saved Messages 以外的一對一聊天）需要維護者的帳號，不在自動測試內。
