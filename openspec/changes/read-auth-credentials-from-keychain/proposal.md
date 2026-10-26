## Problem

plugin README 的 Track A 叫使用者把電話號碼（`TELEGRAM_PHONE`）與 2FA 密碼（`TELEGRAM_2FA_PASSWORD`）存進 Keychain，並說它們會「auto-entered」。實際上沒有任何元件讀這兩個 Keychain 項目：登入時 `auth_run` 回報缺 `phone`／`password`，使用者只能在對話裡手打，**2FA 密碼因此進入對話紀錄**。照 README 存了 Keychain 的人什麼也沒得到（PsychQuant/che-msg#49）。

## Root Cause

「Keychain → binary」這條鏈對電話與 2FA 密碼沒有任何一段負責：

- wrapper（`plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh`）只從 Keychain 讀 `TELEGRAM_API_ID`、`TELEGRAM_API_HASH` 並 export。
- binary 只從 process 環境讀電話與密碼：`TDLibClient` 的三個 auto-fire 函式與 `waitForAuthorizationToSettle`、`Server.swift` 的 `auth_run`。binary 本身完全不碰 Keychain。
- spec `telegram-auth-coordination` 的 Requirement「Auto-fire chain covers params, phone, and password steps」寫「present in the process environment or available via the wrapper-injected variable」，假設了一個 wrapper 從未做的注入；沒有任何 Requirement 規定誰從 Keychain 取這兩個值。
- 所有測試都在斷點的兩側各自成立（`AutoFireChainTests`、`AuthRunHandlerTests` 直接餵字串；wrapper 測試的假 `security` 只回答 API 憑證），沒有測試跨過 Keychain 到 binary 的邊界。

## Proposed Solution

依維護者 2026-10-24 選定的修法 2：**binary 只在 TDLib 等電話或等 2FA 密碼時讀 Keychain，用完即丟**；wrapper 維持不 export 這兩個值。

- `TelegramAllLib` 新增一個可注入的 Keychain 憑證來源。正式版以絕對路徑執行 `/usr/bin/security find-generic-password -a che-telegram-all-mcp -s <TELEGRAM_PHONE|TELEGRAM_2FA_PASSWORD> -w`，有逾時、不快取、不寫 log、錯誤訊息不帶值。
- TDLib 進入 `waitingForPhoneNumber` 或 `waitingForPassword`、而環境變數沒有值時，在既有的 auto-fire `Task` 裡讀 Keychain 並送出；TDLib 的 callback 執行緒不做任何子程序呼叫。
- 用一個不含密碼的查詢狀態（查詢中／找到／沒有）讓 `authorizationIsSettled` 在查詢期間不判為定案，避免 #58 修掉的競態重現。
- `auth_run` 取值的優先順序改為「呼叫端引數 > 環境變數 > Keychain」；等驗證碼時任何路徑都不讀 Keychain。
- spec `telegram-auth-coordination` 以 delta 修改 auto-fire 的來源表、更正「wrapper-injected variable」一句，並新增「Keychain 查詢有時限、不留副本」的 Requirement。
- 文件：plugin README Track A、`che-telegram-all-mcp/README.md`、`--help` 的電話與 2FA 兩行、兩份 CHANGELOG 的 `[Unreleased]`。

**待確認的假設**（不是維護者的決定，見 #49 comment 6411790341）：讀取用 `security` 子程序而不是 Security.framework。2026-10-26 在暫存 Keychain 實測：帶 `-w` 讀取 exit 0、項目不存在 exit 44、不跳授權視窗；從 ad-hoc 簽章 binary 用 Security.framework 讀的實測沒有跑（預期會跳視窗）。憑證來源放在介面後面，改用 Security.framework 只需要換正式版那一個型別。

## Non-Goals (optional)

見 design.md 的 Goals / Non-Goals。

## Success Criteria

- Keychain 有 `TELEGRAM_PHONE`、環境變數沒有時，TDLib 進入等電話狀態後會送出 Keychain 的值；`TELEGRAM_2FA_PASSWORD` 同理。由注入假來源的單元測試驗證。
- 環境變數與 Keychain 同時有值時用環境變數；呼叫端引數優先於兩者。
- Keychain 沒有項目、查詢失敗或逾時時，不送出任何值、狀態不變，`auth_run` 回 `needs_args` 指出缺的欄位。
- 查詢進行中 `authorizationIsSettled` 回 false；查詢結束且沒有值時回 true（#58 的競態以測試釘住）。
- 等驗證碼時 Keychain 來源一次都不被呼叫。
- 正式版憑證來源在暫存 Keychain 檔裡對合成項目端到端取值成功，測完刪除暫存 Keychain，不碰使用者的登入 Keychain。
- plugin 測試：即使假 `security` 對四個項目都有值，wrapper 啟動的 binary 也看不到 `TELEGRAM_PHONE`、`TELEGRAM_2FA_PASSWORD`。
- `swift test --skip E2ETests`（all-mcp）與 plugin 測試全過。

## Impact

- Affected specs: `telegram-auth-coordination`（修改）
- Affected code:
  - Modified: che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift, che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift, che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/AuthResponses.swift, che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift, che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift, che-telegram-all-mcp/README.md, che-telegram-all-mcp/CHANGELOG.md, plugins/che-telegram-mcp/README.md, plugins/che-telegram-mcp/CHANGELOG.md, che-telegram-all-mcp/Tests/TelegramAllLibTests/AutoFireChainTests.swift, che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthRunHandlerTests.swift
  - New: che-telegram-all-mcp/Sources/TelegramAllLib/KeychainCredentials.swift, che-telegram-all-mcp/Tests/TelegramAllLibTests/KeychainCredentialsTests.swift, tests/che-telegram-mcp/test-wrapper-no-auth-secrets.sh
  - Removed: none
- 發布：行為要隨新 binary（0.9.0）才到使用者手上；版號與 plugin pin 走 #40 的發版流程，不在這個 change 裡改。
- 同一條 branch 另有 #87（`--help` 的 `TELEGRAM_AUTH_CODE`）與 #51（README 與提示訊息把密鑰寫在 `security -w` 後面）的獨立 commit，不屬於這個 change。
