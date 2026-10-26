## Context

`dump_chat_to_markdown` 有兩條寫入路徑：TDLib 模式（`Server.handleToolCall` → `MarkdownExporter.dumpChatToMarkdown`）與另一個 process 持有 TDLib 時的本機快取讀取（`Server.handleWhileTDLibIsHeld` → `LocalTDLibReader.dumpChatToMarkdown`）。兩條都先呼叫 `parseDumpChatToMarkdownArgs`，寫入前都呼叫同一個 `validateOutputPath`（只看父目錄存在且可寫），最後以 `String.write(toFile:atomically: true)` 寫入。`archive_chat_to_markdown` 與 `download_message_media` 收的是 `output_dir`，已要求絕對路徑並做 `standardizedFileURL`，檔名由 server 決定，不在這次範圍內。

#21 的 Diagnosis 留了三個 Open questions，維護者不在，這裡採用的預設（default chosen while the maintainer was away）：第 1 步一律啟用、第 2 步 opt-in；根目錄只限制 dump 的兩條寫入路徑；變數名 `CHE_TELEGRAM_ALL_EXPORT_ROOT`。

## Goals / Non-Goals

**Goals:**

- 擋掉會被 shell 或系統當作設定、可執行檔載入的目標（`~/.zshrc`、`authorized_keys`、LaunchAgent plist），以及呼叫端看不到解析基準的相對路徑。
- 讓想要沙箱的使用者用一個環境變數把 dump 關進一個目錄，symlink 也逃不出去。
- 兩條寫入路徑行為一致。

**Non-Goals:**

- 不限制 archive／download 工具與 CLI 的 `--dump-markdown`。
- 不設預設根目錄，不改寫入方式與輸出格式。
- 不防 TOCTOU：驗證與寫入之間（訊息抓取期間）若有人換掉路徑上的目錄為 symlink，檢查擋不住；這些 tool 都不會建立 symlink，所以被 injection 的呼叫端做不到。

## Decisions

### 三條規則放在參數解析

絕對路徑、無 `..` 元件、`.md` 結尾都只看字串，放在 `parseDumpChatToMarkdownArgs`，是純函式、可單元測試，錯誤沿用 `HandlerArgError`，經 `errorResultFromParse` 回成 `Error: ...`。兩個 handler 都先呼叫它，所以兩條路徑一起受益，而且在讀任何訊息之前就拒絕。檢查順序是絕對路徑、`..`、副檔名；錯誤訊息說出規則並以引號帶出原值（`errorResultFromParse` 的 256 字上限照舊適用）。

- 絕對路徑：以 `/` 開頭。`~` 不展開，`~/chat.md` 當作相對路徑拒絕；空字串也是。
- `..`：以 `/` 切開後任何一段恰好是 `..` 就拒絕；`..md` 這類檔名不受影響，`.` 不擋（不會往上走）。
- `.md`：整個字串轉小寫後以 `.md` 結尾。**不分大小寫**：工具只寫 Markdown，大小寫不改變檔案是什麼，macOS 預設的 APFS 也不分大小寫；守門要防的目標沒有一個以任何大小寫的 `.md` 結尾。結尾是 `/`（`/tmp/x.md/`）或 `.mdx`、`.md.sh` 都拒絕。

替代方案是完全拒絕絕對路徑、改由 server 加前綴：會讓 README 範例與既有呼叫全部失效，又需要預設根目錄，捨棄。

### 根目錄 opt-in，設錯時一律拒絕

`CHE_TELEGRAM_ALL_EXPORT_ROOT` 沒設或是空字串時不限制。設了就必須是既存目錄的絕對路徑；不是的話（相對路徑、不存在、不是目錄、只有空白），每一次 dump 都以 `exportRootUnusable` 拒絕並說出設定值。這是安全設定，設錯時默默不限制等於讓使用者以為有沙箱，所以 fail closed；與 `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` 設錯時退回預設不同。值不做 trim，也不展開 `~`。

