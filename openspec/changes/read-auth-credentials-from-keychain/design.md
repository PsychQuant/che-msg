## Context

`che-telegram-all-mcp` 的登入由 TDLib 的授權狀態機驅動。進入 `WaitTdlibParameters`、`WaitPhoneNumber`、`WaitPassword` 時，`TDLibClient.handleAuthStateUpdate`（在 TDLib 的 update callback 執行緒上被呼叫）會呼叫對應的 `autoXxxIfAvailable`，用純函式 `decideAutoFire` 判斷要不要送，要送就開一個 `Task` 走 coalesced path。目前三個值都只從 `ProcessInfo.processInfo.environment` 讀。

另外兩處也讀同一批環境變數：
- `TDLibClient.waitForAuthorizationToSettle` 每 50 ms 呼叫 `authorizationIsSettled`，讓 on-demand 開啟的 client 在登入走到盡頭前不回第一個呼叫（#58）。
- `Server` 的 `auth_run` 用純函式 `decideAuthRunAction` 決定這一步做什麼。

plugin 的 wrapper 只把 `TELEGRAM_API_ID`、`TELEGRAM_API_HASH` 從 Keychain 讀出來 export，電話與 2FA 密碼沒有任何元件從 Keychain 讀。維護者選了修法 2：binary 只在 TDLib 要的時候自己讀 Keychain。

測試的現況：`TDLibClient` 要真的 TDLib 才能建立（`init` 會建立 TDLib client），所以 auto-fire 與 settle 的邏輯一直以純函式（`decideAutoFire`、`authorizationIsSettled`、`decideAuthRunAction`）測試，`TDLibClient` 只做接線。這個 change 沿用同一個模式。

## Goals / Non-Goals

**Goals:**

- 電話與 2FA 密碼存在 Keychain、環境變數沒有時，auto-fire 與 `auth_run` 會用 Keychain 的值，不必在對話裡輸入。
- Keychain 讀取有時限、不阻塞 TDLib 的 callback 執行緒、不留下值的副本。
- #58 的 settle 行為在 Keychain 路徑上仍成立。
- wrapper 不 export 這兩個值，有測試釘住。

**Non-Goals:**

- 不讀驗證碼（spec 本來就禁止）。
- API ID／hash 仍只看環境變數（wrapper 已經處理）。
- 不改 wrapper 的下載、版號或啟動流程，也不改版號（0.9.0 走 #40 的發版流程）。
- 不處理 auth skill 的文件（#48）與「沒有 Keychain 項目時引導使用者去存」（Diagnosis 的 Residue）。
- 不改成 Security.framework（見第一個決策）。
- 不在錯誤的 2FA 密碼反覆送出時做節流（環境變數路徑今天的行為也一樣）。

## Decisions

### 以 `security` 子程序讀 Keychain，而非 Security.framework

正式版以絕對路徑執行 `/usr/bin/security find-generic-password -a che-telegram-all-mcp -s <service> -g`。理由：這跟 README 的存法與 wrapper 讀 API 憑證走同一條信任路徑；用 `security add-generic-password` 建的項目，ACL 預設就信任 `/usr/bin/security`，所以不跳授權視窗，也不受 binary 簽章身分影響。2026-10-26 在暫存 Keychain 實測：讀到值 exit 0、項目不存在 exit 44、不跳視窗。

用 `-g` 而不是 `-w`（verify 第 1 輪改的）：`-w` 遇到值裡有任何非 ASCII 或控制字元，就把整個值印成小寫 hex，而一個本來就由 hex 字元組成的 ASCII 值印出來一模一樣，所以無法還原。存 `密碼` 這種 2FA 密碼時，送出去的是它的 hex，每次都錯。`-g` 把屬性印到 stdout、把值印到 stderr 的一行 `password:`，可列印的值寫成 `password: "<值>"`，其他寫成 `password: 0x<HEX>  "<跳脫>"`，兩種形式分得開。改用 Security.framework 也能解決這個問題，但規格的 Requirement 寫明了 `/usr/bin/security` 與 `-g`，換的時候要一起改。

替代方案 Security.framework（`SecItemCopyMatching`）：較「正規」，但對 binary 而言是「另一個應用程式第一次讀這個項目」，預期會跳授權視窗，而且 ad-hoc 簽章下每次升級 cdhash 都變、可能每次都要重新授權。這個預期沒有實測（會在畫面上留下授權視窗，而實測時維護者不在）。**這是待維護者確認的假設**（#49 comment 6411790341）；憑證來源放在介面後面，換成 Security.framework 時程式碼只動正式版那一個型別（spec 也要一起改，見下段）。

### 憑證來源是注入 TDLibClient 的介面

`TelegramAllLib` 新增 `KeychainCredentials.swift`：

