## 1. 標記與升級（日檔層）

- [x] 1.1 先寫失敗的測試（Requirement: Day file format 的 Example: block written from the local cache 與 Scenario: Text that looks like the marker；Requirement: Merge and idempotent rewrite 的 Example: which existing blocks a call replaces 與 Scenario: TDLib re-run after an upgrade）：`block(_:offsetSeconds:provisional: true)` 的第二行是 `provisionalMarker`；帶標記與不帶標記的日檔 `parseBlocks` 得到相同的 id；`merged(provisional: false)` 換掉帶標記的區塊並回報在 `upgraded`、其他區塊與 preamble 位元組不變；`merged(provisional: true)` 不換任何區塊；內文行恰為標記時被跳脫、該區塊不是暫時的；`write` 升級後檔案仍是 0600、再寫一次位元組不變並回 `([], [])`；只有快取訊息、id 都已存在時檔案不動。驗證：`swift test --filter ArchiveDayFileTests` 先失敗
- [x] 1.2 依設計「標記在錨點之後自己的一行」與「升級：TDLib 換掉帶標記的區塊，快取不換任何區塊」實作 `provisionalMarker`、`block(...provisional:)`、`isProvisional`、`merged(...provisional:)` 與 `write(...provisional:)`（回傳 `added` 與 `upgraded`），既有的 `write` 測試改讀 `.added`。驗證：1.1 的測試與既有的 `ArchiveDayFileTests` 通過 [after: 1.1]

## 2. 歸檔與 manifest

- [x] 2.1 先寫失敗的測試（Requirement: Archive from the local cache 的 Scenario: Another session holds TDLib；Requirement: Merge and idempotent rewrite 的 Scenario: TDLib run after a cache run、Cache run after a TDLib run；Requirement: Content-free manifest 的 Scenario: Manifest after a first run）：快取呼叫寫出的每個區塊第二行是標記；同一個輸出目錄先快取再 TDLib：區塊換成解析過的名稱與說明文字、沒有標記，`upgradedMessages` 為 1、`newMessages` 為 0、`files` 有該日檔，其他區塊位元組不變；先 TDLib 再快取：檔案位元組不變、`upgradedMessages` 為 0；manifest JSON 一律有 `upgraded_messages`。驗證：`swift test --filter ChatArchiverTests` 與 `--filter LocalCacheArchiveTests` 先失敗 [after: 1.2]
- [x] 2.2 依設計「manifest：`upgraded_messages`，`files` 含升級的日檔」與「介面」實作：`ChatArchiver.write` 以 `provisional: sourceKind == .localCache` 呼叫 `ArchiveDayFile.write`，累加 `upgradedMessages`，有升級的日檔放進 `files`；`manifestJSON` 輸出 `upgraded_messages`。驗證：2.1 的測試與既有的 `ChatArchiverTests`、`LocalCacheArchiveTests` 通過 [after: 2.1]

## 3. 工具說明、skill 與文件

- [x] 3.1 依設計「skill 與文件」改 `Server.swift` 的 `archive_chat_to_markdown` 說明（快取寫的區塊是暫時的、之後 TDLib 會換掉）；SKILL.md 的 Step 3 理由、Step 6 的 `last_run.upgraded_messages`、Step 7 的報告行與 `local-cache` 那一列（Requirement: archive-telegram end-of-run check and report 的 Scenario: Report after an upgrade）；all-mcp README 的「Other sessions」與日檔段落寫出標記的確切格式、升級規則、`upgraded_messages`、v0.8.0 的快取區塊不升級、帶標記的區塊屬於工具；plugin README 的快取段落；兩份 CHANGELOG 的 `[Unreleased]` 記 #72，寫出依設計「預設選項（維護者不在時採用）」選定的行為（標記加升級、沒有 `refresh` 參數）；決策過程只留在 proposal、design 與 commit message，不寫進使用者看的文件。驗證：`for t in tests/che-telegram-mcp/*.sh; do bash "$t" | tail -1; done` 全過；人工核對 README 的標記字串與 `provisionalMarker` 一致；`swift test --skip E2ETests` 全過 [after: 2.2]

## 4. 與 #76 的 CR 規則合併

- [x] 4.1 先寫失敗的測試（Requirement: Merge and idempotent rewrite 的 Scenario: Carriage return in a day file with a provisional block 與 Example: day files the call refuses）：CRLF 日檔有訊息 5 的暫時區塊時，快取寫入 5、6 原樣保留；TDLib 只寫 6 原樣保留；TDLib 寫 5、6 丟 `carriageReturn` 且位元組不變；改成 LF 後同一個寫入把 5 升級。依設計「含 CR 的日檔：會被升級就算寫入，一樣拒絕」，`write` 對含 CR 的日檔用 CRLF 換成 LF 後的 `merged` 判斷會不會寫。驗證：只看 `added` 的 #76 規則下這個測試失敗（沒有丟錯誤），合併後的實作下 `swift test --filter ArchiveDayFileTests` 通過 [after: 3.1]

## 5. 以 Unicode scalar 比對日檔的行

- [x] 5.1 先寫失敗的測試（Requirement: Day file format 的 Scenario: Comment followed by a combining mark、Line break followed by a combining mark、Anchor with a mark fused into it）：U+0301、U+200D、U+FE0F、U+034F 接在 `<!--`、`<!-- msg:9 -->`、標記、`**09:00` 之後的內文行都被加上反斜線，以 LF scalar 切開輸出後，以 `<!--` 開頭的只有工具寫的錨點；寄件人與內文裡「換行＋記號」仍是換行、輸出沒有 CR；混了記號的錨點與標記不算；含 CR 的日檔裡「CRLF＋記號」仍結束錨點行。依設計「日檔的行一律以 Unicode scalar 比對」以 `ScalarText` 取代 `hasPrefix`、`==`、正規表示式與 `replacingOccurrences`。驗證：修改前 `swift test --filter ArchiveDayFileTests` 有 22 個 assertion 失敗、CRLF 那一項被誤拒；修改後通過 [after: 4.1]

## 6. verify 之後補的測試與文字

- [x] 6.1 補測試釘住三個解析條件（verify 時這三個 mutant 沒被抓到，程式本身正確）：錨點要有結尾的 ` -->`、id 只能是 ASCII 數字（`+5`、`-5`、空白、其他文字系統的數字都不算）、frontmatter 第一行恰為 `---`；另依 Requirement: Day file format 的 Scenario: Line separators inside a message 測 VT、FF、FS、GS、RS、NEL、U+2028、U+2029 留在行內。驗證：三個 mutant 各自讓 `swift test --filter ArchiveDayFileTests` 的新測試失敗，還原後通過 [after: 5.1]
