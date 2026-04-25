## Context

`che-telegram-all-mcp` 是 Swift Package monorepo 的 subdirectory。Auth 流程透過 TDLib（C++ 函式庫）+ TDLibKit（Swift wrapper）實作：

```
MCP tool call (Server.swift)
  ↓
TDLibClient.setParameters/sendPhoneNumber/sendAuthCode/sendPassword (TDLibClient.swift)
  ↓
TDLibKit.TDLibClient.* (request/response decoded by TDLibKit internal)
  ↓
TDLib C library (returns response or `Error{code, message}`)
```

當 TDLib 回 error，TDLibKit 把 `TDLibKit/Sources/TDLibKit/Generated/Models/Error.swift` 的 `Error{code: Int, message: String}` throw 出來。`TDLibClient` 的四個 auth method 沒接 — 直接 propagate 給 `Server.swift`，後者把 `Swift.Error` 轉成 `errorResult(error.localizedDescription)`，呼叫端只看到 `"TDLibKit.Error error 1"`（`Swift.Error` 的 default `localizedDescription`）。

平行的 latent risk：v0.2.0 因為 `JSONDecoder` 缺 `.convertFromSnakeCase` 而所有 update decode silent fail，導致 `authState` 凍結。雖然 v0.3.0 修了，但缺 regression test 鎖住此 invariant。

## Goals / Non-Goals

**Goals:**

- 把 TDLib error 的 `code: Int` + `message: String` 透過 `TDError.tdlibError(code:message:)` 結構化地 surface 給呼叫端
- 在 MCP tool response 中以 JSON 結構（`{"error": {"code": 420, "message": "FLOOD_WAIT_30"}}`）回給 AI agent
- 對 TDLib 協定保留的 error code 406 走 silent-ignore path（不 surface 給 user）
- 用 unit test 鎖住 `JSONDecoder.keyDecodingStrategy == .convertFromSnakeCase`，防止 v0.2.0 那個 critical bug 再次潛入

**Non-Goals:**

- **不**修 auto-set `Task` race（Issue C tertiary 的 C1/C2/C3 設計）— 拆獨立 issue
- **不**修 `TELEGRAM_2FA_PASSWORD` auto-send 的同類 race
- **不**改 chat operations method（`getChats`、`getChatHistory` 等）的 error handling — scope 只限 auth 四 method（`setParameters` / `sendPhoneNumber` / `sendAuthCode` / `sendPassword`）；chat ops 的 error contract 等未來有需求再 spec
- **不**做自動 retry / backoff（即使 `code == 420 FLOOD_WAIT_X`）— 留給呼叫端決策（YAGNI）
- **不**負責發布 v0.4.x prebuilt binary 到 GitHub Releases（hotfix process，與此 spec change 解耦）
- **不**做 i18n（TDLib message 直接透傳，不翻譯）

## Decisions

### Decision 1: TDError.tdlibError 結構化欄位（取代 String）

`TDError.tdlibError` 的 associated value 從 `String` 改為 `(code: Int, message: String)`：

```swift
case tdlibError(code: Int, message: String)

public var errorDescription: String? {
    switch self {
    case .tdlibError(let code, let message):
        return "TDLib error \(code): \(message)"
    // ...
    }
}
```

**Why over alternatives:**

- **Alt A: 保留 `String`，在 throw 處組字串 `"\(code): \(message)"`** → 呼叫端要解析字串才能拿 code，不利於 MCP response 序列化成結構化 JSON。
- **Alt B: 新增獨立 case `tdlibCodedError(Int, String)` 與既有 `tdlibError(String)` 並存** → API surface 膨脹，現有 case 變死碼，沒帶來好處。
- **Chosen**: 直接改既有 case shape — 內部 BREAKING（影響 `Server.swift` 的 switch / pattern match）但呼叫端統一拿到結構化欄位。`TDError` 是 internal API（`public` 但只有 `che-telegram-all-mcp` 內部使用），無外部 consumer。

### Decision 2: Code 406 silent-ignore handling

TDLib 協定文件明確規定：

> If the error code is 406, the error message must not be processed in any way and must not be displayed to the user.

實作策略：在 `TDLibClient` 的四個 auth method 的 `do/catch` block 中：

```swift
do {
    _ = try await client.setTdlibParameters(...)
} catch let tdError as TDLibKit.Error where tdError.code == 406 {
    // Silently ignore per TDLib protocol. Auth state machine will continue
    // via update broadcasts; caller should re-check authState on next tool call.
    return
} catch let tdError as TDLibKit.Error {
    throw TDError.tdlibError(code: tdError.code, message: tdError.message)
}
```