- `KeychainCredential`：只有 `.phone`（service `TELEGRAM_PHONE`）與 `.password`（service `TELEGRAM_2FA_PASSWORD`）兩個值。驗證碼與 API 憑證刻意不在列舉裡，型別上就查不到。
- `KeychainLookup`：`found(String)`、`absent`、`timedOut`、`unavailable(exitStatus:)`；文字描述（`description`）不印出值。
- `KeychainCredentialSource` protocol：一個 `lookup(_:) async -> KeychainLookup`。
- `SecurityCLICredentialSource`：正式版。初始化參數 `executable`（預設 `/usr/bin/security`）、`keychainPath`（預設 nil，即使用者的預設搜尋清單）、`timeout`（預設 10 秒）只給測試用：測試用假執行檔與暫存 Keychain 檔驗證行為，不需要環境變數開關。

`TDLibClient.init` 多一個 `credentials: KeychainCredentialSource` 參數，預設 `SecurityCLICredentialSource()`，所以 MCP server 的建構點不用改。`telegram-all` CLI 的兩處後來改傳 `NoKeychainCredentialSource()`（#96）：CLI 的每個指令都會打開 TDLib，用 Keychain 會在登出時送出存好的電話號碼，也會和 `auth-phone` 搶先。`TDLibClient` 另提供 `lookUpKeychainCredential(_:) async -> String?` 給 `auth_run` 用，同一個注入來源。

替代方案：直接在 `TDLibClient` 裡寫 `Process` 呼叫。被否決：無法在沒有 TDLib 的單元測試裡驗證逾時、exit status 與不洩值。

### 不含密碼的查詢狀態取代存在檢查

Diagnosis 建議進入等待狀態時跑一次不帶 `-w` 的存在檢查，結果當作布林傳進 `authorizationIsSettled`。這裡改成記錄一個不含密碼的查詢狀態 `CredentialLookupStatus`：`notNeeded`、`pending`、`found`、`absent`。

理由：存在檢查本身也是子程序，不能在 callback 執行緒上跑；一旦改到 `Task` 裡跑，在它跑完之前 settle 一樣會誤判，所以「查詢中」這個狀態本來就需要。有了它之後，直接在 `Task` 裡做帶 `-w` 的讀取就好，存在檢查不提供新資訊，還多一次子程序。

運作方式：
- 進入 `waitingForPhoneNumber` 或 `waitingForPassword`、而環境變數沒有值時，callback 在 lock 內同步把狀態設成 `pending`，並把世代號加一，接著才開 `Task` 讀取。
- `Task` 讀完後在 lock 內比對世代號：沒變才寫入 `found` 或 `absent`；`found` 時送出值。
- 其他狀態一律設成 `notNeeded`，並把世代號加一。這樣舊狀態的 `Task` 晚到時，不會覆寫新狀態的查詢狀態，也不會送出過時的值。
- 查詢狀態由追蹤器自己的 lock 保護；進入新狀態時，`TDLibClient` 在持有 `authState` 那把 lock 的期間呼叫追蹤器，所以兩者一起改變（spec「Authentication state and credential cache are lock-protected」）。鎖的順序固定是外層 `authState`、內層追蹤器，追蹤器從不反過來取外層的 lock。

`authorizationIsSettled` 多一個 `keychainLookup: CredentialLookupStatus` 參數：
- `pending` 與 `found` 都不算定案。
- `absent` 算定案。
- `notNeeded` 時沿用今天的邏輯。

auto-fire 送出失敗會設 `hasAutoFireError`，照舊算定案。

### auth_run 的取值順序：呼叫端引數、環境變數、Keychain

`decideAuthRunAction` 多 `keychainPhone`、`keychainPassword` 兩個參數，順序是引數 > 環境變數 > Keychain；`waitingForCode` 與 `waitingForParameters` 不看這兩個參數。

`Server` 的 `auth_run` 只在以下條件都成立時，才先 `await` 一次 Keychain 讀取，把結果傳進去：
- 狀態是 `waitingForPhoneNumber` 或 `waitingForPassword`；
- 呼叫端沒給對應引數；
- 環境變數也沒有。

讀取在 `auth_run` 自己的 async 路徑裡做，不在 callback 上。

跟背景 auto-fire 同時送出同一個值時，由既有的 coalesced path 合併（spec「Coalesced execution of authentication methods」）。

替代方案：`auth_run` 不讀 Keychain，只靠背景 auto-fire。被否決：背景 auto-fire 失敗一次（例如網路錯誤）之後，使用者重跑 `auth_run` 就只能在對話裡輸入密碼，正是這張 issue 要避免的事。

### 逾時與失敗一律當作沒有值

