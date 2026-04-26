## Why

`che-telegram-all-mcp#2` 揭露遠端 Mac 跑 plugin 的核心摩擦：使用者得手動跑 4 個 MCP tool calls (`auth_set_parameters` → `auth_send_phone` → `auth_send_code` → `auth_send_password`) 才能 auth 起來，而且 `auto-set` 與 manual 之間有 race（v0.4.3 修好 decoder bug 後此 race 反而變得更 active）。實際使用者要的是「裝完 plugin、跑 `/auth`、最多貼一次 SMS code、完成」。

合併原 #2（race fix）+ #4（auto-flow trigger，已 closed merged into #2）成單一 SDD 因為兩者依賴緊密：race fix 是 plumbing，使用者體驗不到；auto-flow 沒 race fix 不可靠。獨立 ship #2 race fix 對遠端 UX 沒進步。

## What Changes

### Concurrency safety (race fix layer)

- 把 `TDLibClient.swift` 的 4 個 auth method (`setParameters` / `sendPhoneNumber` / `sendAuthCode` / `sendPassword`) 改為 **coalesced execution** — 同一 method 並發呼叫共用同一 in-flight `Task<Void, Error>`，不重複呼 TDLib endpoint
- Coalesce 用 `OSAllocatedUnfairLock` 保護 task handle 的 read/write
- `cachedApiId` / `cachedApiHash` / `authState` 三個 mutable property 用同一 lock 保護
- `autoSetParametersIfAvailable` 與 `autoSendPasswordIfAvailable` 改走 coalesced path
- **BREAKING (internal)**: `TDLibClient.authState` 從 sync property 改為透過 lock 讀取的 method `getAuthState() -> AuthState`（保留 `getAuthState() -> String` 既有 method）

### Auto-flow chain (新功能)

- 新增 `autoSendPhoneIfAvailable()`：當 TDLib 進到 `WaitPhoneNumber` 時，從 env var `TELEGRAM_PHONE` 或 Keychain `TELEGRAM_PHONE` 讀手機號碼自動 fire
- 新增 `submitAuthCode(_ code: String)` library method：等同 `sendAuthCode` 但走 coalesced path
- `autoSendPasswordIfAvailable` 維持，refactor 走 coalesced path
- 移除 auto-fire 的 `try?` swallow，failure 透過 lock-protected `lastAutoFireError: TDError?` field 暴露給 caller
- 新增 env var spec：
  - `TELEGRAM_PHONE`：手機號碼（含國碼，如 `+886912345678`）
  - **不**新增 `TELEGRAM_AUTH_CODE` env var — SMS code lifetime 短（5 分鐘）+ single-use，env var 持久化會洩漏。Code 走 MCP tool 一次性注入

### MCP tool surface

- 新增 MCP tool **`auth_run`**：driver tool，依當前 `authState` 驅動下一步
  - 若 `waitingForParameters` → 觸發 auto-set（若 env 有）或回 missing-credentials error
  - 若 `waitingForPhoneNumber` → 觸發 auto-send-phone（若 Keychain/env 有）或回 next-step hint「請呼叫 `auth_run` with `phone` arg」
  - 若 `waitingForCode` → 必要 `code` arg；回 next-step hint
  - 若 `waitingForPassword` → 觸發 auto-send-password（若 env 有）或必要 `password` arg
  - 若 `ready` → no-op，回成功
- 修改 MCP tool **`auth_status`**：response 加 `next_step` 欄位（structured object，包含 `tool` / `required_args` / `hint`），讓 caller 不用解 free-text
- 既有 `auth_set_parameters` / `auth_send_phone` / `auth_send_code` / `auth_send_password` 維持作為 lower-level entry point，但 marked "advanced — prefer auth_run"

### `/auth` slash command

- 既有 `commands/auth.md`（在 plugin repo）改為**真的呼叫 `auth_run` MCP tool**，不是只給 LLM 描述。Plugin shell 改動屬於 follow-up（不在此 SDD scope，但 design.md 會記錄協同變更）

## Non-Goals (optional)

> 此 change 將建立 design.md，所以 Non-Goals 寫在那邊，這裡留白。

## Capabilities

### New Capabilities

- `telegram-auth-coordination`: 定義 `che-telegram-all-mcp` 認證流程的 concurrency 模型、auto-fire 機制、與 driver tool 行為。涵蓋：（a）4 個 auth method 的 coalesced execution contract，（b）env / Keychain 自動讀取規則，（c）`auth_run` driver tool 的 state-machine-driven 行為，（d）`auth_status` 的 structured next-step hint。

### Modified Capabilities

- `telegram-auth-error-reporting`: 新增「auto-fire failure surfacing」requirement。原 spec 只規範 method-level error propagation；此次新增「auto-fire path 的失敗不能 silent swallow，必須暴露在 `auth_status` response 中」requirement。

## Impact

- **Affected code**:
  - `che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift`（concurrency primitive、coalesced auth methods、autoSendPhone、lastAutoFireError）
  - `che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift`（新 `auth_run` tool、`auth_status` schema 擴充）
  - `che-telegram-all-mcp/Tests/TelegramAllLibTests/`（新 `AuthCoalescingTests.swift`、修改既有 `TDLibClientTests`）
  - `che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/`（新 `AuthRunHandlerTests.swift`、`AuthStatusNextStepTests.swift`）
- **Affected specs**:
  - 新增：`openspec/specs/telegram-auth-coordination/spec.md`
  - 修改：`openspec/specs/telegram-auth-error-reporting/spec.md`（新 ADDED Requirement）
- **Out of scope**（拆獨立 SDD / hotfix）:
  - **Cross-machine session sync** (#3) — 獨立 SDD，code surface 完全不同
  - `commands/auth.md` 改成真的 invoke `auth_run` — 屬 plugin repo 的 follow-up commit，不在此 SDD（但會在 design.md 列為 dependency）
  - **Swift 6 strict concurrency adoption** (`-strict-concurrency=complete`) — 此 SDD 不切此 flag，僅確保 lock-based 設計兼容未來啟用
  - **TELEGRAM_AUTH_CODE env var 注入 SMS code** — 安全考量拒絕（見 design.md Decisions）
  - **Webhook / bot relay 取得 SMS code** — 不在範圍
- **Dependencies**: 無新外部依賴；`OSAllocatedUnfairLock` 是 Foundation API（macOS 13+，符合 Package.swift 既有 platform requirement）
- **Breaking surface**: `TDLibClient.authState` direct property access 改成 method call — internal API only（消費者只有 `Server.swift`，會一起更新）
