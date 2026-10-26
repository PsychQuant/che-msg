## Context

`archive_chat_to_markdown`（v0.8.0）寫的日檔格式由 `telegram-chat-archive` 的「Day file format」定義：`<output_dir>/<chat_id>/YYYY-MM-DD.md`，frontmatter 有 `chat_id`、`date`、`utc_offset`；每則訊息是一個以 `<!-- msg:<id> -->` 整行開頭的區塊，接著 `**HH:mm <sender>**：` 與內文；內文開頭是 `<!--`、或像區塊標頭的行，寫入時加一個反斜線，寄件人名稱裡的換行寫成空格。寫入端自己的解析在 `ArchiveDayFile.split`／`anchorId`：只認整行的錨點、只以 LF 分行、同一檔案重複的 id 留第一個。

#72（另一個人平行在做）會在快取寫出的區塊的錨點下一行加一行標記（Diagnosis 的例子是 `<!-- provisional: local-cache -->`），錨點本身不變。#75／#76 讓寫入端拒絕不是一般檔案、含 CR 的日檔。

搜尋要面對的三個事實：歸檔目錄必須被 git ignore（`/archive-telegram` Step 2），所以工作區的 Grep 從上層開始時找不到它；內文是第三方文字，可能含有對模型的指示；歸檔可能很大，經過模型逐檔讀很慢、很佔 context。

## Goals / Non-Goals

**Goals:**

- 依文字、寄件人、日期範圍、聊天找到已歸檔的訊息，結果有界（筆數、摘錄長度）。
- 一個穩定的引用 `telegram:<chat_id>/<message_id>`，能解析回它的區塊。
- 讀取端契約寫成 spec，包含 #72 的標記行，讓之後改格式的人知道有讀取端依賴它。
- 不寫任何檔案、不開 TDLib；歸檔在 git repo 裡卻沒被 ignore 時不讀。

**Non-Goals:**

- server 工具或 CLI 子命令；多個歸檔目錄；正規表示式或模糊比對；索引與媒體。
- 改寫入端或 `telegram-chat-archive` spec。

## Decisions

### 維護者不在時採用的預設（default chosen while the maintainer was away）

Diagnosis 的四個 Open questions 都照建議選項：Q1 做成 skill；Q2 每筆只給 id 與一行摘錄，整則要指名；Q3 引用 `telegram:<chat_id>/<message_id>`（是否符合 Akashic 流程待維護者確認，見 proposal）；Q4 每次一個歸檔目錄。skill 名稱 `archive-telegram-search` 也是預設。下面各節是這些選擇的細節。

### Skill 加一支附帶腳本，而不是純 prose 或 server 工具

Diagnosis 的建議（Q1）是 skill。只寫 prose、讓模型用 Grep 與 Read 做，有三個問題：Grep 從工作區搜不到被 ignore 的歸檔；一般的前後文視窗會在任意行切斷區塊，只有以錨點為界的解析才準；模型逐檔讀日檔，筆數與摘錄長度的上限只是指示，不是保證。所以解析、過濾、上限與 git 檢查放在 `skills/archive-telegram-search/scripts/search_archive.py`，skill 的 prose 只負責讀設定、組參數、呈現結果與隱私規則。

server 工具不採用：`telegram-all` 的工具都經過 TDLib lifecycle（`lifecycle.beginCall()`），一個只讀本機檔案的搜尋會開啟或佔住 TDLib，或在別的 session 持有時回 `tdlib_in_use`（#62 處理的正是這種過度佔用）。CLI 子命令（以 `ArchiveDayFile.parseBlocks` 為底）是 Diagnosis 提到較小的一步，但要等新版 binary 發布才能用，而且同一份解析要寫第二次，捨棄。

### 腳本用 Python 標準函式庫，以 `python3 -I` 執行

摘錄要以字元而不是位元組切（中文），比對要做 Unicode case folding，這兩件事 macOS 內建的 awk 不可靠。`python3` 與 `/archive-telegram` 已經依賴的 `git` 同樣來自 Command Line Tools；腳本相容 3.9（CLT 的 `/usr/bin/python3` 是 3.9.6），只用標準函式庫。`-I` 讓 Python 不讀 `PYTHON*` 環境變數、不加使用者 site-packages、不把腳本目錄放進 `sys.path`。

