## 1. 可測試的接縫（行為不變）

- [x] 1.1 依設計「授權狀態移到 AuthCoordinator，TDLib 請求經過 CredentialRequestSending」：client lock 與它保護的授權狀態、電話與密碼的 holder、兩個請求的路徑移到內部的 `AuthCoordinator`，TDLib 的兩個請求經過 `CredentialRequestSending`（正式版 `TDLibKitCredentialRequests`：TDLibKit 的 callback 形式，把請求排進 TDLibKit 的送出佇列就返回，`completion` 之後收到回應）；`runCredentialPlan` 的 `claim:` 併進 `submit:`（回傳是否 claim 成功）；`beforeAutomaticClaim` 與 `afterAutomaticClaim` 兩個 hook 在 claim 步驟的前後執行（依設計「測試在 claim 步驟返回的那一刻動作」）。`TDLibClient` 的公開 API 不變。驗證：既有的 `CredentialPlanRunnerTests`（只改呼叫形式，斷言不變）與 `swift test --skip E2ETests` 全過，測試數與 `847971c` 相同

## 2. 先寫失敗的測試

- [x] 2.1 `AuthCoordinatorTests`（Requirement: An automatic credential is claimed and handed to TDLib in one step）：claim 步驟返回時記錄的狀態變更（電話與密碼）、交出請求當下另一條 thread 記錄的狀態變更、claim 之後同方法的明確呼叫（TDLibKit 只收到一個請求、明確呼叫得到自動請求的結果）。驗證：在 1.1 的 commit 上 `swift test --filter AuthCoordinatorTests` 這三個測試失敗 [after: 1.1]
- [x] 2.2 同檔記錄 #96 的行為與跨 generation 加入：claim 之前的明確呼叫取消自動值、其他步驟的明確值不取消、claim 之前的狀態變更不交出請求、lookup 結束後到 claim 之間的狀態變更讓 claim 失敗（`beforeAutomaticClaim`），電話與密碼各測一次；TDLib 的 406 視為成功、其他錯誤以 `TDError.tdlibError` 交給所有呼叫端並記錄（一個狀態只有一個自動值已由 `CredentialPlanRunnerTests` 與 `CredentialLookupTrackerTests` 涵蓋）；新狀態的自動值加入舊狀態仍在途中的請求。驗證：#96 的三個測試在 1.1 的 commit 上通過；跨 generation 的測試要等 claim 與加入是同一步才是決定性的，在 3.1 之後驗證 [after: 1.1]

## 3. 選項 B

- [x] 3.1 依設計「Claim 與交給 TDLibKit 在 client lock 下一步完成」與「Coalesced task 等待已交出請求的回應」：自動送出在 client lock 下 claim、以 `coalescedRequest(holder:send:)` 建立或加入 coalesced task 並當場交出請求，`RequestAnswer` 接收回應（含同步到達的回應），TDLib 錯誤在交付時經 `mapTDLibError`。驗證：2.1 的測試與跨 generation 的測試通過，`AuthCoalescingTests` 的 `coalescedRequest` 測試（在途中只交出一次、交出時同步到達的回應不遺失、只算第一個回應、等待結束後重新交出）通過 [after: 2.1]
- [x] 3.2 依設計「明確呼叫也在 client lock 下建立或加入 coalesced task」：`sendPhoneNumber`／`sendPassword` 在 client lock 下記下 `explicitSubmission`（只在 TDLib 等同一憑證時）並建立或加入 coalesced task；鎖的順序 client → holder → `RequestAnswer`，sender 與 completion 不取 client lock。驗證：2.1、2.2 的測試、`testAnUpdateBeforeTheAnswerLeavesTheAnswerToEveryCaller`（update 與 completion 在同一條序列 queue、update 先到）、`testAnAnswerDeliveredInsideTheHandOffDoesNotBlock`（回應在交出當下同步到達）與 `swift test --skip E2ETests` 全過 [after: 3.1]

## 4. 文件

- [x] 4.1 all-mcp CHANGELOG `[Unreleased]` 的 #96 條目改寫「Still open」那句，新增 #98 的行為說明（claim 與交出請求一步完成、claim 之後的明確呼叫加入自動請求並得到它的結果、TDLib 已改變而 update 未到時以錯誤回應）。驗證：人工核對條目只描述行為，與 spec 的 Requirement 一致 [after: 3.2]
