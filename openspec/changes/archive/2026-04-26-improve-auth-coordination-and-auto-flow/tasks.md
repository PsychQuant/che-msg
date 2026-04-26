## 1. TDD red phase — concurrency & coalescing tests

- [x] 1.1 [P] 新增 `che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthCoalescingTests.swift`，撰寫測試覆蓋 spec requirement「Coalesced execution of authentication methods」（design Decision 2: Coalesced Task pattern — pure helper at file scope）：用 mock body closure 計數 invocation；spawn 2 個 Task 同時呼 helper → assert body 只執行一次、兩個 caller 都拿到同 outcome
- [x] 1.2 在 `AuthCoalescingTests.swift` 加 case 覆蓋「auto-fire path coalesces with manual path」scenario：模擬 lock + taskRef 的 in-flight task → 第二個 caller awaits 而非另起新任務
- [x] 1.3 [P] 新增 `che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthStateLockingTests.swift`，覆蓋 spec requirement「Authentication state and credential cache are lock-protected」（design Decision 1: Concurrency primitive — `OSAllocatedUnfairLock`，不改 actor）：用 `getAuthState()` + 並發 setter 模擬 callback/stdio thread scenario，assert 讀取永遠看到一致 enum case（不會 partial state）
- [x] 1.4 [P] 新增 `che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthRunHandlerTests.swift`，覆蓋 spec requirement「`auth_run` MCP tool drives the state machine」（design Decision 4: `auth_run` MCP tool — state-machine driver）：透過 pure helper `decideAuthRunAction(...)` + `AuthRunAction` enum（task 5.3），verify auth_run 依 authState 路由到正確 action（5 個 state × 2 條件 = 10 個 case + caller-arg-overrides-env-var precedence）
- [x] 1.5 [P] 新增 `che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthStatusNextStepTests.swift`，覆蓋 spec requirement「`auth_status` response includes structured next-step hint」（design Decision 5: `auth_status` next_step hint — structured object，不只字串）：assert 5 個 state 對應的 `next_step` payload shape（含 `null` at ready）+ `last_error` 序列化
- [x] 1.6 在 `AuthStatusNextStepTests.swift` 加 case 覆蓋 spec requirement「Auto-fire failure surfacing via auth_status」（telegram-auth-error-reporting 新增 requirement）：注入 `lastAutoFireError = TDError.tdlibError(code:420,message:"FLOOD_WAIT_30")` → assert response `last_error` 含結構化 JSON
- [x] 1.7 [P] 新增 `che-telegram-all-mcp/Tests/TelegramAllLibTests/AutoFireChainTests.swift`，覆蓋 spec requirements「Auto-fire chain covers params, phone, and password steps」+「SMS verification code is never auto-fired from environment」：透過 pure helper `decideAutoFire(state:env...)` + `AutoFireAction` enum（task 4.1），parameterized over 4 個 auth state，assert (a) env 有 → fire；(b) env 無 → no-op；(c) `WaitCode` + `TELEGRAM_AUTH_CODE` 環境 → 仍 no-op
- [x] 1.8 跑 `swift test --skip E2ETests`，確認 1.1-1.7 全部 RED（compile fail 或 assertion fail）— file-scope helper 與 new MCP tool 尚未實作。Confirmed: `cannot find 'coalesceTask' / 'TaskFieldHolder' / 'decideAuthRunAction' / 'AuthRunAction' / 'authStatusResult' / 'decideAutoFire' in scope`. AuthStateLockingTests 用 inline OSAllocatedUnfairLock fixture 編得過（contract test 性質），其他 6 個 test files compile fail.

## 2. Concurrency primitive（design Decision 1: Concurrency primitive — `OSAllocatedUnfairLock`，不改 actor）