### 解析 symlink：最長既存前綴

根目錄以 `realpath` 解析。目標路徑從完整路徑往上找最長的、`lstat` 看得到的前綴（symlink 本身存在就算，即使它指向不存在的位置），對它做 `realpath`，再接上其餘元件。以下情況一律拒絕（`outsideExportRoot`）：

- 其餘（尚不存在的）元件中有 `..`；
- `lstat` 的錯誤不是 `ENOENT`（例如 `EACCES`、`ENOTDIR`、`ELOOP`）；
- 前綴 `lstat` 得到但 `realpath` 失敗（懸空 symlink、symlink 迴圈）；
- 路徑含 NUL 字元（C 函式會在 NUL 截斷，檢查的就不是會被寫入的路徑）；
- 解析後的目標不是嚴格位於解析後的根目錄之內：以路徑元件比較，根的元件必須是目標元件的前綴，且目標比根多至少一個元件。

`realpath` 在 macOS 會把大小寫正規化成磁碟上的寫法、把 `/tmp` 換成 `/private/tmp`，根與目標用同一個函式解析，比較的是同一種形式。最後一個元件若是 symlink 也一併解析：實測 `write(toFile:atomically: true)` 會取代 link 本身而不是寫穿過去，但這是 Foundation 的實作細節，保守起見只要 link 指向根目錄外就拒絕。

### 變數在啟動時讀一次，由 server 傳給兩條路徑

`TelegramAllLib` 新增 `ExportRoot`（與 `IdleTimeout` 同形）：`environmentVariable`、`parse(_:)`、`fromEnvironment(_:)`。`CheTelegramAllMCPServer` 的 convenience init 呼叫 `ExportRoot.fromEnvironment()`，designated init 收 `exportRoot: String?`（預設 nil）並存起來；TDLib 模式以 `MarkdownExporter(client:exportRoot:)` 傳入，本機快取路徑以 `LocalCacheReading.dumpChatToMarkdown(...exportRoot:)` 傳入。server 是唯一擁有這個值的地方，兩條路徑拿到同一個值；測試以 designated init 注入，不改測試 process 的環境變數。

替代方案是讓 `LocalTDLibReader` 自己存根目錄：要在 convenience init 對 reader 與 exporter 各注入一次，日後重構容易漏一邊；協定多一個參數只影響三個測試替身，採用協定參數。

### CLI 不變

`telegram-all history --dump-markdown` 是使用者在終端機下的指令，不經 `parseDumpChatToMarkdownArgs`，`MarkdownExporter(client:)` 的 `exportRoot` 預設 nil，行為與現在相同。

## Implementation Contract

