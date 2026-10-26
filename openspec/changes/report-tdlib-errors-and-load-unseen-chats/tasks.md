## 1. 每個 TDLib 請求都轉換錯誤（原因 1）

- [x] 1.1 先寫失敗的測試（Requirement: Every TDLib request reports TDLib's code and message；Requirement: Authentication scope of structured error contract：一般請求的 406 丟出、message 留空，四個認證請求仍走 `mapTDLibError`）：`ArchiveTDLibErrorTests` 改呼叫 `tdlibCall`；新檔 `TDLibRequestTests` 讀 `Sources/TelegramAllLib` 所有 Swift 檔，每一行含 `openClient.` 的程式碼必須是 `tdlibCall { try await openClient.` 或四個認證請求之一，且四個認證請求各出現一次。驗證：`swift build --build-tests` 因 `tdlibCall` 不存在而失敗
- [x] 1.2 依設計「轉換放在 `TelegramAllLib` 的請求邊界，每個請求各自包一次」與「406 在一般請求照樣丟出，message 留空」，把 `archiveTDLibCall` 改名 `tdlibCall` 移到 `TDLibRequests.swift`，`TDLibClient.swift` 的 28 個請求與封存檔案的請求都包進去。驗證：1.1 的測試通過，`TDLibClosedClientTests` 通過 [after: 1.1]

## 2. 用 id 載入沒見過的聊天（原因 2）

- [ ] 2.1 先寫失敗的測試（Requirement: A chat TDLib has not loaded is loaded by its id）：`loadChat` 的六種情況（`getChat` 成功不建立；400 時依種類建立；建立回 400 丟 `unknownChat` 帶原錯誤；id 不可建立時不送建立請求；`getChat` 的非 400 錯誤與建立請求的 429 原樣丟出）；`TDLibChatID` 的 id 範圍；原始碼：每個接受聊天 id 的公開方法與封存的 `page`、`message` 都呼叫 `knownChat`；`TDError.unknownChat` 的 `errorDescription` 與 `hint`；server 的 `tdlibErrorResult(for:)` 對 `tdlibError`、`unknownChat`（含 `hint`）、其他錯誤（nil）。驗證：`swift build --build-tests` 先失敗 [after: 1.2]
- [ ] 2.2 依設計「載入聊天：抽成可測的純函式，失敗時回報原錯誤」與「`unknownChat` 是 `TDError` 的新 case，server 加 `hint` 欄位」實作 `TDLibChatID`、`loadChat`、`knownChat`、`TDError.unknownChat`／`hint`、`tdlibErrorResult(for:)`，各方法在第一個請求前呼叫 `knownChat`，`loadChatForArchive` 移除，`handleWithTDLib` 的 catch 改用 `tdlibErrorResult(for:)`。驗證：2.1 的測試通過，`swift test --skip E2ETests` 全過 [after: 2.1]

## 3. 文件

- [ ] 3.1 CHANGELOG `[Unreleased]` 記錄 #71 兩個原因；all-mcp README 說明 `tdlib_error` 的欄位（含 `hint`）與 TDLib 沒載入的聊天 id。驗證：人工核對 README 的欄位名與 `tdlibErrorResult` 的 JSON 鍵名一致 [after: 2.2]

## 4. 實測（需要維護者的帳號）

- [ ] 4.1 在沒有載入目標聊天的全新 TDLib 資料庫上（例如剛登入後、尚未呼叫 `get_chats`），分別用一個群組（basic group 或 supergroup）與一個非 Saved Messages 的一對一聊天呼叫 `get_chat_history`：記錄 `createPrivateChat`／`createBasicGroupChat`／`createSupergroupChat` 是否成功；失敗時回應是否為帶 `hint` 的 `tdlib_error`，以及照提示先呼叫 `get_chats` 後是否讀得到。驗證：結果貼在 #71；若建立失敗而 `get_chats` 能救回，另開 issue 決定是否在 `loadChat` 加 `loadChats` [after: 2.2]