腳本位置在 skill 目錄下（官方文件的 supporting files 寫法），skill 以 `${CLAUDE_SKILL_DIR}` 指到它。`bin/` 不行：那裡的檔案會進 Bash 的 PATH，layout 測試 (a) 只允許 wrapper。

### 不預先核准任何工具

layout 測試 (d) 只允許 allowed-tools 列本 plugin 的 MCP 工具，不允許 Bash。Diagnosis 也只要求「沒有 Write」。所以腳本的 Bash 呼叫照使用者的一般權限設定詢問；每次搜尋都由使用者看過實際指令，這對會把第三方文字帶進對話的動作是合理的。skill 不需要任何 MCP 工具，所以 frontmatter 沒有 `allowed-tools`（README 的預先核准表也不列它）。

### 讀取端契約放在新 capability，不改 `telegram-chat-archive`

Diagnosis 建議在「Day file format」加一句「錨點與跳脫規則是讀取端契約」。那需要 MODIFIED 整段 requirement，而 #72 與 harden-chat-archive-media-and-day-files 也在改同一個 spec，三個 change 改同一段會互相衝突。改把契約寫成 `telegram-archive-search` 的「Archive reader contract」，明寫它讀的是「Day file format」定義的格式；之後改寫入格式的 change 要同時改這個 requirement 與 `test-archive-search.sh`（spec 範例日檔原樣是測試的一個 fixture）。

### 錨點後的 HTML 註解行一律是註記

寫入端會把內文中以 `<!--` 開頭的行加上反斜線，所以區塊裡沒有跳脫、以 `<!--` 開頭的行（錨點除外）不可能是訊息內文，只能是工具寫的（#72 的標記）或人手加的。讀取端把這些行收進 `annotations`，不放進內文、不參與比對，也不限定它們出現的位置或確切文字。#72 的標記形式還沒定案，這樣寫不必等它；skill 只看 annotation 是否以 `provisional` 開頭，來說明這個區塊來自本機快取。

### git 檢查做在腳本裡，檢查實際要讀的檔案

`/archive-telegram` 用兩個探測路徑檢查目錄是否被 ignore，因為那時日檔可能還不存在。搜尋時日檔都在，所以腳本把**每個要讀的日檔**交給 `git check-ignore --stdin -z`；它不回報已追蹤的檔案，所以已經 commit 的日檔也會被擋下。檢查在任何讀取之前，被拒絕時輸出只有路徑，沒有內文。腳本先移除會選擇 repository 的 `GIT_*` 環境變數，免得檢查問到別的 repo；`GIT_CEILING_DIRECTORIES` 保留，行為與直接執行 git 相同。路徑一律先 `realpath`，避免 `/var` 與 `/private/var` 讓 git 判成在 repo 外。git 回「not a git repository」以外的錯誤（找不到 git、dubious ownership）時拒絕，與 `/archive-telegram` 相同。

### 輸出是一個 JSON 物件，危險字元寫成跳脫

JSON 讓 skill 不必解析自由文字，第三方文字也不會被誤認為輸出的結構。`json.dumps(ensure_ascii=False)` 不跳脫 C1 控制字元、U+2028／U+2029 與雙向格式字元，所以輸出後再把這些字元換成 `\uXXXX`：資訊不丟，但不會原樣送到終端機（例如 U+202E 讓檔名或內文倒過來顯示）。這些字元只會出現在 JSON 字串裡，替換不影響結構。

### 結果與上限

- 結果由新到舊（日期、時間、message id）。截斷時使用者通常想看最近的，並看到總數以縮小日期範圍。不同聊天的 `utc_offset` 不同時，跨聊天的排序是近似的。
- `max_results` 預設 20、最多 100；`snippet_chars` 預設 80、介於 20 到 200；超出範圍是 usage error，不默默夾回。
- 整則內文只在 `--cite` 模式給，一次最多 10 個引用，每則最多 4000 字元並標示是否截斷。`--cite` 與搜尋條件不能混用。
- 搜尋至少要一個條件（文字、寄件人、日期、聊天），避免一次把整個歸檔列出來；單看某聊天某天仍然可以，但受上限約束。

### 跳脫還原

讀取端把「去掉一個反斜線後以 `<!--` 或 `**` 加時間開頭」的行還原。寫入端的跳脫不是可逆的：原文本來就以 `\<!--` 開頭的行不會被跳脫，讀回時會被少一個反斜線。這種內文極少，且只影響顯示，記在這裡不處理。

