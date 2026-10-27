## Context

#96 之後（`847971c`），TDLib 等電話號碼或 2FA 密碼時，`TDLibClient.enterCredentialState` 開一個 `Task` 跑 `runCredentialPlan`：先 `claim`（`claimCredentialSubmission(generation)`，在 client lock 下），再 `submit`（`submitCredential` → `requestPhoneNumber`／`requestPassword` → `coalesceTask(holder:)` → 新的 `Task` → TDLibKit 的 async `setAuthenticationPhoneNumber`／`checkAuthenticationPassword`）。client lock 是 `OSAllocatedUnfairLock`，不可重入、不能跨 `await`，所以 claim 與 TDLibKit 收下請求之間有空隙，#98 的兩個情況都落在這裡：claim 之後才記錄的狀態變更，以及 claim 之後才開始並完成的明確呼叫。

讀 TDLibKit `1.5.2-tdlib-1.8.60-cb863c16`（`Package.swift` 以 `exact:` 固定）得到的事實：

- 每個請求都經過 `TDLibClient.send(query:completion:)`，它做的是 `queryQueue.async { …; td_send }` 然後立刻返回。這個 `queryQueue` 是每個 client 一條的 **concurrent** queue（`attributes: .concurrent`，TDLibKit 自己的註解：先交出的請求可能比後交出的晚送出）。manager 的序列 queue 只處理回應，不處理送出。
- callback 形式 `setAuthenticationPhoneNumber(phoneNumber:settings:completion:)`、`checkAuthenticationPassword(password:completion:)` 經 `run(query:completion:)` 直接呼叫 `send`：不阻塞、不 suspend。async 形式也是同步呼叫同一個 `send` 後才 suspend。
- `completion` 在 client 的序列 `updateHandlerQueue` 上執行，與 update handler 同一條 queue。`send` 丟錯時 `run` 會在呼叫端同步呼叫 `completion`；1.5.2 的 `send` 不會丟錯，但設計不能假設這點。

`TDLibClient` 不能在單元測試裡建構：它的 init 建立真的 TDLib client（process-global 的 receive loop）並建立資料庫目錄。所以 #96 的 claim 接線一直沒有測試，只有 tracker 與 `runCredentialPlan` 的邏輯有。

## Goals / Non-Goals

**Goals:**

- 自動值的 claim 與「請求已交給 TDLibKit」之間，client 不可能記錄狀態變更。
- 自動值 claim 之後的同方法明確呼叫加入自動請求、得到它的結果，TDLibKit 只收到一個請求。
- 兩件事都能在 production 程式路徑上、以決定性的測試驗證，TDLib 本身換成假的 sender。

**Non-Goals:**

- 不保證 TDLib 收到請求的順序等於交給 TDLibKit 的順序：TDLibKit 的送出 queue 是 concurrent。兩個空隙都不需要這個順序（見 Decisions 第一項）。
- 不處理 TDLib 已經改變狀態、但 update 還沒到 client 的情況：任何選項都關不掉，TDLib 會以錯誤回應，照既有的自動送出失敗處理（環境變數的值記錄錯誤；Keychain 的值只在狀態沒變時記錄）。
- 不把自動值移出 coalesced 路徑（選項 A）。
- 不改 `setParameters` 與 `sendAuthCode` 的路徑。
- 不改跨 generation 的加入：較新的狀態 claim 時，若舊狀態送出的同方法請求還沒有回應，新的自動值加入它、不送自己的請求（#98 第一則 comment 評為無害：同一個來源的同一個值）。測試記錄這個行為。

## Decisions

### Claim 與交給 TDLibKit 在 client lock 下一步完成

自動送出改成一個同步的步驟：在 client lock 下 `claimSubmission(generation)`，成功就在同一把鎖裡建立或加入該方法的 coalesced task，建立時當場用 TDLibKit 的 callback 形式交出請求，然後才放鎖。這一步沒有 `await`。

為什麼這樣能關掉兩個空隙，又不需要 TDLib 端的順序：

