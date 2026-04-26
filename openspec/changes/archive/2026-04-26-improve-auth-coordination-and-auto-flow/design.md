## Context

`che-telegram-all-mcp` 有兩個糾結的問題：

1. **Race**：`autoSetParametersIfAvailable` (`TDLibClient.swift:150`) 從 TDLib callback thread spawn fire-and-forget Task；同時 `Server.swift` 的 `auth_set_parameters` MCP handler 從 stdio thread 直接呼 `setParameters`。兩條路徑在 `WaitTdlibParameters` state 下並發，TDLib 拒絕第二個。同 shape 在 password 路徑（`autoSendPasswordIfAvailable`）。
2. **遠端使用者要手動跑 4 個 auth tool calls** — 不只設定流程煩，且兩個 auto-fire 既有路徑（params + password）失敗會被 `try?` 吞掉，使用者完全看不到。

v0.4.3 修了 snake_case decoder bug 之後，update broadcast 才真的 fire，race 從「永遠不發生」變「每次 cold start 都可能」。修這個 race 的 priority 比表面看的高。

Diagnose 階段（issue #2）已列三條候選 fix（C1 coalesced Task / C2 actor / C3 NSLock+flags）。Discuss 階段轉向「from remote-user UX」反推：race fix 是 plumbing，使用者體會不到差異；要交付的是「`/auth` 跑一次就完成」。SDD scope 因此擴大為 race fix + auto-flow。

## Goals / Non-Goals

**Goals:**

- 4 個 auth method 在 concurrent invocation 下行為 deterministic — 兩個 caller 永遠看到單一 outcome
- `cachedApiId` / `cachedApiHash` / `authState` 三個 mutable state 在 callback thread 與 stdio thread 之間的存取被 lock 保護
- Auto-fire chain 涵蓋三個 auth step（params、phone、password）；code step 留 explicit `auth_run(code: ...)` 入口（SMS code 是 inherent out-of-band）
- Auto-fire 失敗不再 silent — 透過 `lastAutoFireError` field 暴露在 `auth_status` response
- 新 MCP tool `auth_run` 作為 driver — caller 一直呼叫直到 `state == .ready`，每次依當前狀態 advance 一步
- `auth_status` response 結構化 `next_step` hint — caller 不用解 free-text 知道下一步要呼什麼

**Non-Goals:**

- **不**改 `TDLibClient` 為 `actor` — 改了就 BREAKING 全部 26+ public method 變 async，回歸風險過大
- **不**做 Swift 6 strict concurrency adoption — 此 SDD 確保 lock-based 設計可在未來啟用該 flag 時通過編譯，但不切 flag
- **不**注入 SMS code via env var `TELEGRAM_AUTH_CODE` — code 5 分鐘 single-use，env var 持久化會洩漏；caller 必須一次性 paste
- **不**處理 cross-machine session sync — `che-telegram-all-mcp#3` 獨立 SDD
- **不**改 `commands/auth.md`（plugin shell 改動）— 在 plugin repo 跟此 SDD 分開 commit
- **不**做 webhook / bot relay 自動接 SMS code — 開另一個 can of worms
- **不**改 chat / message / contact operation 的 concurrency — 此 SDD 範圍只限 4 個 auth method 與相關 mutable state

## Decisions

### Decision 1: Concurrency primitive — `OSAllocatedUnfairLock`，不改 actor

`TDLibClient` 維持 `public final class`，加 `private let lock = OSAllocatedUnfairLock()`，保護以下 mutable state 的 read/write：

```swift
// State protected by `lock`:
private var cachedApiId: Int?
private var cachedApiHash: String?
private var authState: AuthState = .waitingForParameters
private var setParametersTask: Task<Void, Error>?
private var sendPhoneTask: Task<Void, Error>?
private var sendCodeTask: Task<Void, Error>?
private var sendPasswordTask: Task<Void, Error>?
private var lastAutoFireError: TDError?
```

Public `getAuthState()` 取代既有 `authState` property 的 sync read。

**Why over alternatives:**

- **C2 actor**: 改了 BREAKING 全部 public method async，影響 Server.swift 全 handler、telegram-all CLI、所有 tests。範圍大。
- **C3 NSLock + flags**: 「concurrent caller 怎麼等 in-flight 完成」沒有乾淨答案；要 spin-wait or `NSCondition`，async code 不自然。
- **Chosen** `OSAllocatedUnfairLock` (Foundation, macOS 13+)：tagged with `Sendable` requirement annotations correctly；no priority inversion vs raw `os_unfair_lock`；可在 Swift 6 strict concurrency 下通過。

### Decision 2: Coalesced Task pattern — pure helper at file scope

新增 file-scope helper：

```swift
internal func coalescedAuthCall<T>(
    lock: OSAllocatedUnfairLock,
    taskRef: KeyPath<TDLibClient, Task<Void, Error>?>,
    setTaskRef: ReferenceWritableKeyPath<TDLibClient, Task<Void, Error>?>,
    on client: TDLibClient,
    body: @escaping () async throws -> T
) async throws -> T?
```

