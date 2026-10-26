## 1. 參數解析的三條規則

- [x] 1.1 先寫失敗的測試（Requirement: Output path validation and error reporting 的 Relative path refused、Traversal component refused、Non-Markdown target refused、Upper-case extension accepted）：`testDumpRejectsRelativePath`（`chat.md`、`./chat.md`、`~/chat.md`、空字串）、`testDumpRejectsTraversalPath`（`..` 在中間與結尾；`..md` 檔名接受）、`testDumpRejectsNonMarkdownExtension`（`.zshrc`、`.txt`、`.mdx`、`.md.sh`、結尾 `/`；`.MD`、`.Md` 接受），比對錯誤訊息全文。驗證：`swift test --filter ParseDumpArgsTests` 先失敗
- [x] 1.2 依設計「三條規則放在參數解析」在 `parseDumpChatToMarkdownArgs` 實作，錯誤為 `HandlerArgError`。驗證：1.1 的測試通過，`ParseDateInArgsTests`、`ParseMaxMessagesTests` 等既有 dump 測試仍過 [after: 1.1]

## 2. 選用的根目錄

- [x] 2.1 先寫失敗的測試（Requirement: Output path validation and error reporting 的 Path inside the export root accepted、Path outside the export root refused、Symbolic link escape refused、Unusable export root refuses every dump）：`ExportRoot.parse` 對 nil、空字串、一般值；`testValidateOutputPathRespectsExportRoot` 在暫存目錄內涵蓋根內接受、根外拒絕、目錄 symlink 逃逸、檔案 symlink 逃逸、懸空 symlink、根內 symlink 指回根內接受、不存在元件中的 `..`、根目錄是相對路徑或不存在。驗證：`swift test --filter MarkdownExporterContractTests` 先失敗（編譯失敗也算）[after: 1.2]
- [x] 2.2 依設計「根目錄 opt-in，設錯時一律拒絕」與「解析 symlink：最長既存前綴」實作 `ExportRoot`、`ExportError` 的兩個新 case、`validateOutputPath(_:exportRoot:)`。驗證：2.1 的測試通過 [after: 2.1]
- [x] 2.3 先寫失敗的測試（Scenario: Local-cache dump honours the export root）：`LocalTDLibReader.dumpChatToMarkdown(..., exportRoot:)` 在根目錄外拒絕且不寫檔；`ToolRoutingTests` 驗證 server 把 designated init 注入的根目錄傳給 reader，且三條規則在本機快取路徑也回錯誤、不呼叫 reader。驗證：`swift test --filter LocalReaderToolTests` 與 `--filter ToolRoutingTests` 先失敗 [after: 2.2]
- [x] 2.4 依設計「變數在啟動時讀一次，由 server 傳給兩條路徑」與「CLI 不變」實作（`MarkdownExporter(client:)` 的 `exportRoot` 預設 nil，CLI 呼叫不改）：`LocalCacheReading.dumpChatToMarkdown` 加 `exportRoot:`，`MarkdownExporter(client:exportRoot:)`，server 的 convenience init 讀 `ExportRoot.fromEnvironment()`、designated init 收 `exportRoot:`，兩個 handler 傳入；更新三個測試替身。驗證：2.3 的測試通過，`swift test --skip E2ETests` 全過 [after: 2.3]

## 3. 文件

- [x] 3.1 tool schema 的 `output_path` 說明寫出三條規則、根目錄與既有檔案會被取代；README 環境變數表加 `CHE_TELEGRAM_ALL_EXPORT_ROOT`、Messages 表的 `dump_chat_to_markdown` 說明更新；CHANGELOG `[Unreleased]` 記錄行為變更（相對路徑與非 `.md` 路徑現在被拒絕）與新變數，並寫明三個預設是維護者不在時選的。驗證：人工核對 README、schema 與錯誤訊息的用詞一致；`swift test --skip E2ETests` 與 `tests/che-telegram-mcp/*.sh` 全過 [after: 2.4]

## 4. 驗證後的修正

- [x] 4.1 先寫失敗的測試（Scenario: Traversal hidden behind a combining mark refused、Root escape hidden behind a combining mark refused）：沒有根目錄時 `/tmp/..` + "/" + 組合用記號（U+0301、U+200D、U+FE0F、U+034F）被 `..` 規則拒絕；有根目錄時 `<root>/..`、`<root>/escape` 後接 "/" + 組合用記號被拒絕；根目錄內以組合用記號開頭的檔名接受；本機快取路徑不寫到 `<base>`。依設計「路徑以 Unicode scalar 讀，與 OS 相同」實作 `ScalarPath` 並改用在所有切路徑的地方。驗證：`swift test --filter "ParseDumpArgsTests|MarkdownExporterContractTests|LocalReaderToolTests|ScalarPathTests"` 先失敗後通過 [after: 3.1]
- [x] 4.2 先寫失敗的測試：`MarkdownExporter` 以替身讀取時在根目錄外拒絕且沒有讀取；`dumpInTDLibMode` 用 server 的根目錄；source pin 確認 TDLib 分支經過 seam。依設計「變數在啟動時讀一次，由 server 傳給兩條路徑」的 seam 段實作 `MarkdownExportSource` 與 `dumpInTDLibMode`。驗證：三個 mutant（helper 不傳根目錄、TDLib 分支自建 exporter、`dumpChatToMarkdown` 驗證時不帶根目錄）各自讓測試失敗；`swift test --skip E2ETests` 全過 [after: 4.1]
- [x] 4.3 README 寫明空字串等於沒設、只有空白的值拒絕每一次 dump，以及沒有根目錄時 agent 會載入的 `.md`（`CLAUDE.md`、`AGENTS.md`、`SKILL.md`、`~/.claude/commands/*.md`）不受保護；CHANGELOG 補上以 scalar 讀路徑與只有空白的值。驗證：人工核對 README、CHANGELOG 與 spec 用詞一致；`tests/che-telegram-mcp/*.sh` 全過 [after: 4.2]