- 狀態變更只在 client lock 下記錄。它若排在這一步之前，claim 失敗、什麼都不交出；若排在之後，請求已經交給 TDLibKit。client 不會再為它已知離開的狀態交出值。
- 明確呼叫也在 client lock 下建立或加入 coalesced task（下一項）。它若排在這一步之後，就看到自動值的 task 還在 holder 裡，加入它；同一方法只有一個請求，沒有「誰先到 TDLib」的問題。若排在之前，#96 的 `explicitSubmission` 讓 claim 失敗。
- TDLibKit 的 concurrent queue 只影響「不同請求」在 TDLib 的先後。這兩個情況裡沒有第二個同方法請求；不同方法的請求（例如 idle close）若先到，TDLib 以錯誤回應自動值，與「update 還沒到 client」同一類。

替代方案：選項 A（自動值離開 coalesced 路徑，在 TDLib 呼叫前於鎖下重查）要改 spec，而且明確呼叫在自動值途中時會拿到 TDLib 自己的回答；維持現狀則兩個空隙都留著。Decision comment 選 B。

### 明確呼叫也在 client lock 下建立或加入 coalesced task

`sendPhoneNumber`／`sendPassword` 在 client lock 下做兩件事：TDLib 正在等同一個憑證時記下 `explicitSubmission`（#96 原樣），然後建立或加入 coalesced task。這讓 claim、明確標記與 holder 的進出在同一把鎖下有全序。明確值本身照舊：狀態不對時 TDLib 回錯誤，在其他步驟送出的電話號碼不取消那一步的自動值。

鎖的順序固定為 client lock → holder lock → `RequestAnswer` 的鎖；sender 與 `completion` 都不碰 client lock 與 holder lock，所以不會反向取鎖。

### Coalesced task 等待已交出請求的回應

請求在 coalesced task 建立前就交出，回應可能比 task 開始等待還早到，甚至在 `send` 丟錯時同步到達。所以交出請求時先建立一個只交付一次的 `RequestAnswer`，`completion` 只把結果交給它（自己的鎖），task 等它。TDLib 錯誤在交付時就經過 `mapTDLibError`，所有加入者看到同一個結果（406 一律視為成功）。holder 照 `coalesceTask` 的做法由等待者在結束時以 `clearIfMatches` 清掉。

### 授權狀態移到 AuthCoordinator，TDLib 請求經過 CredentialRequestSending

測試要驗的是 production 路徑：狀態變更、自動送出、明確呼叫三者在同一把鎖下的互動。這三者原本都在 `TDLibClient` 裡，而 `TDLibClient` 不能在測試裡建構。所以把 client lock 與它保護的狀態（`authState`、`cachedApiId`／`cachedApiHash`、`lastAutoFireError`、`CredentialLookupTracker`、電話與密碼的 holder）以及這兩個請求的路徑移到內部的 `AuthCoordinator`，TDLib 的兩個請求經過 `CredentialRequestSending`。`TDLibClient` 留著 TDLibKit client、`setParameters`、`sendAuthCode` 與讀環境變數，其餘轉交；公開方法簽名不變。正式的 sender 是 `TDLibKitCredentialRequests`，由 `TDLibClient` 以自己的 TDLibKit client 建立。

替代方案：在 `TDLibClient` 加 internal init 換掉 sender。它的 init 一定會開真的 TDLib，而 `client` 是許多聊天功能共用的非 optional 屬性，所以不可行。只抽出請求路徑、狀態留在 `TDLibClient`：測試就得自己重寫狀態變更與明確呼叫，驗的不是 production 路徑。

### 測試在 claim 步驟返回的那一刻動作

`AuthCoordinator` 接受一個 internal 的 `afterAutomaticClaim` hook（預設什麼都不做），在自動送出的 claim 步驟返回後、等待 TDLib 回應前執行：這是別的呼叫端最早能拿到 client lock 的時刻。測試在這裡記錄狀態變更或發出明確呼叫：在 #96 的流程裡，這個時刻請求還沒進 holder、還沒交出，測試會失敗；在 B 的流程裡請求已經交出並在 holder 裡。另外一個測試不靠 hook：假 sender 在交出請求的當下讓另一條 thread 記錄狀態變更，並等它最多 1 秒；B 之下那條 thread 被 client lock 擋住，交出時看到的仍是 claim 的 generation。

## Implementation Contract

