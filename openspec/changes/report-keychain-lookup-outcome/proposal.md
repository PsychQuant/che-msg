## Why

#49 讓 che-telegram-all-mcp 在 Telegram 等電話號碼或 2FA 密碼時，從 Keychain 讀值送出。查詢沒有拿到值時（沒存、Keychain 鎖住而 10 秒逾時、`security` 失敗或輸出讀不懂），只在 server 的 stderr 留一行；`auth_status` 與 `auth_run` 的回應跟完全沒查過一樣：`waitingForPassword`、`required_args: ["password"]`、「Enter your two-factor authentication password」。讀到這個回應的 agent 會請使用者把 2FA 密碼打進對話，正是 #49 要關掉的洩漏途徑；使用者也分不出是「沒存」還是「存了但 Keychain 鎖住」（PsychQuant/che-msg#95）。

## What Changes

- 新增不含秘密的查詢結果分類：`not_stored`、`timed_out`、`unavailable`，由 Keychain 查詢結果換算，找到值時沒有分類。
- 每個 TDLib 狀態記住最後一次 Keychain 查詢的分類；狀態一變就清掉。背景 auto-fire 與 `auth_run` 自己的查詢都會記錄，`auth_run` 找到值時清掉先前的分類。
- `auth_status` 與 `auth_run` 的回應多一個 `keychain_lookup` 欄位：null，或 `{"credential": "phone" | "password", "outcome": "not_stored" | "timed_out" | "unavailable"}`。
- `waitingForPassword` 的 `next_step` 提示先說怎麼把密碼存進 Keychain（或解鎖）再呼叫 `auth_run`，並說明用 `password` 參數會讓密碼經過對話；有分類時提示開頭先講原因。電話號碼的提示在有分類時也講原因。

## Non-Goals

- 不改 Keychain 的讀法（仍是 `/usr/bin/security`、10 秒上限）與送值的順序（呼叫端參數 > 環境變數 > Keychain）。
- 不把 `security` 的輸出或結束碼放進回應；`unavailable` 只說讀取失敗，細節留在 stderr。
- 不處理送出時機的競態與 CLI 的 auto-fire（#96）。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `telegram-auth-error-reporting`: 新增「Keychain 查詢沒有拿到值時，`auth_status`／`auth_run` 說明原因分類並把 Keychain 放在提示的第一順位」的要求。

## Impact

- 受影響的 spec：`telegram-auth-error-reporting`
- 程式：`che-telegram-all-mcp/Sources/TelegramAllLib/KeychainCredentials.swift`、`che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift`、`che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift`、`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/AuthResponses.swift`、`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift`
- 測試：`che-telegram-all-mcp/Tests/TelegramAllLibTests/`、`che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/`
- 文件：`che-telegram-all-mcp/README.md`（`auth_status` 欄位）、`che-telegram-all-mcp/CHANGELOG.md`