**Why over alternatives:**

- **Alt A: throw 一個 `TDError.silentlyIgnored` sentinel** → 呼叫端要分辨 sentinel vs 真錯，邏輯更繁瑣。406 在語意上就是「假裝沒事」，return 才符合 TDLib intent。
- **Alt B: 把 406 也 throw 為 `tdlibError(code: 406, ...)` 讓呼叫端決定** → 違反 TDLib 協定（「must not be processed」表示 client 層就該吞掉，不該往上傳）。
- **Chosen**: silent return（method 的 return type 是 `Void` 或 `Throwing` 不回值，silent return 不會誤導呼叫端）。

### Decision 3: MCP response 錯誤序列化格式

`Server.swift` 的 auth tool handler 在 catch `TDError.tdlibError(code, message)` 時，回 MCP response：

```json
{
  "error": {
    "type": "tdlib_error",
    "code": 420,
    "message": "FLOOD_WAIT_30"
  }
}
```

**Why over alternatives:**

- **Alt A: plain string `"TDLib error 420: FLOOD_WAIT_30"`** → AI agent 要 regex 解析才能拿 code，違反 MCP 「結構化資料優於字串」的精神。
- **Alt B: 沿用 `errorResult(message: String)` helper（plain text MCP error）** → MCP 標準的 `errorResult` 是 plain text；改成 structured 要走 result content 而非 isError flag。
- **Chosen**: 用 result content 回結構化 JSON，並把 `isError: true`。Caller AI agent 既看得到 plain text fallback 也能 parse JSON。`Server.swift` 加 helper `tdlibErrorResult(code:message:)`。

### Decision 4: JSONDecoder snake_case regression invariant

新增 unit test `JSONDecoderConfigurationTests`（檔名待 tasks 決定），assertion：

```swift
// 黑箱測試：餵 snake_case JSON → 確認 decode 成功
let json = """
{"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateWaitTdlibParameters"}}
"""
// Decode via TDLibClient's internal decoder path, assert no throw + correct enum case.
```

**Why over alternatives:**

- **Alt A: 直接 reflect 出 `JSONDecoder` instance assert `.keyDecodingStrategy == .convertFromSnakeCase`** → `keyDecodingStrategy` 是 `enum` 但無 `Equatable` conformance（Swift Foundation 限制），無法直接斷言。
- **Alt B: 把 decoder 暴露成 `TDLibClient` 的 internal property** → 為了測試破壞 encapsulation。
- **Chosen**: 黑箱測試 — 餵已知 snake_case JSON，確認能 decode 出預期結果。Indirect but robust。

## Risks / Trade-offs

- **[Risk] TDLibKit `Error` 型別將來改名 / 改欄位** → Mitigation: unit test 包含 fixture JSON `{"@type":"error","code":420,"message":"FLOOD_WAIT_30"}` 餵給 mock；若 TDLibKit 升級導致 fixture 失效，test 會立刻失敗，提示維護者更新。
- **[Risk] `TDError.tdlibError` BREAKING 影響 `Server.swift` 既有 pattern match** → Mitigation: 同一 PR 改完所有 call site；compiler 會在 `switch` exhaustiveness 強制標出遺漏。
- **[Trade-off] Silent-ignore 406 讓呼叫端無法觀察「是否曾遇到 406」** → 接受。TDLib 協定明文要求；若將來需 telemetry，加 `os_log` 不影響 contract。
- **[Risk] MCP response 結構化錯誤格式可能與既有 client 的 plain text 解析不相容** → Mitigation: 新格式包含 plain-text 訊息作 fallback；MCP `isError: true` flag 仍維持，相容 client 的 error detection。
- **[Trade-off] 不修 race（Issue C tertiary）→ user 升級到新 binary 後可能仍撞 race** → 接受。Race fix 需獨立設計決策（C1/C2/C3），混進來會稀釋這個 change 的 review 焦點。後續 issue 追蹤。

## Open Questions

- **MCP error helper 命名**：`tdlibErrorResult(code:message:)` 還是更通用的 `structuredErrorResult(type:code:message:)`？傾向後者（為未來其他結構化 error 鋪路），但這個 change 只用到 TDLib path，可在 tasks 階段定。
- **Silent-ignore 是否 log**：silent return 時要不要寫 stderr？傾向 `fputs("info: TDLib code 406 silently ignored at <method>\n", stderr)`，既守 TDLib 協定（不 surface 給 caller）也保留 debug 痕跡。Tasks 階段確認。
