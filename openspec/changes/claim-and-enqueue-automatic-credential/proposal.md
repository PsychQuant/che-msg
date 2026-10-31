## Why

#96 讓每個授權狀態最多自動送出一次電話號碼或 2FA 密碼，claim 在記錄狀態變更的同一把 client lock 下取得。但 claim 與 TDLibKit 收下請求之間隔著 async 的步驟（`submit` → coalesced task → 新的 `Task` → TDLibKit 的 async API），client lock 不能跨過這些步驟。兩件事會落進這個空隙（PsychQuant/che-msg#98）：

1. claim 之後才記錄的狀態變更：值仍會為已經離開的狀態送出。
2. claim 之後才開始、而且在自動值進入 coalesced task 之前就完成的明確呼叫（`auth_run`、`auth_send_phone`、`auth_send_password`、CLI）：自動值會另外送出自己的請求。在驗證碼那一步送出的電話號碼會讓登入重來，Telegram 再寄一次驗證碼。

issue 上的 Decision comment 選了選項 B：保留 coalesced 路徑，把 claim 與送出請求併成 client lock 下的一步。

## What Changes

- 自動送出的電話號碼與 2FA 密碼：claim、建立該方法的 coalesced task、把請求交給 TDLibKit，三件事在 client lock 下一步完成。交出請求用 TDLibKit 的 callback 形式，它只把請求排進 TDLibKit 的佇列，不阻塞、不 suspend；coalesced task 之後只等這個請求的回應。
- 明確呼叫的 `sendPhoneNumber`／`sendPassword` 也在同一把鎖下建立或加入 coalesced task。自動值 claim 之後的明確呼叫一定加入自動請求、得到它的結果，TDLib 只收到一個請求；claim 之前的明確呼叫照 #96 讓 claim 失敗。
- 授權狀態與電話、密碼的請求路徑從 `TDLibClient` 移到內部的 `AuthCoordinator`，這兩個 TDLib 請求經過可替換的 `CredentialRequestSending`（正式版是 TDLibKit 的 callback 形式）。測試用假的 sender 在 production 路徑上驗證兩個空隙。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `telegram-auth-coordination`: 新增「自動送出的值在 client lock 下一步 claim 並交給 TDLib」的要求（Requirement: An automatic credential is claimed and handed to TDLib in one step）。既有的「Coalesced execution of authentication methods」不變：自動值仍走 coalesced 路徑。

## Impact

- 受影響的 spec：`telegram-auth-coordination`
- 程式：`che-telegram-all-mcp/Sources/TelegramAllLib/AuthCoordinator.swift`（新）、`che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift`、`che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift`、`che-telegram-all-mcp/Sources/TelegramAllLib/AuthCoalescing.swift`
- 測試：`che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthCoordinatorTests.swift`（新）、`che-telegram-all-mcp/Tests/TelegramAllLibTests/CredentialPlanRunnerTests.swift`
- 文件：`che-telegram-all-mcp/CHANGELOG.md`
- 公開 API 不變：`TDLibClient` 的方法簽名照舊，只是轉交給 `AuthCoordinator`。