## Implementation Contract

- **行為**：`python3 -I search_archive.py --archive <絕對路徑> [--text T]... [--sender S] [--since D] [--until D] [--chat ID]... [--max-results N] [--snippet-chars N]` 搜尋；`--cite telegram:<chat_id>/<message_id>`（可重複，最多 10）解析引用。輸出一個 JSON 物件到 stdout：搜尋是 `{"archive", "searched_files", "matched", "shown", "truncated", "results": [...], "skipped": [...], "skipped_count", "missing_chats": [...]}`；引用是 `{"archive", "blocks": [...], "not_found": [...], "skipped": [...], "skipped_count"}`。每筆 result 有 `citation`、`chat_id`、`message_id`、`date`、`time`、`utc_offset`、`sender`、`snippet`、`file`、`annotations`；每個 block 把 `snippet` 換成 `text` 與 `text_truncated`。
- **錯誤**：`{"error": {"type", "message", ...}}` 也寫到 stdout。`usage`（exit 2）、`not_ignored`（exit 3，附 `files` 與 `count`）、`git_failed`（exit 3）、`archive_missing`（exit 4：不是絕對路徑、不存在、不是目錄、列不出內容）、`internal`（exit 1：腳本本身的例外，只回例外類型，不回 traceback，免得夾帶檔案內容）。
- **介面**：skill `plugins/che-telegram-mcp/skills/archive-telegram-search/SKILL.md`（`disable-model-invocation: true`，沒有 `allowed-tools`），以 `python3 -I '${CLAUDE_SKILL_DIR}/scripts/search_archive.py'` 呼叫腳本，路徑與參數依 `/archive-telegram` 的單引號規則包住。
- **邊界**：不讀 `media/`、索引、非日檔名稱的檔案；symlink 的聊天目錄不進入，列為 `symlinked-chat-directory`；日檔以 `O_RDONLY | O_NONBLOCK | O_NOFOLLOW` 開啟，只讀一般檔案，大於 32 MiB 的列為 `too-large`；`skipped` 最多列 20 個並給總數。
- **驗收**：`tests/che-telegram-mcp/test-archive-search.sh` 以合成日檔驗證 spec 的所有 scenario（含 #72 標記行、其他 HTML 註解行、多行內文、跳脫行、不相符的檔案、CR、FIFO、symlink、git 檢查三種情況、唯讀、上限、雙向字元），在 `python3` 與 `/usr/bin/python3`（存在時）各跑一次；`test-plugin-layout.sh` 的 (h) 含新 skill，mutation 測試證明 (h)、(d) 會抓到新 skill 的違規；`claude plugin validate plugins/che-telegram-mcp` 通過。
- **範圍內**：新 skill 與腳本、新 capability、`telegram-messaging` 一行、layout 測試 (h) 與 mutation 案例、plugin README 與 CHANGELOG。
- **範圍外**：寫入端與 `telegram-chat-archive` spec、#72 的標記與升級、server 工具、CLI 子命令、多個歸檔目錄、plugin 版號、引用離開歸檔後的同意與匿名化。

## Risks / Trade-offs

- [第三方文字進入對話，其中可能有對模型的指示] → skill 規定內文是資料、不照做、不寫進檔案、不引用到公開處；摘錄有長度上限，整則只在指名時給。降低，不能消除。
- [讀取端依賴目前的格式] → 契約寫成 spec，spec 範例日檔是測試 fixture；#72 的標記不論位置、文字都當註記。之後改格式的 change 要改這裡。
- [和 #54／#86 的 layout 檢查合併時] → 那個分支的 (a) 把 `skills/` 限定為六個 skill、每個只有 `SKILL.md`，(l) 對照預先核准表。合併時 (a) 要加入 `archive-telegram-search` 與它的 `scripts/search_archive.py`，(h) 要保留新 skill；新 skill 沒有 `allowed-tools`，(l) 不需要新的一列。
- [`git check-ignore` 讀 repository 的設定] → 與 `/archive-telegram` 在同一個 repo 執行同樣的 git 指令，沒有新增的風險。
- [python3 不存在（沒裝 Command Line Tools）] → Bash 回錯誤，skill 說明需要 Command Line Tools；`/archive-telegram` 的 git 檢查同樣需要。