- **行為**：TDLib 等電話號碼或 2FA 密碼、而自動值（環境變數或 Keychain）被 claim 時，client 在放開 client lock 前已把 `setAuthenticationPhoneNumber` 或 `checkAuthenticationPassword` 交給 TDLibKit；之後記錄的狀態變更不會讓請求被收回或重送，之前記錄的狀態變更讓 claim 失敗、不交出任何請求。claim 之後的同方法明確呼叫加入自動請求並得到它的結果（成功，或同一個 `TDError`），TDLibKit 只收到一個請求。claim 之前、TDLib 在等同一憑證時的明確呼叫讓這個狀態沒有自動值。其餘行為不變：`auth_status`、`auth_run`、settle 判斷、Keychain 查詢與其分類、CLI 不讀 Keychain。
- **介面**：`TelegramAllLib` 內部新增 `protocol CredentialRequestSending: Sendable`（`setAuthenticationPhoneNumber(_:completion:)`、`checkAuthenticationPassword(_:completion:)`，`completion` 是 `@Sendable (Result<Void, Error>) -> Void`；呼叫在 client lock 下，不得阻塞、suspend 或取那把鎖）、`struct TDLibKitCredentialRequests`（正式版，TDLibKit callback 形式）、`final class AuthCoordinator`（`init(credentials:requests:afterAutomaticClaim:)`；`enter(_:)`、`enterCredentialState(_:plan:)` 回傳執行該 plan 的 `Task`、`autoSettingParameters(apiId:apiHash:)`、`recordAutoFireError(_:)`、`sendPhoneNumber(_:)`、`sendPassword(_:)`、`state`、`lastAutoFireError`、`isSubmittingKeychainCredential`、`lookUpKeychainCredential(_:)`、`stateAndKeychainMiss()`、`settleInputs()`、`credentialLookups`）、`AuthCoalescing.swift` 的 `RequestAnswer`、`coalescedRequest(holder:send:)` 與 `awaitCoalesced(_:holder:)`。`runCredentialPlan` 的 `claim:` 與 `submit:` 合成一個 `submit: (String) async throws -> Bool`：它負責 claim，claim 失敗時回 false 且不送任何東西。`TDLibClient` 的公開 API 不變。
- **錯誤與邊界**：TDLib 的錯誤照舊經 `mapTDLibError`（406 視為成功）；自動送出失敗的記錄規則不變。sender 若同步呼叫 `completion`，結果照樣交付。TDLib 一直不回應時 task 一直等待，與 TDLibKit 的 async API 相同。
- **驗收**：`AuthCoordinatorTests` 的兩個空隙測試（claim 步驟返回時記錄的狀態變更、交出請求時另一條 thread 的狀態變更、claim 之後的明確呼叫）在 B 之前的程式上失敗、之後通過；同檔的 #96 行為測試（claim 之前的明確呼叫取消自動值、其他步驟的明確值不取消、一個狀態一個自動值、claim 前的狀態變更不送出）與跨 generation 加入的記錄測試在前後都通過；`CredentialPlanRunnerTests` 照舊通過；`swift test --skip E2ETests` 全過。
- **範圍外**：選項 A、TDLib 端的請求順序、`setParameters`／`sendAuthCode`、跨 generation 加入的行為改變、CLI 與 Server 的行為。

## Risks / Trade-offs

- [sender 在 unfair lock 下被呼叫；會阻塞的 sender 會卡住所有讀授權狀態的人] → 正式 sender 只做 `queryQueue.async`；protocol 文件寫明不得阻塞、suspend 或取 client lock。
- [TDLibKit 在 `send` 丟錯時同步呼叫 `completion`] → `completion` 只交付給 `RequestAnswer`（自己的鎖），從不取 client lock 或 holder lock。
- [claim 之後才打的明確 2FA 密碼不會送出，呼叫端得到存好的值的結果] → 選項 B 的既定後果（Decision comment）。存好的值錯了，呼叫端拿到錯誤，下一次明確呼叫時 holder 已空，會送出他打的值。
- [跨 generation 加入：新狀態的自動值加入舊狀態還沒有回應的請求] → 不在範圍內，測試記錄現行行為；改它需要追蹤 holder 裡請求的 generation。
- [TDLibKit 升級改變 `send` 的行為（例如變成會阻塞）] → `Package.swift` 以 `exact:` 固定版本；Context 記下讀過的版本與事實，升級時要重讀。
