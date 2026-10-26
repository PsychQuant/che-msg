## 1. 標記與升級（日檔層）

- [x] 1.1 先寫失敗的測試（Requirement: Day file format 的 Example: block written from the local cache 與 Scenario: Text that looks like the marker；Requirement: Merge and idempotent rewrite 的 Example: which existing blocks a call replaces 與 Scenario: TDLib re-run after an upgrade）：`block(_:offsetSeconds:provisional: true)` 的第二行是 `provisionalMarker`；帶標記與不帶標記的日檔 `parseBlocks` 得到相同的 id；`merged(provisional: false)` 換掉帶標記的區塊並回報在 `upgraded`、其他區塊與 preamble 位元組不變；`merged(provisional: true)` 不換任何區塊；內文行恰為標記時被跳脫、該區塊不是暫時的；`write` 升級後檔案仍是 0600、再寫一次位元組不變並回 `([], [])`；只有快取訊息、id 都已存在時檔案不動。驗證：`swift test --filter ArchiveDayFileTests` 先失敗
- [x] 1.2 依設計「標記在錨點之後自己的一行」與「升級：TDLib 換掉帶標記的區塊，快取不換任何區塊」實作 `provisionalMarker`、`block(...provisional:)`、`isProvisional`、`merged(...provisional:)` 與 `write(...provisional:)`（回傳 `added` 與 `upgraded`），既有的 `write` 測試改讀 `.added`。驗證：1.1 的測試與既有的 `ArchiveDayFileTests` 通過 [after: 1.1]

## 2. 歸檔與 manifest

- [x] 2.1 先寫失敗的測試（Requirement: Archive from the local cache 的 Scenario: Another session holds TDLib；Requirement: Merge and idempotent rewrite 的 Scenario: TDLib run after a cache run、Cache run after a TDLib run；Requirement: Content-free manifest 的 Scenario: Manifest after a first run）：快取呼叫寫出的每個區塊第二行是標記；同一個輸出目錄先快取再 TDLib：區塊換成解析過的名稱與說明文字、沒有標記，`upgradedMessages` 為 1、`newMessages` 為 0、`files` 有該日檔，其他區塊位元組不變；先 TDLib 再快取：檔案位元組不變、`upgradedMessages` 為 0；manifest JSON 一律有 `upgraded_messages`。驗證：`swift test --filter ChatArchiverTests` 與 `--filter LocalCacheArchiveTests` 先失敗 [after: 1.2]
- [x] 2.2 依設計「manifest：`upgraded_messages`，`files` 含升級的日檔」與「介面」實作：`ChatArchiver.write` 以 `provisional: sourceKind == .localCache` 呼叫 `ArchiveDayFile.write`，累加 `upgradedMessages`，有升級的日檔放進 `files`；`manifestJSON` 輸出 `upgraded_messages`。驗證：2.1 的測試與既有的 `ChatArchiverTests`、`LocalCacheArchiveTests` 通過 [after: 2.1]

## 3. 工具說明、skill 與文件

- [ ] 3.1 依設計「skill 與文件」改 `Server.swift` 的 `archive_chat_to_markdown` 說明（快取寫的區塊是暫時的、之後 TDLib 會換掉）；SKILL.md 的 Step 3 理由、Step 6 的 `last_run.upgraded_messages`、Step 7 的報告行與 `local-cache` 那一列（Requirement: archive-telegram end-of-run check and report 的 Scenario: Report after an upgrade）；all-mcp README 的「Other sessions」與日檔段落寫出標記的確切格式、升級規則、`upgraded_messages`、v0.8.0 的快取區塊不升級、帶標記的區塊屬於工具；plugin README 的快取段落；兩份 CHANGELOG 的 `[Unreleased]` 記 #72，並依設計「預設選項（維護者不在時採用）」寫明 Q1、Q2 的預設。驗證：`for t in tests/che-telegram-mcp/*.sh; do bash "$t" | tail -1; done` 全過；人工核對 README 的標記字串與 `provisionalMarker` 一致；`swift test --skip E2ETests` 全過 [after: 2.2]