- [x] 2.1 在 `che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift` 新增 `private let lock = OSAllocatedUnfairLock()`（import `os` if needed），加在 `authState` 等 property 宣告之上
- [x] 2.2 把 `cachedApiId` / `cachedApiHash` / `authState` 的所有 read/write 包進 `lock.withLock { ... }`（**critical section 內不可 await**）
- [x] 2.3 把 `authState` 從 `public private(set) var` 改為 `private var`；新增 `public func getAuthState() -> AuthState`（lock 包讀取）
- [x] 2.4 `getAuthState() -> String`（既有 method）改為 call `getAuthState() -> AuthState`，rawValue 取出
- [x] 2.5 新增 `private var lastAutoFireError: TDError?`（lock-protected）+ `public func getLastAutoFireError() -> TDError?` accessor

## 3. Coalesced Task helper（design Decision 2: Coalesced Task pattern — pure helper at file scope）

- [x] 3.1 在 `TDLibClient.swift` file scope 加 internal helper（簽名草稿在 design.md），抽成可測試的 pure function — 實際放在新檔 `AuthCoalescing.swift`，含 `TaskFieldHolder` class + `coalesceTask(holder:body:)` free function
- [x] 3.2 在 `TDLibClient` 加四個 `private var setParametersTask`/`sendPhoneTask`/`sendCodeTask`/`sendPasswordTask: Task<Void, Error>?`（lock-protected）— 改用 `let setParametersTask = TaskFieldHolder()` 等四個 holder（lock 由 holder 內部管理）
- [x] 3.3 `setParameters` / `sendPhoneNumber` / `sendAuthCode` / `sendPassword` 的 body 改走 helper，每個 method 把對應 task field 傳給 helper
- [x] 3.4 跑 1.1 測試 → RED 轉 GREEN
- [x] 3.5 跑 1.2 測試（auto-fire vs manual coalescing）→ GREEN
- [x] 3.6 跑 1.3 測試（state locking）→ GREEN

## 4. Auto-fire chain extension（design Decision 3: Auto-fire chain — 3 step（params + phone + password），code step 必手動）

- [x] 4.1 在 `Sources/TelegramAllLib/` 新增 pure decision helper（任放 `AuthCoalescing.swift` 或新檔 `AutoFire.swift`）：`decideAutoFire(state:envApiId:envApiHash:envPhone:envPassword:envAuthCode:) -> AutoFireAction` + `AutoFireAction` enum（`.fireSetParameters(apiId:apiHash:)` / `.fireSendPhone(_:)` / `.fireSendPassword(_:)` / `.noOp`）。改造既有 `autoSetParametersIfAvailable`：移除 fire-and-forget Task，改先 call decision helper，依 `.fireSetParameters` 走 coalesceTask（task 3）；`.noOp` 直接 return。將 `try?` 換成 `do/catch` 把錯誤寫到 `lastAutoFireError`
- [x] 4.2 新增 `autoSendPhoneIfAvailable()`：讀 `TELEGRAM_PHONE` env var，若 present 則走 helper 呼 `sendPhoneNumber`；失敗寫到 `lastAutoFireError`
- [x] 4.3 在 `handleAuthStateUpdate` 的 `.authorizationStateWaitPhoneNumber` case 加 `autoSendPhoneIfAvailable()` 觸發
- [x] 4.4 改造 `autoSendPasswordIfAvailable`：與 4.1 同 pattern，移 `try?`、寫 `lastAutoFireError`、走 helper
- [x] 4.5 確認 spec requirement「SMS verification code is never auto-fired from environment」：在 `handleAuthStateUpdate` 的 `.authorizationStateWaitCode` case **不加** auto-fire；加 inline comment 引用 spec 防止未來誤改
- [x] 4.6 在三個 auto-fire path 起頭都加 `lock.withLock { lastAutoFireError = nil }`，覆蓋「last_error clears when fresh auto-fire begins」scenario（design Decision 6: `lastAutoFireError` 生命週期 — 由 auto-fire path 寫入；新一輪 auto-fire 清空）
- [x] 4.7 在 `handleAuthStateUpdate` 的 `.authorizationStateReady` case 也加 `lock.withLock { lastAutoFireError = nil }`，覆蓋「last_error clears at ready」scenario（design Decision 6 上半段 — advance 過 state 時清空）
- [x] 4.8 跑 1.6 + 1.7 測試 → RED 轉 GREEN

