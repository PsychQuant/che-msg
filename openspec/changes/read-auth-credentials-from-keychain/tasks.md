## 1. Keychain 憑證來源

- [x] 1.1 先寫失敗的測試：新增 `che-telegram-all-mcp/Tests/TelegramAllLibTests/KeychainCredentialsTests.swift`，以假執行檔（測試在暫存目錄寫出的小 shell script）驅動 `SecurityCLICredentialSource`，逐列涵蓋 spec〈outcomes of a lookup〉表（`secret\n` → found、`a\nb\n` → found `a\nb`、空輸出 → absent、exit 44 → absent、exit 51 → unavailable、逾時 → timedOut），另驗證子程序的 stdin 是 null device（假執行檔讀 stdin 立即得到 EOF）、逾時時子程序在時限後被終止（`timeout: 0.5`，整個 lookup 在 2 秒內回來）、`KeychainLookup.found` 的 `description` 不含值。對應 Requirement「Keychain credential lookup is bounded and keeps no copy」。驗證：`swift test --skip E2ETests --filter KeychainCredentialsTests` 因型別不存在而失敗。
- [x] 1.2 [after: 1.1] 依 design〈以 `security` 子程序讀 Keychain，而非 Security.framework〉與〈逾時與失敗一律當作沒有值〉實作 `che-telegram-all-mcp/Sources/TelegramAllLib/KeychainCredentials.swift`：`KeychainCredential`（只有 phone 與 password）、`KeychainLookup`、`KeychainCredentialSource`、`SecurityCLICredentialSource`（絕對路徑、常數引數、stdin 接 null device、背景讀 stdout 到 EOF、stderr 丟棄、只去掉一個結尾換行、`timedOut` 與 `unavailable` 時 stderr 寫一行不含值的訊息）。驗證：1.1 的測試全過。
- [x] 1.3 [after: 1.2] 暫存 Keychain 的端到端測試：在 `KeychainCredentialsTests` 用 `security create-keychain` 於測試的暫存目錄建一個 Keychain 檔，放入合成的 `TELEGRAM_PHONE` 項目，以 `SecurityCLICredentialSource(keychainPath:)` 讀到值、讀不存在的 `TELEGRAM_2FA_PASSWORD` 得到 absent，最後 `security delete-keychain` 刪除；測試前後 `security list-keychains -d user` 的輸出必須相同（只帶路徑呼叫 `security`，不呼叫 `list-keychains -s`）。驗證：該測試通過，登入 Keychain 不受影響。

## 2. auto-fire 與 settle

- [x] 2.1 先寫失敗的測試：在 `AuthorizationSettleTests` 逐列涵蓋 spec〈settled by lookup status〉表，既有測試改為傳 `keychainLookup: .notNeeded` 且結果不變；在 `AutoFireChainTests` 新增「該送值、要查 Keychain、還是什麼都不做」的純函式測試：等電話且環境變數有值 → 送環境變數的值；沒有 → 查 `.phone`；等密碼同理查 `.password`；等驗證碼 → 永不查 Keychain（Requirement「SMS verification code is never auto-fired from environment」）；等參數 → 不查 Keychain。另為查詢狀態追蹤器寫測試：進入新狀態後世代號改變，舊查詢的結果被丟棄、不改變狀態。驗證：`swift test --skip E2ETests --filter 'AuthorizationSettleTests|AutoFireChainTests|CredentialLookupTracker'` 因新參數與型別不存在而失敗。
- [x] 2.2 [after: 2.1] 依 design〈不含密碼的查詢狀態取代存在檢查〉在 `che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift` 實作 `CredentialLookupStatus`、`authorizationIsSettled` 的 `keychainLookup` 參數、決定送值或查 Keychain 的純函式，以及以 lock 保護、帶世代號的查詢狀態追蹤器（只存狀態，不存值）。驗證：2.1 的測試全過，既有的 `AutoFireChainTests` 與 `AuthorizationSettleTests` 不需要改斷言。
- [x] 2.3 [after: 1.2, 2.2] 依 design〈憑證來源是注入 TDLibClient 的介面〉接線 `che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift`：`init` 多 `credentials:` 參數（預設 `SecurityCLICredentialSource()`）；進入等電話或等密碼且環境變數沒有值時，在 callback 內同步把查詢狀態設成 pending，之後在既有的 auto-fire `Task` 裡呼叫 `lookup` 並在世代號相符時送出；其他狀態把查詢狀態重設；`waitForAuthorizationToSettle` 傳入查詢狀態；新增 `lookUpKeychainCredential(_:)`。這完成 Requirement「Auto-fire chain covers params, phone, and password steps」的 client 端。驗證：`swift build` 通過、`swift test --skip E2ETests` 全過，並以 code review 確認 `handleAuthStateUpdate` 本身沒有任何 `Process` 或 `lookup` 呼叫。

## 3. auth_run

- [x] 3.1 先寫失敗的測試：在 `AuthRunHandlerTests` 逐列涵蓋 spec〈source precedence〉表（電話與密碼各一組），並驗證 `waitingForCode` 與 `waitingForParameters` 時 `keychainPhone`／`keychainPassword` 被忽略。對應 Requirement「`auth_run` MCP tool drives the state machine」。驗證：`swift test --skip E2ETests --filter AuthRunHandlerTests` 因 `decideAuthRunAction` 沒有新參數而失敗。
- [x] 3.2 [after: 3.1, 2.3] 依 design〈auth_run 的取值順序：呼叫端引數、環境變數、Keychain〉為 `decideAuthRunAction`（`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/AuthResponses.swift`）加上兩個 Keychain 參數；`Server` 的 `auth_run` 只在等電話或等密碼、且引數與環境變數都沒有值時才 `await tdlib.lookUpKeychainCredential(...)`；`auth_run` 的工具說明改寫為「呼叫端引數、環境變數、Keychain」三個來源。驗證：3.1 的測試全過，`swift test --skip E2ETests` 全過。

