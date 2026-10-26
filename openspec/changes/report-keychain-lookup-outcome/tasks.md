## 1. 查詢結果分類與記錄

- [x] 1.1 先寫失敗的測試：`KeychainMiss(KeychainLookup)` 把 `absent`／`timedOut`／`unavailable` 換成 `not_stored`／`timed_out`／`unavailable`，`found` 換成 nil；`CredentialLookupTracker` 的 `finish(_:miss:)` 記錄分類、`stateChanged` 清掉、過期 generation 不寫入、`note(_:miss:)` 更新分類但不改 settle 狀態。驗證：`swift test --filter KeychainMissTests` 與 `--filter CredentialLookupTrackerTests` 先失敗
- [x] 1.2 依設計「原因分類放在 tracker，與 settle 狀態分開」實作 `KeychainMiss` 與 tracker 的分類欄位，`runCredentialPlan` 把查詢結果的分類交給 `finish(_:miss:)`，`TDLibClient` 提供 `authStateAndKeychainMiss()`，`lookUpKeychainCredential` 以起始 generation 呼叫 `note`。驗證：1.1 的測試與 `CredentialPlanRunnerTests` 通過 [after: 1.1]

## 2. 回應與提示

- [x] 2.1 先寫失敗的測試（Requirement: Keychain lookup outcome is reported without the value；Requirement: `auth_status` response includes structured next-step hint 的完整回應加上 `"keychain_lookup": null`）：`authStatusResult(... keychainMiss:)` 在等電話／等密碼時輸出 `keychain_lookup` 物件、其他狀態輸出 null；`waitingForPassword` 的 hint 先提 Keychain 再提 `password` 參數，有分類時以原因開頭；回應不含測試用的值。驗證：`swift test --filter AuthStatusNextStepTests` 先失敗 [after: 1.2]
- [x] 2.2 依設計「欄位是物件而不是字串」與「提示文字以 Keychain 為先」實作回應欄位與提示，`Server.swift` 的 `auth_status` 與 `auth_run` 以 `tdlib.authStateAndKeychainMiss()` 一起取得狀態與原因。驗證：2.1 的測試通過，`swift test --skip E2ETests` 全過 [after: 2.1]

## 3. 文件

- [x] 3.1 all-mcp README 說明 `keychain_lookup` 欄位，CHANGELOG `[Unreleased]` 記錄 #95。驗證：人工核對 README 的欄位說明與實際 JSON 鍵名一致 [after: 2.2]
