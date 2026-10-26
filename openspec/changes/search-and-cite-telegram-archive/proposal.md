## Why

`/archive-telegram`（#69）把對話寫成每日 Markdown 檔，目的是日後能在寫作中引用。但目前沒有任何方法找到並引用一則已歸檔的訊息，只能整份打開日檔（PsychQuant/che-msg#80）。工作區的 Grep 也找不到：歸檔目錄必須在 `.gitignore` 裡，而以 ripgrep 為底的搜尋從上層目錄開始時會略過被 ignore 的路徑。同時，搜尋的用途就是把訊息內文給使用者看，所以 `/archive-telegram`「報告不引用內文」的規則不能照搬，需要為「內文會進入對話」重新定隱私規則。

## What Changes

- 新增 skill `archive-telegram-search`（只在使用者輸入時執行，不預先核准任何工具）：讀 `.claude/.telegram/config.yaml` 的 `output_dir` 與聊天 label，在這一個歸檔目錄裡依文字、寄件人、日期範圍、聊天搜尋，每筆結果一行（label、日期、時間、`utc_offset`、寄件人、短摘錄、引用）；使用者指名引用時才顯示整則訊息。
- skill 附一支唯讀的 Python 腳本 `skills/archive-telegram-search/scripts/search_archive.py`（只用標準函式庫，以 `python3 -I` 執行）：照錨點逐區塊解析日檔，把錨點之後的 HTML 註解行（#72 的標記）當作註記而不是訊息內文，還原寫入端加的反斜線跳脫，套用筆數與摘錄長度上限，輸出一個 JSON 物件，控制字元與雙向格式字元一律寫成 `\uXXXX`。
- 讀任何日檔之前，腳本先問 git 歸檔是否在 work tree 裡；在的話，要讀的每個日檔都必須被 ignore（已 commit 的不算），否則拒絕且不讀任何檔案。
- 引用格式 `telegram:<chat_id>/<message_id>`，以日檔裡的錨點行解析；每次給出引用都附上日期、時間、寄件人、`utc_offset` 與限制說明。
- 新 capability `telegram-archive-search`：讀取端契約、引用、搜尋與輸出上限、唯讀與 git 檢查、skill 的隱私規則。
- `telegram-messaging` 加一行：搜尋本機歸檔請使用者輸入這個 skill，不要自己 Grep 歸檔目錄。
- plugin README、CHANGELOG `[Unreleased]`；layout 測試的 (h) 加入新 skill，並加 mutation 案例。

## Non-Goals

- 不做 server 工具、不做 `telegram-all` CLI 子命令（見下方預設 Q1）。
- 不一次搜尋多個歸檔目錄（Q4），不接受設定檔以外的歸檔路徑。
- 不做正規表示式、模糊比對或全形半形正規化；比對是 Unicode case folding 後的子字串。
- 不讀索引（`index.json`）與媒體檔；書籤與搜尋無關，聊天目錄與日檔 frontmatter 已有需要的一切。
- 不改歸檔的寫入端（`ArchiveDayFile.swift`）與 `telegram-chat-archive` spec；#72 的標記與升級規則由 #72 處理。
- 不處理引用離開歸檔之後的歸屬問題（被引用者的同意、匿名化），那是 Diagnosis 的 Residue，由維護者決定。

## Defaults chosen while the maintainer was away

#80 的 Diagnosis 留了四個 Open questions。維護者不在，以下照 Diagnosis 的建議選項，並記在 design 與 commit message：

| 問題 | 採用的預設 |
|------|------------|
| Q1 放在哪 | skill（唯讀，讀 `/archive-telegram` 寫的日檔與設定檔），不是 server 工具；決定性的解析放在 skill 附帶的腳本裡 |
| Q2 預設曝光 | 每筆只給 id 與一行摘錄；使用者指名引用時才給整則 |
| Q3 引用文字 | `telegram:<chat_id>/<message_id>`，加上人讀的形式（label、日期、時間、寄件人、`utc_offset`） |
| Q4 範圍 | 每次只搜一個歸檔目錄（工作區設定檔的 `output_dir`） |
| skill 名稱（Diagnosis 待定） | `archive-telegram-search`：不和既有的線上搜尋 skill `search` 混淆，並與 `/archive-telegram` 成對（郵件那邊是 `/archive-mail-view`） |

**待維護者確認（Q3）**：Diagnosis 問這個引用文字是否適合維護者的 Akashic／筆記流程。這個 change 只定義引用文字與解析規則，不改其他 repo；若 Akashic 需要別的形式（例如 URI scheme 或 `chat_id` 以外的穩定鍵），之後改的是本 capability 的「Message citation」requirement 與腳本的引用格式。

## Capabilities

### New Capabilities

- `telegram-archive-search`：歸檔日檔的讀取端契約、訊息引用格式與解析、搜尋條件與輸出上限、唯讀與 git-ignore 檢查、`archive-telegram-search` skill 的行為與隱私規則。

### Modified Capabilities

（無）

## Impact

- 受影響的 spec：新增 `telegram-archive-search`；`telegram-chat-archive` 不改（讀取端契約引用它的「Day file format」）
- skill：`plugins/che-telegram-mcp/skills/archive-telegram-search/SKILL.md`、`plugins/che-telegram-mcp/skills/archive-telegram-search/scripts/search_archive.py`、`plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md`（一行）
- 測試：新增 `tests/che-telegram-mcp/test-archive-search.sh`；`tests/che-telegram-mcp/test-plugin-layout.sh` 的 (h)、`tests/che-telegram-mcp/test-plugin-layout-mutations.sh`
- 文件：`plugins/che-telegram-mcp/README.md`、`plugins/che-telegram-mcp/CHANGELOG.md`
- binary：無；不需要新版 `che-telegram-all-mcp`，plugin 版號不在這個 change 裡升