## 4. wrapper 回歸測試

- [x] 4.1 依 design〈wrapper 不 export 電話與 2FA 密碼〉新增 `tests/che-telegram-mcp/test-wrapper-no-auth-secrets.sh`：沿用 `tests/lib/wrapper_harness.sh` 的私人 HOME，另放一個對四個項目（API ID、API hash、電話、2FA 密碼）都回合成值的假 `security`，假 binary 只記錄它看得到的 `TELEGRAM_*` 變數名稱，斷言只有 `TELEGRAM_API_HASH` 與 `TELEGRAM_API_ID`。這是防止日後改回修法 1 的守門測試，對現行 wrapper 一開始就會通過；另以暫時在 scratch 複本的 wrapper 裡加一行 export 確認測試會失敗（不改 repo 裡的 wrapper）。驗證：`bash tests/che-telegram-mcp/test-wrapper-no-auth-secrets.sh` 通過，對 export 版本失敗。

## 5. 文件與收尾

- [x] 5.1 文件說明 Keychain 來源：`plugins/che-telegram-mcp/README.md` 的 Track A 寫明電話與 2FA 密碼從 0.9.0 起由 binary 在需要時讀 Keychain、環境變數優先、密碼錯了要先更新 Keychain 項目；`che-telegram-all-mcp/README.md` 的環境變數表與 `auth_run` 流程補上 Keychain 這個來源；`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift` 的 `--help` 中電話與 2FA 兩行註明「or the Keychain item」，並在 `CLIBootstrapTests` 斷言這兩行提到 Keychain（`TELEGRAM_AUTH_CODE` 那兩行屬於 #87，不在這個 change）。驗證：`swift test --skip E2ETests --filter CLIBootstrapTests` 通過，content review 兩份 README。
- [x] 5.2 [after: 5.1] `che-telegram-all-mcp/CHANGELOG.md` 與 `plugins/che-telegram-mcp/CHANGELOG.md` 的 `[Unreleased]` 各記一筆（binary 會讀 Keychain 的電話與 2FA 密碼、README 的說法自 0.9.0 起成立），不改任何版號。驗證：content review（這條 branch 從 `main` 開，沒有 #40 的 `make check-pins`；版號一致性在發版時由 #40 的流程檢查）。
- [x] 5.3 [after: 1.3, 2.3, 3.2, 4.1, 5.2] 整體驗證：`swift test --skip E2ETests`（`che-telegram-all-mcp`）、所有 `tests/che-telegram-mcp/*.sh` 與 `tests/che-archive-lines/*.sh`、`claude plugin validate .` 與兩個 plugin、`spectra validate read-auth-credentials-from-keychain` 全部通過。驗證：各命令的輸出。

## 6. verify 第 1 輪的修正

- [x] 6.1 先寫失敗的測試，再把 `SecurityCLICredentialSource` 改成 `-g`：`KeychainCredentialsTests` 以假執行檔逐列涵蓋 spec〈outcomes of a lookup〉更新後的表（引號形式、值裡有引號、hex 解成 UTF-8、hex 含換行、看起來像 hex 的引號文字不解碼、空值、沒有 `password:` 行、非 UTF-8 的 hex），另驗證輸出超過 64 KiB 不採用、執行檔不存在時 0.5 秒內回 `unavailable(-1)`、逾時一定回 `timedOut`；暫存 Keychain 的端到端測試多存一個 `密碼pässwörd` 並讀回原值。驗證：改之前 3 個測試失敗，改之後 `swift test --skip E2ETests --filter KeychainCredentialsTests` 23 個全過。
- [x] 6.2 [after: 6.1] 把背景送值抽成 `runCredentialPlan`（`che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift`），先寫 `CredentialPlanRunnerTests`（環境變數直接送、Keychain 查一次送一次、沒有值或逾時不送且判為定案、狀態已變不送、送出失敗判為定案並把錯誤丟回給呼叫端），`TDLibClient` 改呼叫它。驗證：測試先因沒有 `runCredentialPlan` 而編譯失敗，之後全過。
- [x] 6.3 [after: 6.2] `auth_run` 在 Keychain 查詢後重讀狀態（`authRunKeychainValues`，先寫 `AuthRunHandlerTests` 的三個測試），並在背景正從 Keychain 送值時等最多 15 秒再回答。驗證：測試先因沒有 `authRunKeychainValues` 而編譯失敗；`swift test --skip E2ETests` 三個 bundle 全過。
- [x] 6.4 spec delta：coordination 的 Keychain Requirement 改成 `-g` 並更正表格（原本 `a\nb\n` 那一列描述的輸出 `security` 從不產生）、`auth_run` 補「查詢後重讀狀態」與「等背景送值」；新增 `telegram-tdlib-lifecycle` 的 MODIFIED delta（Requirement「TDLib opens on first use, not at startup」：Keychain 查詢中或找到未送算未定案，由 `AuthorizationSettleTests` 涵蓋）與 `telegram-auth-error-reporting` 的 MODIFIED delta（Requirement「Auto-fire failure surfacing via auth_status」：拿掉已刪除的 `autoSendPhoneIfAvailable`／`autoSendPasswordIfAvailable`，送出失敗判為定案並記錄錯誤，由 `CredentialPlanRunnerTests.testAFailedSubmissionSettlesAndIsReported` 涵蓋）。驗證：`spectra validate read-auth-credentials-from-keychain`。