## 5. `auth_run` MCP tool（design Decision 4: `auth_run` MCP tool — state-machine driver）

- [x] 5.1 在 `che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift` 的 `defineTools()` 加 `auth_run` tool definition：optional args `phone` / `code` / `password`
- [x] 5.2 在 `handleToolCall` 加 `case "auth_run":`：依 `tdlib.getAuthState()` 5 個 state 路由：`waitingForParameters` 嘗試 auto-set 或 error；`waitingForPhoneNumber` 嘗試 auto-phone 或用 caller arg；`waitingForCode` 必要 caller `code` arg；`waitingForPassword` 嘗試 auto-password 或用 caller arg；`ready` no-op；`closed` error
- [x] 5.3 新增 file-scope helpers 在 `Sources/CheTelegramAllMCPCore/AuthResponses.swift`（**新檔**）：(a) `decideAuthRunAction(state:phone:code:password:envApiId:envApiHash:envPhone:envPassword:) -> AuthRunAction`（pure routing function — 5 states 對應的 action 決定，caller arg 優先於 env var）；(b) `AuthRunAction` enum（`.callSetParameters(apiId:apiHash:)` / `.callSendPhone(_:)` / `.callSendCode(_:)` / `.callSendPassword(_:)` / `.noOpReady` / `.errorClosed` / `.needsArgs([String])`）；(c) `authStatusResult(state:lastError:)` 組裝 `{state, next_step, last_error}` JSON payload — 三個 helper 皆 testable 不需 server instance
- [x] 5.4 `auth_run` 結尾用 5.3 helper 組 response，回傳給 caller
- [x] 5.5 跑 1.4 測試 → RED 轉 GREEN

## 6. `auth_status` 升級（design Decision 5: `auth_status` next_step hint — structured object，不只字串）

- [x] 6.1 修改 `Server.swift` 的 `case "auth_status":` handler，改用 5.3 的 `authStatusResult` helper 組 response，含 `state` + `next_step` + `last_error`
- [x] 6.2 既有 `auth_set_parameters` / `auth_send_phone` / `auth_send_code` / `auth_send_password` 維持不變（advanced/escape hatch）
- [x] 6.3 跑 1.5 測試 → RED 轉 GREEN

## 7. Build + verification

- [x] 7.1 在 `che-telegram-all-mcp/` 跑 `swift build -c release` — 全綠無 warning（剩 ld warning 是 TDLibFramework binary 內部 macOS 15→13 mismatch，非本 SDD 範圍）
- [x] 7.2 跑 `swift test --skip E2ETests` — 所有新增測試（含 1.1-1.7）+ 既有測試全綠（137 tests / 0 failures）
- [ ] 7.3 跑 universal build：`swift build -c release --triple arm64-apple-macosx13.0` + `swift build -c release --triple x86_64-apple-macosx13.0` + `lipo -create` — 確認 Intel/ARM 都過。**延後到實際發版（v0.4.4）時跑**，本 SDD 完成不需要 release。
- [x] 7.4 確認 `che-telegram-all-mcp/CHANGELOG.md` 加新版本 entry（`[Unreleased]`，等實際發版時 rename），記錄 BREAKING `TDLibClient.authState` direct access 改為 `getAuthState()` method、新 `auth_run` tool、`auth_status` schema 擴充
- [x] 7.5 README.md（che-telegram-all-mcp）補 `TELEGRAM_PHONE` env var 說明與範例，加在既有 env vars table，新增 `auth_run` recommended flow 段落
