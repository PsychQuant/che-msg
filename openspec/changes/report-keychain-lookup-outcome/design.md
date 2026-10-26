## Context

#49 的 Keychain 來源回傳 `KeychainLookup`（`found`／`absent`／`timedOut`／`unavailable(exitStatus:)`），但兩個使用端都把原因丟掉：背景 auto-fire（`runCredentialPlan`）只把「有沒有值」交給 `CredentialLookupTracker.finish(_:found:)`；`auth_run` 自己的查詢（`TDLibClient.lookUpKeychainCredential`）只回 `String?`。`authStatusResult(state:lastError:sync:)` 只看狀態組 `next_step`。

## Goals / Non-Goals

**Goals:**

- `auth_status`／`auth_run` 在查詢沒拿到值時說出原因分類，且提示把 Keychain 放在第一順位。
- 原因只屬於它被查詢的那個狀態，狀態一變就失效。

**Non-Goals:**

- 不改查詢方式、逾時與來源順序。
- 不回報 `security` 的輸出或結束碼。
- 不處理送值的競態與 CLI 的 auto-fire（#96）。

## Decisions

### 原因分類放在 tracker，與 settle 狀態分開

`CredentialLookupTracker` 已經以 generation 管「這個狀態的查詢」；把分類存在同一把鎖、同一個 generation 下，狀態一變就跟著清，不需要第二份同步。分類與 settle 用的 `status` 分開存：`auth_run` 的查詢只更新分類，不動 `status`，避免讓 `isInFlight` 變真而觸發 15 秒等待。替代方案是在 `TDLibClient` 另存一個欄位：要自己對 generation，容易在狀態改變時留下舊值，捨棄。

### 欄位是物件而不是字串

`keychain_lookup` 帶 `credential` 與 `outcome`，讓 agent 不必從狀態反推是哪一個憑證；兩個值都是封閉列舉，沒有自由文字，所以不可能夾帶秘密。

### 提示文字以 Keychain 為先

`required_args` 仍是 `["password"]`（不改既有契約）；`hint` 先講 Keychain 的存法與解鎖，最後才提參數並說明它會經過對話。存法用 plugin README 的同一行指令（`-w` 放最後、不帶值）。

## Implementation Contract

- **行為**：TDLib 等電話或 2FA 密碼、而該狀態最後一次 Keychain 查詢沒有拿到值時，`auth_status` 與 `auth_run` 回應的 `keychain_lookup` 是 `{"credential": "phone"|"password", "outcome": "not_stored"|"timed_out"|"unavailable"}`；其他情況是 null。`waitingForPassword` 的 `next_step.hint` 先講 Keychain 再講參數；有分類時開頭先講原因。
- **介面**：`TelegramAllLib` 新增 `public enum KeychainMiss: String`（`notStored = "not_stored"`、`timedOut = "timed_out"`、`unavailable`），`init?(_ lookup: KeychainLookup)`（`found` 回 nil）；`TDLibClient.lastKeychainMiss: KeychainMiss?`。`CredentialLookupTracker.finish(_:miss:)` 取代 `finish(_:found:)`（nil 表示找到），新增 `note(_:miss:)` 供 `auth_run` 的查詢使用，`generationNow` 供它取得起始 generation。`authStatusResult(state:lastError:sync:keychainMiss:)` 新參數預設 nil。
- **錯誤與邊界**：`keychainMiss` 在狀態不是等電話或等密碼時一律輸出 null。兩次查詢以後完成者為準。`unavailable` 不帶結束碼。
- **驗收**：`CredentialLookupTrackerTests`（分類的記錄、狀態變更清除、`note` 不改 status、過期 generation 不寫入）、`CredentialPlanRunnerTests`（三種失敗各自記錄、找到值不記錄）、`AuthStatusNextStepTests`（三種分類的 JSON、非等待狀態為 null、提示順序、不含值）；`swift test --skip E2ETests` 全過。
- **範圍外**：#96 的單一送出路徑、CLI、enum 描述遮蔽。
