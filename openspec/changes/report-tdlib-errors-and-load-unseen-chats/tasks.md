## 1. 每個 TDLib 請求都轉換錯誤（原因 1）

- [x] 1.1 先寫失敗的測試（Requirement: Every TDLib request reports TDLib's code and message；Requirement: Authentication scope of structured error contract：一般請求的 406 丟出、message 留空，四個認證請求仍走 `mapTDLibError`）：`ArchiveTDLibErrorTests` 改呼叫 `tdlibCall`；新檔 `TDLibRequestTests` 讀 `Sources/TelegramAllLib` 所有 Swift 檔，每一行含 `openClient.` 的程式碼必須是 `tdlibCall { try await openClient.` 或四個認證請求之一，且四個認證請求各出現一次。驗證：`swift build --build-tests` 因 `tdlibCall` 不存在而失敗
- [x] 1.2 依設計「轉換放在 `TelegramAllLib` 的請求邊界，每個請求各自包一次」與「406 在一般請求照樣丟出，message 留空」，把 `archiveTDLibCall` 改名 `tdlibCall` 移到 `TDLibRequests.swift`，`TDLibClient.swift` 的 28 個請求與封存檔案的請求都包進去。驗證：1.1 的測試通過，`TDLibClosedClientTests` 通過 [after: 1.1]

## 2. 用 id 載入沒見過的聊天（原因 2）

- [x] 2.1 先寫失敗的測試（Requirement: A chat TDLib has not loaded is loaded by its id）：`loadChat` 的六種情況（`getChat` 成功不建立；400 時依種類建立；建立回 400 丟 `unknownChat` 帶原錯誤；id 不可建立時不送建立請求；`getChat` 的非 400 錯誤與建立請求的 429 原樣丟出）；`TDLibChatID` 的 id 範圍；原始碼：每個接受聊天 id 的公開方法與封存的 `page`、`message` 都呼叫 `knownChat`；`TDError.unknownChat` 的 `errorDescription` 與 `hint`；server 的 `tdlibErrorResult(for:)` 對 `tdlibError`、`unknownChat`（含 `hint`）、其他錯誤（nil）。驗證：`swift build --build-tests` 先失敗 [after: 1.2]
- [x] 2.2 依設計「載入聊天：抽成可測的純函式，失敗時回報原錯誤」與「`unknownChat` 是 `TDError` 的新 case，server 加 `hint` 欄位」實作 `TDLibChatID`、`loadChat`、`knownChat`、`TDError.unknownChat`／`hint`、`tdlibErrorResult(for:)`，各方法在第一個請求前呼叫 `knownChat`，`loadChatForArchive` 移除，`handleWithTDLib` 的 catch 改用 `tdlibErrorResult(for:)`。驗證：2.1 的測試通過，`swift test --skip E2ETests` 全過 [after: 2.1]

## 3. 文件

- [x] 3.1 CHANGELOG `[Unreleased]` 記錄 #71 兩個原因；all-mcp README 說明 `tdlib_error` 的欄位（含 `hint`）與 TDLib 沒載入的聊天 id。驗證：人工核對 README 的欄位名與 `tdlibErrorResult` 的 JSON 鍵名一致 [after: 2.2]

## 4. 實測（需要維護者的帳號）

- [ ] 4.1 在沒有載入目標聊天的全新 TDLib 資料庫上（例如剛登入後、尚未呼叫 `get_chats`），分別用一個群組（basic group 或 supergroup）與一個非 Saved Messages 的一對一聊天呼叫 `get_chat_history`：記錄 `createPrivateChat`／`createBasicGroupChat`／`createSupergroupChat` 是否成功；失敗時回應是否為帶 `hint` 的 `tdlib_error`，以及照提示先呼叫 `get_chats` 後是否讀得到。驗證：結果貼在 #71；若建立失敗而 `get_chats` 能救回，另開 issue 決定是否在 `loadChat` 加 `loadChats` [after: 2.2]

## 5. 驗證後的修正

- [x] 5.1 先寫失敗的測試：原始碼測試改為掃 `Sources/TelegramAllLib` 所有檔案、辨認任何 `…chatId: Int64`／`…ChatId: Int64` 參數、略過註解行，並要求 `knownChat` 單獨一行、不帶條件、在第一個請求之前；封存的 `page` 只在 `fromMessageId == 0` 時載入而失敗。再讓 `page` 每一頁都呼叫 `knownChat`（Requirement: A chat TDLib has not loaded is loaded by its id）。驗證：`swift test --filter TDLibRequestTests` 先失敗後通過 [after: 2.2]
- [x] 5.2 先寫失敗的測試：`loadChat` 改收三個依種類的建立請求（參數同 TDLib，含 `force`），測每種 id 送哪個請求、`force: false`；四種失敗依 TDLib 原始碼（cb863c16）的回答：`getChat` 非 400 原樣、id 不可建立時原樣丟出 `getChat` 的錯誤、建立請求回 400「Chat info not found」才丟 `unknownChat` 加提示、建立請求的其他錯誤（含「Can't access the chat」）原樣；原始碼釘住 `knownChat` 把參數原樣交給 `openClient` 的四行。再實作，提示加上 `get_chats` 只讀主清單、不載入封存的聊天（Requirement: A chat TDLib has not loaded is loaded by its id）。驗證：`swift build --build-tests` 先失敗；換掉群組與 supergroup 的請求、或改成 `force: true` 時測試失敗 [after: 5.1]
