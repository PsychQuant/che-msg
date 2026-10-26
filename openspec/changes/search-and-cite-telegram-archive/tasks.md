## 1. 讀取端與搜尋腳本

- [x] 1.1 先寫失敗的測試 `tests/che-telegram-mcp/test-archive-search.sh`（Requirement: Archive reader contract；Requirement: Message citation；Requirement: Search filters and bounded output；Requirement: Read-only search with the git-ignore guard）：只用合成日檔，涵蓋 spec 範例日檔、#72 標記行與其他 HTML 註解行、多行內文、跳脫行、不相符的檔案、CR、FIFO、symlink 日檔與聊天目錄、frontmatter 不符、重複錨點、超出 Int64 的錨點、寄件人與日期與聊天條件、上限與截斷、摘錄、case folding、雙向字元、引用解析與錯誤格式、git 檢查（ignore、未 ignore、已追蹤、`GIT_DIR` 指向別處、不在 repo）、唯讀。驗證：腳本還不存在時測試失敗
- [x] 1.2 依設計「Skill 加一支附帶腳本，而不是純 prose 或 server 工具」「腳本用 Python 標準函式庫，以 `python3 -I` 執行」「讀取端契約放在新 capability，不改 `telegram-chat-archive`」「錨點後的 HTML 註解行一律是註記」「跳脫還原」「git 檢查做在腳本裡，檢查實際要讀的檔案」「輸出是一個 JSON 物件，危險字元寫成跳脫」「結果與上限」實作 `plugins/che-telegram-mcp/skills/archive-telegram-search/scripts/search_archive.py`（標準函式庫，相容 Python 3.9）。驗證：1.1 的測試在 `python3` 與 `/usr/bin/python3` 都通過 [after: 1.1]

## 2. Skill 與 layout 測試

- [x] 2.1 先在 `tests/che-telegram-mcp/test-plugin-layout.sh` 的 (h) 加入 `archive-telegram-search`，並在 mutation 測試加入：新 skill 缺 `disable-model-invocation`、新 skill 預先核准 Bash、新 skill 預先核准 `archive_chat_to_markdown`。驗證：skill 還不存在時 (h) 失敗 [after: 1.2]
- [x] 2.2 依 Requirement: archive-telegram-search skill 與設計「不預先核准任何工具」「維護者不在時採用的預設（default chosen while the maintainer was away）」寫 `plugins/che-telegram-mcp/skills/archive-telegram-search/SKILL.md`（設定、`output_dir` 規則、單引號規則、呼叫腳本、結果與錯誤的呈現、引用的限制、隱私規則），`telegram-messaging` 加一行指向它。驗證：`test-plugin-layout.sh` 與 mutation 測試通過，`claude plugin validate plugins/che-telegram-mcp` 通過 [after: 2.1]

## 3. 文件

- [x] 3.1 plugin README：Skills 表、只在輸入時執行的 skill 清單、Usage Examples、新段落「Searching the archive」（設定、輸出、引用與限制、隱私）；CHANGELOG `[Unreleased]` 記錄 #80。驗證：README 寫的參數與上限和腳本一致；`for t in tests/che-telegram-mcp/*.sh; do bash "$t" | tail -1; done` 全部通過 [after: 2.2]
