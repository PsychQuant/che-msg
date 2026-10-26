## 1. 讀取端與搜尋腳本

- [x] 1.1 先寫失敗的測試 `tests/che-telegram-mcp/test-archive-search.sh`（Requirement: Archive reader contract；Requirement: Message citation；Requirement: Search filters and bounded output；Requirement: Read-only search with the git-ignore guard）：只用合成日檔，涵蓋 spec 範例日檔、#72 標記行與其他 HTML 註解行、多行內文、跳脫行、不相符的檔案、CR、FIFO、symlink 日檔與聊天目錄、frontmatter 不符、重複錨點、超出 Int64 的錨點、寄件人與日期與聊天條件、上限與截斷、摘錄、case folding、雙向字元、引用解析與錯誤格式、git 檢查（ignore、未 ignore、已追蹤、`GIT_DIR` 指向別處、不在 repo）、唯讀。驗證：腳本還不存在時測試失敗
- [x] 1.2 依設計「Skill 加一支附帶腳本，而不是純 prose 或 server 工具」「腳本用 Python 標準函式庫，以 `python3 -I` 執行」「讀取端契約放在新 capability，不改 `telegram-chat-archive`」「錨點後的 HTML 註解行一律是註記」「跳脫還原」「git 檢查做在腳本裡，檢查實際要讀的檔案」「輸出是一個 JSON 物件，危險字元寫成跳脫」「結果與上限」實作 `plugins/che-telegram-mcp/skills/archive-telegram-search/scripts/search_archive.py`（標準函式庫，相容 Python 3.9）。驗證：1.1 的測試在 `python3` 與 `/usr/bin/python3` 都通過 [after: 1.1]

## 2. Skill 與 layout 測試

- [x] 2.1 先在 `tests/che-telegram-mcp/test-plugin-layout.sh` 的 (h) 加入 `archive-telegram-search`，並在 mutation 測試加入：新 skill 缺 `disable-model-invocation`、新 skill 預先核准 Bash、新 skill 預先核准 `archive_chat_to_markdown`。驗證：skill 還不存在時 (h) 失敗 [after: 1.2]
- [x] 2.2 依 Requirement: archive-telegram-search skill 與設計「不預先核准任何工具」「維護者不在時採用的預設（default chosen while the maintainer was away）」寫 `plugins/che-telegram-mcp/skills/archive-telegram-search/SKILL.md`（設定、`output_dir` 規則、單引號規則、呼叫腳本、結果與錯誤的呈現、引用的限制、隱私規則），`telegram-messaging` 加一行指向它。驗證：`test-plugin-layout.sh` 與 mutation 測試通過，`claude plugin validate plugins/che-telegram-mcp` 通過 [after: 2.1]

## 3. 文件

- [x] 3.1 plugin README：Skills 表、只在輸入時執行的 skill 清單、Usage Examples、新段落「Searching the archive」（設定、輸出、引用與限制、隱私）；CHANGELOG `[Unreleased]` 記錄 #80。驗證：README 寫的參數與上限和腳本一致；`for t in tests/che-telegram-mcp/*.sh; do bash "$t" | tail -1; done` 全部通過 [after: 2.2]

## 4. verify 第一輪的修正

- [x] 4.1 先寫失敗的測試（Requirement: Archive reader contract；Requirement: Search filters and bounded output；Requirement: Read-only search with the git-ignore guard）：`<!--` 加 U+0301／U+200D／U+FE0F 的內文行、標頭之後的註解行、沒有標頭的區塊；搜尋中聊天目錄被換成 symlink（包住 guard 的 white-box 測試）；`GIT_CEILING_DIRECTORIES`、`GIT_CONFIG_COUNT`、`GIT_CONFIG_PARAMETERS`、`GIT_CONFIG_GLOBAL`、`GIT_CONFIG_SYSTEM` 各自不能放行；global excludes 照 git 的讀法生效；註記上限；含換行標記的摘錄寬度；5000 位數字；20 MiB 訊息的記憶體；隱形字元的跳脫。驗證：舊腳本 308 個檢查有 61 個失敗
- [x] 4.2 依設計「註記只在錨點與標頭之間」「目錄以 descriptor 開啟，日檔相對於它讀」「git 檢查做在腳本裡，檢查實際要讀的檔案」「輸出是一個 JSON 物件，危險字元寫成跳脫」「結果與上限」修正腳本，原始碼只含 ASCII。驗證：308 個檢查在 `python3` 與 `/usr/bin/python3` 都通過 [after: 4.1]
- [x] 4.3 與寫入端一致的案例：U+2028 與 NEL 不結束一行、非 ASCII 數字不是標頭時間、以 scalar 跳脫的 `\<!--` 加組合字元讀回時去掉反斜線。驗證：318 個檢查在兩個 interpreter 都通過 [after: 4.2]

## 5. verify 第二輪的修正

- [x] 5.1 先寫失敗的測試（Requirement: Archive reader contract；Requirement: Search filters and bounded output）：`ulimit -n 64` 下 80 個聊天；12 萬筆符合的記憶體；省略號在上限之內；新增的隱形字元；mode 000 的歸檔與指名一般檔案的 `--chat`；white-box 測試在重新檢查之後換掉聊天目錄、在 git 檢查之後換掉歸檔目錄、換成另一個真目錄、在開啟前換成一般檔案、把日檔換成 link 或 FIFO；32 MiB 上限、10 個 200 字元的詞、20 筆 skipped、5 個被拒的檔案、整行錨點、一般的反斜線、前導零的 `chat_id`、重複的引用、超過 64K 的 case-fold 對應、經 link 給的歸檔路徑。驗證：舊腳本 398 個檢查有 54 個失敗
- [x] 5.2 依設計「目錄以 descriptor 開啟，日檔相對於它讀」「結果與上限」「輸出是一個 JSON 物件，危險字元寫成跳脫」修正腳本：逐一開關聊天目錄、heap、上限含省略號、跳脫字元。驗證：398 個檢查在 `python3` 與 `/usr/bin/python3` 都通過，審查列出的存活 mutant 都被殺掉 [after: 5.1]

## 6. verify 第三輪的修正

- [x] 6.1 先寫測試（Requirement: Search filters and bounded output）：同一日期時間、兩個聊天的 message 999 與 1，`--max-results 1` 取 999；路徑含 0xFF 的錯誤輸出是合法 UTF-8。驗證：排序的案例在舊腳本失敗
- [x] 6.2 依設計「結果與上限」「輸出是一個 JSON 物件，危險字元寫成跳脫」把排序 key 改成日期、時間、message id、chat id，並跳脫孤立的 surrogate。驗證：410 個檢查在 `python3` 與 `/usr/bin/python3` 都通過 [after: 6.1]