10 秒內子程序沒結束就 `terminate()`，結果記為 `timedOut`；exit 44 為 `absent`；其他非零 exit 為 `unavailable(exitStatus:)`；exit 0 但值是空的也是 `absent`。除了 `found`，其他結果對 auto-fire 與 `auth_run` 都等同「沒有值」：不送出、狀態不變、`auth_run` 回 `needs_args`。

`timedOut` 與 `unavailable` 時，在 stderr 寫一行，只寫憑證名稱與原因（逾時秒數或 exit status），不寫值。MCP 的協定走 stdout，所以 stderr 不會進 tool 回應。

子程序細節：
- stdin 接 null device，避免 `security` 讀到 MCP 的 JSON-RPC 輸入。
- stdout（項目屬性）丟棄。
- stderr 在背景持續讀，最多 64 KiB，避免子程序因 pipe 滿而卡住；超過上限的輸出不採用。
- 只讀 stderr 第一個以 `password:` 開頭的行：引號形式取外層引號之間的文字，hex 形式解成 UTF-8；解不出來、沒有這一行，都當作沒有值並在 stderr 寫一行原因（不含值）。
- 逾時先記錄結果再 `terminate()`，所以逾時不會被回報成 signal 的 exit status；子程序根本沒啟動時不等輸出。
- 診斷訊息經 `diagnostics` 參數送出（預設寫 stderr），測試可以收集它們、檢查裡面沒有值。

10 秒是 Diagnosis 的建議值，屬於估計，沒有量測。它只需要大於正常讀取的時間：2026-10-26 的暫存 Keychain 實測中讀取立即回來（沒有計時），所以 10 秒應有足夠餘裕；要確認可在第一次真實登入時量 `security` 的耗時；它也只決定 Keychain 鎖住時要等多久才放棄，不影響正確性。

### wrapper 不 export 電話與 2FA 密碼

被否決的修法 1 是讓 wrapper 也 export 這兩個值；那會讓 2FA 密碼成為常駐 MCP process 的環境變數，同一使用者的其他 process 讀得到。新增 plugin 測試 `tests/che-telegram-mcp/test-wrapper-no-auth-secrets.sh`：用 `tests/lib/wrapper_harness.sh` 起真的 wrapper，假 `security` 對四個項目都回合成值，假 binary 只記錄它看得到的 `TELEGRAM_*` 變數名稱，斷言只有 API ID 與 API hash。

## Implementation Contract

**Behavior**：
- 使用者照 README 把電話與 2FA 密碼存進 Keychain 後，登入只需要在對話裡提供簡訊驗證碼。
- 環境變數仍優先於 Keychain（SSH 或遠端設定照舊）。
- `auth_run` 的引數優先於兩者。
- Keychain 沒有項目、鎖住或讀取失敗時，行為與今天相同：`auth_run` 回 `needs_args`，由呼叫端提供。

**Interface**：

```swift
// TelegramAllLib/KeychainCredentials.swift
public enum KeychainCredential: String, CaseIterable, Sendable {
    case phone = "TELEGRAM_PHONE"
    case password = "TELEGRAM_2FA_PASSWORD"
}
public enum KeychainLookup: Equatable, Sendable, CustomStringConvertible {
    case found(String), absent, timedOut, unavailable(exitStatus: Int32)
    public var value: String? { get }          // found 時的值，其餘 nil
    public var description: String { get }    // found 印成 "found(<redacted>)"
}
public protocol KeychainCredentialSource: Sendable {
    func lookup(_ credential: KeychainCredential) async -> KeychainLookup
}
public struct SecurityCLICredentialSource: KeychainCredentialSource {
    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/security"),
                keychainPath: String? = nil, timeout: TimeInterval = 10,
                diagnostics: @escaping @Sendable (String) -> Void = /* 寫 stderr */)
    static func parsePasswordLine(_ stderr: Data) -> PasswordLine   // 讀 `-g` 的 password: 行
}

// TelegramAllLib/AutoFire.swift
internal enum CredentialLookupStatus: Equatable { case notNeeded, pending, found, absent }
internal func authorizationIsSettled(state:hasAutoFireError:envApiId:envApiHash:envPhone:envPassword:keychainLookup:) -> Bool
internal final class CredentialLookupTracker   // stateChanged(lookingUp:) / finish / isCurrent / isInFlight / submissionFailed
internal func runCredentialPlan(_:generation:tracker:lookup:submit:recordFailure:) async

// TelegramAllLib/TDLibClient.swift
public init(logVerbosity: Int = 0, syncState: TDLibSyncState? = nil,
            credentials: KeychainCredentialSource = SecurityCLICredentialSource()) async throws
public func lookUpKeychainCredential(_ credential: KeychainCredential) async -> String?
public var isSubmittingKeychainCredential: Bool { get }   // auth_run 等背景送值

// CheTelegramAllMCPCore/AuthResponses.swift
internal func decideAuthRunAction(state:phone:code:password:envApiId:envApiHash:envPhone:envPassword:keychainPhone:keychainPassword:) -> AuthRunAction
internal func authRunKeychainValues(lookedUp:value:stateNow:phone:password:envPhone:envPassword:) -> (phone: String?, password: String?)
internal func decideAuthRunActionAfterLookup(lookedUp:value:stateNow:phone:code:password:envApiId:envApiHash:envPhone:envPassword:) -> AuthRunAction
```