> Final signature 在 implementation 階段定 — 上面是骨架。重點是**邏輯抽成 testable pure function**，避免每個 auth method 重複 lock + task-handle 三段邏輯。

呼叫流程：
1. Acquire lock
2. 若 `taskRef` 已有 in-flight Task → release lock，await 該 task → return
3. 若無 → create new Task 包 `body`，存 `setTaskRef`，release lock
4. Await new task；defer 清空 `setTaskRef`

**Why over alternatives:**

- **Per-method ad-hoc lock blocks**: 4 個 method 重複 lock + task-handle 邏輯，高度容易出錯（lock 漏 release、task-ref 漏清）。
- **`OSAllocatedUnfairLock.withLock { ... }` inline closures**: 短 critical section OK，但「await Task while holding lock」是 anti-pattern（lock 不能跨 suspend point）。Helper 抽掉這個 trap。
- **Chosen** file-scope helper，符合 v0.4.3 SDD 既建立的「testable file-scope helper」pattern (`mapTDLibError`、`makeUpdateDecoder`、`tdlibErrorResult`)。

### Decision 3: Auto-fire chain — 3 step（params + phone + password），code step 必手動

| Step | Auto-fire? | Source | Trigger event |
|------|-----------|--------|---------------|
| `setTdlibParameters` | ✓ | `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` env or Keychain | `WaitTdlibParameters` update |
| `setAuthenticationPhoneNumber` | ✓（新增） | `TELEGRAM_PHONE` env or Keychain `che-telegram-all-mcp/TELEGRAM_PHONE` | `WaitPhoneNumber` update |
| `checkAuthenticationCode` | ✗ | 必要 caller 顯式提供 | N/A — `auth_run(code: ...)` |
| `checkAuthenticationPassword` | ✓（既有） | `TELEGRAM_2FA_PASSWORD` env or Keychain | `WaitPassword` update |

**Why code 不 auto-fire:**

- TDLib SMS code lifetime 5 分鐘 + single-use
- 注入 env var → 持久化進 process env / keychain → 洩漏給其他工具讀到
- 注入 file → file 須立即刪除，邏輯複雜且 race 風險
- Caller paste 一次性 + `auth_run(code: "12345")` 是最簡單最安全

**Keychain entry 命名:**

| Variable | Keychain account | Keychain service |
|----------|-----------------|------------------|
| `TELEGRAM_API_ID` | `che-telegram-all-mcp` | `TELEGRAM_API_ID` |
| `TELEGRAM_API_HASH` | `che-telegram-all-mcp` | `TELEGRAM_API_HASH` |
| `TELEGRAM_PHONE` | `che-telegram-all-mcp` | `TELEGRAM_PHONE` |
| `TELEGRAM_2FA_PASSWORD` | `che-telegram-all-mcp` | `TELEGRAM_2FA_PASSWORD` |

Wrapper script `bin/che-telegram-all-mcp-wrapper.sh` 已負責讀 Keychain export 為 env var（見現存程式碼），所以 library 層只需讀 env var，無需額外 Keychain SDK 依賴。

### Decision 4: `auth_run` MCP tool — state-machine driver

新增 MCP tool `auth_run`：

```jsonc
{
  "name": "auth_run",
  "description": "Drive the Telegram auth state machine. Call repeatedly until state==ready. Auto-fires steps that have prerequisites available.",
  "inputSchema": {
    "phone":    { "type": "string", "description": "Phone number (with country code) — only required for state=waitingForPhoneNumber if env/Keychain is empty" },
    "code":     { "type": "string", "description": "SMS verification code — required for state=waitingForCode" },
    "password": { "type": "string", "description": "2FA password — required for state=waitingForPassword if env/Keychain is empty" }
  }
}
```

行為（依當前 `authState`）：

| State | `auth_run` 行為 | 後續 |
|-------|---------------|------|
| `waitingForParameters` | Trigger auto-set（若 env/Keychain 有）；無則 error | Caller 再呼 `auth_run`，state 應已 advance |
| `waitingForPhoneNumber` | Trigger auto-send-phone（若有）；用 caller 提供的 `phone` arg；無 env 也無 arg → error | 同上 |
| `waitingForCode` | 必須 `code` arg；無則 error with structured next_step | 等待 caller paste code |
| `waitingForPassword` | Auto-send（若有）；用 caller `password` arg；都無 → error | 同上 |
| `ready` | No-op，回成功 | Done |
| `closed` | Error — caller 須重新 init client | Bail |

Response shape：

```jsonc
{
  "state": "ready" | "waitingForCode" | ...,
  "next_step": {
    "tool": "auth_run",
    "required_args": ["code"],
    "hint": "Paste the SMS verification code Telegram sent to +886xxxxx"
  } | null  // null when state == ready
}
```

