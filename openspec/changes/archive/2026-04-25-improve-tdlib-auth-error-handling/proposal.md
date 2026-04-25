## Why

`che-telegram-all-mcp` issue #1 揭露 v0.2.0 prebuilt binary 的 auth 流程完全壞掉。Root cause 之一（snake_case decoder bug，Issues A+B）已在 v0.3.0 source 修復；但 issue #1 的 **Issue C 主因——TDLib error masking** 至今仍存在所有版本。

具體現象：`TDLibClient.setParameters` / `sendPhoneNumber` / `sendAuthCode` 把 TDLib 回的 `TDLibKit.Error`（含 `code: Int` + `message: String`）直接 propagate，呼叫方只看到「`TDLibKit.Error error 1`」這種泛型訊息，看不到 `code` 也看不到 `message`。後果：使用者撞 flood-wait、phone code invalid、TDLib internal state error 都長同一張臉，無法自助 debug，也無從決定要重試還是等冷卻。

同時 v0.2.0 那個已修但未發 binary 的 decoder 回歸也提醒我們：缺乏 regression test 鎖住 `JSONDecoder.keyDecodingStrategy` 是現存的 latent risk。

## What Changes

- 在 `TDLibClient.setParameters`、`sendPhoneNumber`、`sendAuthCode`、`sendPassword` 四個 auth call site 加 `do/catch` wrap，把 `TDLibKit.Error` unwrap 為 `TDError.tdlibError(code:message:)`（**結構化欄位**，不 stringify）
- 修改 `TDError.tdlibError` 的 case associated value：從 `String` 改為 `(code: Int, message: String)`（**BREAKING**：影響 `TDError` API surface，但目前只有 `che-telegram-all-mcp` 內部用，無外部依賴）
- TDLib 協定保留的 **error code 406** 處理：`code == 406` 時不 surface 給 caller，由 `TDLibClient` 內部 silently swallow（重新 throw `.notAuthenticated` 或回傳 sentinel — 細節在 design.md 決定）
- 新增 regression test：assert `JSONDecoder.keyDecodingStrategy == .convertFromSnakeCase`（防止 v0.2.0 那個 critical bug 再次潛入）
- 新增 unit tests：mock `TDLibKit.Error(code: 420, message: "FLOOD_WAIT_30")` → assert `TDError.tdlibError` 帶完整 code/message；mock `code: 406` → assert silent-ignore
- 更新 `Server.swift` 的 auth tool handler error formatting，把 structured error 序列化為 MCP response（`{"error": {"code": 420, "message": "FLOOD_WAIT_30"}}`）讓 AI agent 拿到結構化資訊
- 不動 `TDError.notAuthenticated` 與 `.missingCredentials`（這兩個 case 不變）

## Non-Goals (optional)

> 此 change 將建立 design.md，所以 Non-Goals 寫在那邊，這裡留白。

## Capabilities

### New Capabilities

- `telegram-auth-error-reporting`: 定義 Telegram MCP server 在 auth 流程中遇到 TDLib 錯誤時的 reporting contract — 結構化錯誤欄位、code 406 silent-ignore rule、JSON decoder snake_case invariant、MCP response 錯誤序列化格式。

### Modified Capabilities

(none)

## Impact

- **Affected code**:
  - `che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift`（修改 `TDError` enum、四個 auth method 加 unwrap、JSONDecoder regression invariant）
  - `che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift`（auth tool handler 改用結構化 error 序列化）
  - `che-telegram-all-mcp/Tests/TelegramAllLibTests/`（新增 `TDLibAuthErrorTests.swift`，可能也加 `JSONDecoderRegressionTests.swift`）
- **Affected specs**: 新增 `openspec/specs/telegram-auth-error-reporting/spec.md`
- **Out of scope**（拆獨立 issue）:
  - Issue C tertiary: auto-set `Task` race fix（C1/C2/C3 三選一設計）
  - `TELEGRAM_2FA_PASSWORD` auto-send 的同類 race
  - 發布 v0.4.x prebuilt binary 到 GitHub Releases（process 行為，hotfix 處理）
- **Dependencies**: 無新外部依賴；`TDLibKit.Error` 已在依賴內（`TDLibKit/Sources/.../Error.swift` 確認 `code: Int` + `message: String`）
- **Breaking surface**: `TDError.tdlibError` enum case 從 `(String)` 變 `(code: Int, message: String)`。內部消費者只有 `Server.swift`（會一起更新）；無外部公開 API。