`decideAutoFire` 的簽章不變；`envAuthCode` 參數由 #87 處理，不在這個 change 裡。

**Failure modes**：
- 逾時與非 44 的失敗：stderr 一行（憑證名稱＋原因），當作沒有值。
- 送出失敗：照舊記為 auto-fire error，由 `auth_status` 回報；錯誤內容來自 TDLib，不含 Keychain 的值。
- 舊狀態的查詢晚到：因世代號不符而丟棄，不送出。

**Acceptance criteria**：
- `KeychainCredentialsTests`：用假執行檔驗證 spec〈outcomes of a lookup〉表的每一列，stdin 是 null device，逾時會終止子程序，`description` 不含值。另有暫存 Keychain 檔的端到端測試：建立後放入合成項目，讀到值，最後刪除；測試前後 `security list-keychains -d user` 相同，不碰登入 Keychain。
- `AuthorizationSettleTests`：spec〈settled by lookup status〉表的每一列。
- 狀態追蹤器的測試：世代號不符時丟棄結果。
- `AuthRunHandlerTests`：spec〈source precedence〉表的每一列，並包含 `waitingForCode` 時 Keychain 參數被忽略。
- plugin 測試 `test-wrapper-no-auth-secrets.sh` 通過。
- `swift test --skip E2ETests`（all-mcp）與所有 plugin 測試全過。

**Scope**：
- 範圍內：上面的 Swift 檔、對應測試、spec delta、plugin 測試、兩份 README 的 Keychain 說明、`--help` 的電話與 2FA 兩行、兩份 CHANGELOG 的 `[Unreleased]`。
- 範圍外：#87 的 `TELEGRAM_AUTH_CODE` 與 `envAuthCode`、#51 的 `-w` 寫法、版號、wrapper 行為、#48 的 skill 文件。

## Risks / Trade-offs

- [Keychain 鎖住或授權視窗沒人按] → 10 秒逾時並終止子程序，退回 `needs_args`；第一個呼叫最多多等 10 秒。
- [錯誤的 2FA 密碼存在 Keychain] → 每次 `auth_run` 都會再送一次，可能碰到 Telegram 的頻率限制；與環境變數路徑今天的行為相同，在 README 寫明「密碼錯了先更新 Keychain 項目」。
- [Swift `String` 無法清零] → 「不留副本」指不保留參照，不是擦除記憶體；值只存在送出它的 `Task` 的區域變數。
- [沒有存 Keychain 的人] → 仍要在對話裡輸入 2FA 密碼；這個修法縮小風險，沒有消除它（#48 承接引導）。
- [`TDLibClient` 的接線沒有單元測試] → verify 第 1 輪之後，背景那一段抽成 `runCredentialPlan(plan, generation:, tracker:, lookup:, submit:)` 並有 `CredentialPlanRunnerTests`；`TDLibClient` 只傳入 Keychain 來源與送出函式。E2E 測試的 setUp 要求已經登入的帳號，所以**沒有任何測試、也沒有人手動跑過從 Keychain 讀到值、送給 TDLib 的完整登入流程**；第一次發版前要用測試帳號手動登入一次（見 #40 的發版檢查）。
- [`auth_run` 在查詢期間狀態改變] → 查詢不持鎖，回來後重讀狀態，只有狀態仍在等同一個憑證才用這個值（`authRunKeychainValues`）。查詢回來到 TDLib 收到之間仍有一個很短的窗口，與環境變數路徑相同。
- [`auth_run` 剛把驗證碼送出、背景正從 Keychain 讀 2FA 密碼] → `auth_run` 等最多 15 秒讓它送完再回答，免得回一個「請提供 password」的提示。
- [Security.framework 的假設被推翻] → 程式碼只換 `SecurityCLICredentialSource` 一個型別；spec 的 Keychain Requirement 寫明了 `/usr/bin/security` 與 `-g`，要一起改。

## Migration Plan

無資料遷移。0.9.0 之前的 binary 沒有這個行為；README 的說法隨同一個 release 變成真的。回滾就是 pin 回 0.8.0。

## Open Questions

- 讀取方式（子程序或 Security.framework）是待維護者確認的假設，見第一個決策。
