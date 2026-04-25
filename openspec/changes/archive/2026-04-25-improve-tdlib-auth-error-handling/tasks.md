## 1. TDD red phase — tests first

- [x] 1.1 [P] 新增 `che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibAuthErrorTests.swift`，撰寫測試覆蓋 spec requirement「Structured TDLib error propagation」：mock `TDLibKit.Error{code: 420, message: "FLOOD_WAIT_30"}` 餵給 `setParameters`/`sendPhoneNumber`/`sendAuthCode`/`sendPassword`，assert throw `TDError.tdlibError(code:message:)` 帶 discrete code/message
- [x] 1.2 [P] 新增 `che-telegram-all-mcp/Tests/TelegramAllLibTests/JSONDecoderRegressionTests.swift`，撰寫測試覆蓋 spec requirement「JSONDecoder snake_case invariant for TDLib updates」（對應 design Decision 4: JSONDecoder snake_case regression invariant）：餵 fixture JSON `{"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateWaitTdlibParameters"}}` 過 client decoder path，assert decode 成 `Update.updateAuthorizationState` 且 `authorizationState == .authorizationStateWaitTdlibParameters`
- [x] 1.3 在 `TDLibAuthErrorTests.swift` 加兩個 case 覆蓋 spec requirement「TDLib error code 406 silent-ignore rule」（對應 design Decision 2: Code 406 silent-ignore handling）：(a) mock `Error{code: 406, message: any}` → assert method 不 throw、return 正常；(b) mock `Error{code: 400, message: "ANY"}` → assert throw `TDError.tdlibError(code: 400, message: "ANY")`，確認只有 406 觸發 silent-ignore
- [x] 1.4 [P] 新增 `che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthErrorResponseTests.swift`，覆蓋 spec requirement「MCP response error serialization」（對應 design Decision 3: MCP response 錯誤序列化格式）：mock auth handler throws `TDError.tdlibError(code: 420, message: "FLOOD_WAIT_30")` → assert MCP response `isError == true` 且 content 含 JSON `{"type":"tdlib_error","code":420,"message":"FLOOD_WAIT_30"}`
- [x] 1.5 跑 `swift test --skip E2ETests`，確認 1.1/1.2/1.3/1.4 都 RED（compile fail 或 assertion fail）— 確認測試確實會失敗才有意義

## 2. TDError 結構化欄位（design Decision 1: TDError.tdlibError 結構化欄位（取代 String））

- [x] 2.1 修改 `che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift` 的 `TDError.tdlibError` enum case，從 `(String)` 改為 `(code: Int, message: String)`
- [x] 2.2 更新 `TDError.errorDescription` 的 pattern match：`case .tdlibError(let code, let message): return "TDLib error \(code): \(message)"`
- [x] 2.3 跑 `swift build`，由 compiler 揪出 `Server.swift` 中所有 `TDError.tdlibError(...)` pattern match site（exhaustiveness 報錯就是 BREAKING 觸及點清單）

## 3. Auth method error unwrap（spec requirement「Structured TDLib error propagation」+「TDLib error code 406 silent-ignore rule」）

- [x] 3.1 在 `TDLibClient.setParameters` 包 `do/catch`：catch `TDLibKit.Error where code == 406` → 直接 return；catch 其他 `TDLibKit.Error` → throw `TDError.tdlibError(code: tdError.code, message: tdError.message)`
- [x] 3.2 在 `TDLibClient.sendPhoneNumber` 套用同 3.1 的 unwrap pattern
- [x] 3.3 在 `TDLibClient.sendAuthCode` 套用同 3.1 的 unwrap pattern
- [x] 3.4 在 `TDLibClient.sendPassword` 套用同 3.1 的 unwrap pattern
- [x] 3.5 確認 spec requirement「Authentication scope of structured error contract」：明確 **不動** chat operation methods（`getChats`、`getChat`、`getChatHistory`、`searchChats`、`sendMessage` 等），保持現有 propagation 行為不變
- [x] 3.6 跑 1.1 的 unit test → 應由 RED 轉 GREEN
- [x] 3.7 跑 1.3 的 unit test → 406 silent-ignore + 400 throw 兩個 case 都 GREEN

## 4. MCP response 結構化錯誤（design Decision 3: MCP response 錯誤序列化格式）

- [x] 4.1 在 `che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift` 加 helper `tdlibErrorResult(code: Int, message: String) -> CallTool.Result`，回 `isError: true` + JSON content `{"type":"tdlib_error","code":<code>,"message":"<message>"}`
- [x] 4.2 修改 `Server.swift` 的 `handleToolCall` catch 區塊：catch `TDError.tdlibError(let code, let message)` → 用 4.1 的 helper 回 response（套用於 `auth_set_parameters`/`auth_send_phone`/`auth_send_code`/`auth_send_password` 四個 case）
- [x] 4.3 確認其他 `TDError` case（`.notAuthenticated`、`.missingCredentials`）的 catch path 不受影響，仍走原 `errorResult(message:)` plain text path
- [x] 4.4 跑 1.4 的 unit test → 應由 RED 轉 GREEN

## 5. JSONDecoder snake_case regression（design Decision 4: JSONDecoder snake_case regression invariant）

- [x] 5.1 確認 `TDLibClient.swift:55-67` 的 decoder 仍有 `decoder.keyDecodingStrategy = .convertFromSnakeCase`（read-only check，不修改）
- [x] 5.2 跑 1.2 的 `JSONDecoderRegressionTests` → GREEN，鎖住 v0.2.0 那個 critical bug 的回歸路徑

## 6. Build + verification

- [x] 6.1 在 `che-telegram-all-mcp/` 跑 `swift build -c release` — 全綠無 warning
- [x] 6.2 跑 `swift test --skip E2ETests` — 所有新增測試 + 既有測試全綠
- [x] 6.3 確認 `che-telegram-all-mcp/CHANGELOG.md` 加新版本 entry（暫定 `[Unreleased]`，等實際發版時 rename），記錄 BREAKING `TDError.tdlibError` enum case shape 變更與新增的 structured MCP error response 行為