- **行為**：`dump_chat_to_markdown` 在讀任何訊息之前，拒絕不是絕對路徑、含 `..` 元件、或不以 `.md`（不分大小寫）結尾的 `output_path`，回 `isError: true` 的 `Error: output_path must ...; got "<值>"`。server 啟動時 `CHE_TELEGRAM_ALL_EXPORT_ROOT` 有非空值時，兩條寫入路徑都在抓訊息之前，拒絕解析 symlink 後不在根目錄之內的 `output_path`（`Output path is outside CHE_TELEGRAM_ALL_EXPORT_ROOT (<root>) or could not be resolved: <path>`，`<root>` 是設定值原樣）；根目錄不是既存目錄的絕對路徑時拒絕每一次 dump（`CHE_TELEGRAM_ALL_EXPORT_ROOT is not an absolute path to an existing directory: <root>`）。沒設或空字串時，只有父目錄存在且可寫的既有檢查。
- **介面**：
  - `parseDumpChatToMarkdownArgs(_:timeZone:)` 簽名不變，多三條 `HandlerArgError`：`output_path must be an absolute path; got "<p>"`、`output_path must not contain '..' components; got "<p>"`、`output_path must end in .md; got "<p>"`。
  - `TelegramAllLib`：`public enum ExportRoot { static let environmentVariable = "CHE_TELEGRAM_ALL_EXPORT_ROOT"; static func parse(_ value: String?) -> String?; static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? }`，nil 或空字串回 nil，其他值原樣回傳。
  - `MarkdownExporter.ExportError` 新增 `outsideExportRoot(path: String, root: String)` 與 `exportRootUnusable(root: String)`；`MarkdownExporter.init(client:exportRoot: String? = nil)`。
  - `internal func validateOutputPath(_ path: String, exportRoot: String? = nil) throws`：先做根目錄檢查（`exportRoot` 非 nil 時），再做既有的父目錄檢查。
  - `LocalCacheReading.dumpChatToMarkdown` 多一個最後的參數 `exportRoot: String?`；`LocalTDLibReader.dumpChatToMarkdown` 的同名參數預設 nil。
  - `CheTelegramAllMCPServer.init(lock:idleTimeout:reader:syncState:exportRoot:)`，`exportRoot` 預設 nil；convenience init 傳 `ExportRoot.fromEnvironment()`。
  - tool schema 的 `output_path` 說明寫出三條規則、根目錄與「既有檔案會被取代」。
- **錯誤與邊界**：`output_path` 缺少時仍是 `output_path is required`。`..` 只看整段元件。路徑解析的邊界照「解析 symlink：最長既存前綴」一節。根目錄檢查在父目錄檢查之前，所以根目錄外且父目錄不存在的路徑回報 `outsideExportRoot`。
- **驗收**：`ParseDumpArgsTests` 的 `testDumpRejectsTraversalPath`、`testDumpRejectsNonMarkdownExtension`、`testDumpRejectsRelativePath`（含錯誤訊息全文與 `.MD` 接受）；`MarkdownExporterContractTests` 的 `testValidateOutputPathRespectsExportRoot`（暫存目錄內：根內接受、根外拒絕、目錄 symlink 逃逸拒絕、檔案 symlink 逃逸拒絕、懸空 symlink 拒絕、根內 symlink 指回根內接受、`..` 在不存在的元件裡拒絕、根目錄不可用拒絕）與 `ExportRoot.parse` 的測試；`LocalReaderToolTests` 驗證本機快取路徑在根目錄外拒絕且不寫檔；`ToolRoutingTests` 驗證 server 把注入的根目錄傳給 reader、三條規則在本機快取路徑也生效；`swift test --skip E2ETests` 兩個 bundle 全過。
- **範圍內**：上述程式、tool schema、`telegram-history-export` spec、README、CHANGELOG。
- **範圍外**：`archive_chat_to_markdown`、`download_message_media`、CLI `--dump-markdown`、預設根目錄、TOCTOU、寫入方式。

## Risks / Trade-offs

- [Risk] 相對路徑與非 `.md` 路徑的既有呼叫會失敗（行為變更）→ CHANGELOG 以 Behavior change 標出，錯誤訊息說出規則；tool schema 本來就寫 Absolute 與 .md。
- [Risk] 副檔名守門擋不住寫到 `~/Documents/x.md` 這類無害但不想要的位置 → 要沙箱就設 `CHE_TELEGRAM_ALL_EXPORT_ROOT`。
- [Risk] TDLib 模式把根目錄傳給 `MarkdownExporter` 的那一行沒有單元測試（需要真的 `TDLibClient`）→ 根目錄邏輯本身在 `validateOutputPath` 測試，本機快取路徑與 server 的傳遞各有測試；TDLib 模式只是同一個值的轉交。
- [Risk] 驗證與寫入之間的 TOCTOU → 見 Non-Goals；這些 tool 不會建立 symlink。
- [Trade-off] 根目錄內指向根目錄外的檔案 symlink 會被拒絕，即使 atomic write 實際上會取代 link → 選保守，不依賴 Foundation 的實作細節。