**Why over alternatives:**

- **單一 `auth_run` vs 既有 4 tools 升級**：保留既有 4 tool 作為 advanced/escape hatch（呼 specific step），但 `auth_run` 作為 caller 主要入口。LLM-driven workflow 不用記哪步該呼什麼。
- **Auto-detect input vs explicit args**：caller 提供 `phone: "+886..."` 即使 env 也有，以 caller arg 為準（manual override env）。
- **Chosen**：`auth_run` 是 idempotent — 無論當前 state 都呼，依狀態 advance 一步或 no-op。

### Decision 5: `auth_status` next_step hint — structured object，不只字串

既有 `auth_status` response 是 `{"status": "waitingForParameters"}`。擴充為：

```jsonc
{
  "status": "waitingForCode",
  "next_step": {
    "tool": "auth_run",
    "required_args": ["code"],
    "hint": "Paste the SMS verification code Telegram sent to +886912345678"
  },
  "last_error": null  // or {"type": "tdlib_error", "code": ..., "message": ...}
}
```

`last_error` 來自 `lastAutoFireError` field — auto-fire 失敗時這裡會出現，caller 知道為什麼 auth 卡住。

**Why over alternatives:**

- **Plain string hint**：違反 v0.4.3 既有「結構化錯誤 over free-text」原則。
- **回傳 enum on caller**：JSON-RPC 不天然支援 enum；string + structured object 是 lingua franca。
- **Chosen**：與 `tdlibErrorResult(code:message:)` 相同精神 — caller 解 JSON 即可，不靠 regex。

### Decision 6: `lastAutoFireError` 生命週期

- 由 auto-fire path（`autoSetParametersIfAvailable`、`autoSendPhoneIfAvailable`、`autoSendPasswordIfAvailable`）寫入
- 由 `auth_status` response 讀取
- 新一輪 auto-fire 開始時清空（避免顯示過時錯誤）
- Caller 顯式呼 `auth_run` / `auth_set_parameters` 等 manual entry 時不寫入此 field（manual error 走 throw + structured MCP response）

**Why:**

- 區分 auto path 與 manual path 的 error reporting：auto path 沒有同步 caller 可拋；manual path 有。
- Auto path 的失敗對 caller 是 "background event"，next-step hint 把它接出來。

## Risks / Trade-offs

- **[Risk] Lock 跨 await suspend** — Swift Concurrency 不允許 hold lock 跨 suspend point。Helper signature 必須 release lock 才 await Task。**Mitigation**: 設計成「lock 內讀 task handle → release lock → await task」；helper 內封裝此 pattern 確保所有 caller 不會誤用。
- **[Risk] Auto-fire 失敗用 `lastAutoFireError` 暴露，但同時 caller 又呼 `auth_run` 觸發新的失敗** — 兩條 path 同時寫 `lastAutoFireError` 會 race。**Mitigation**: `lastAutoFireError` 只由 auto-fire path 寫；manual path 走 throw。Test cover 兩 path 並發場景。
- **[Trade-off] `OSAllocatedUnfairLock` 是 macOS 13+ API** — 不是 problem (Package.swift 已要求 macOS 13)，但若未來想支援 iOS 13 / older macOS 要重新評估。
- **[Risk] `TDLib` callback 與 stdio handler 都會呼 lock** — Lock contention 集中在 short critical section（lock acquire → branch → release，<10 instructions），無 deadlock 顧慮（無 nested lock）。
- **[Trade-off] `auth_run` 增加 surface — 既有 4 tools 沒 deprecate** — 短期保留兩條路徑，3 個月後若 metrics 顯示無人用 individual tools 再 deprecate。Spec 已 marked "advanced — prefer auth_run"。
- **[Risk] `TELEGRAM_PHONE` env var 洩漏顧慮** — 手機號碼是中度敏感資料；env var 已是既有 pattern (API_ID/HASH 也是 env)；存 Keychain 走 wrapper 解。Caller 端 wrapper 必須先寫好 Keychain bootstrap doc。**Mitigation**: README 與 Keychain entry 命名與 API_ID 一致，使用者已熟悉同 pattern。

## Open Questions

- **`auth_run` 與既有 `auth_set_parameters` 等 4 tool 並存策略**：3 個月後 deprecate 還是永久共存？Spec 用 SHOULD vs SHALL 寫法不同。傾向 3 個月後 deprecate，但實際 deprecation 留 follow-up。
- **`lastAutoFireError` 是否該在 success 時清空 or 保留歷史？** 傾向新 auto-fire 啟動時清空，advance 過 state 時也清。實作階段確認。
- **`/auth` slash command 改動的 PR 順序** — 此 SDD ship 後 `commands/auth.md` 必須改才能讓使用者真的體會到 UX。Plugin repo PR 是這個 SDD 的 follow-up 還是同 PR ship？傾向 follow-up（plugin repo 是不同 git 倉），但 README / changelog 要 cross-reference。
