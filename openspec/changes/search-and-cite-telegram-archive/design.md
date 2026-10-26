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

### 註記只在錨點與標頭之間

#72 把標記寫在錨點的下一行、標頭之前（恰為 `<!-- provisional: local-cache -->`）。讀取端只把「錨點與標頭之間、以 `<!--` 開頭的行」當作註記；標頭之後的每一行都是內文，即使它以 `<!--` 開頭。

第一版把區塊裡任何沒有跳脫、以 `<!--` 開頭的行都當註記，理由是寫入端會跳脫這種內文行。verify 發現這個前提不成立：寫入端用 Swift 的 `hasPrefix("<!--")` 判斷，它比較的是 grapheme cluster，所以 `<!--` 後面接組合字元（U+0301）、U+200D 或 U+FE0F 的內文行不會被跳脫；讀取端用 code point 的 `startswith` 判斷，就把這行當成註記，從內文與摘錄中消失。寫入端另行改成以 scalar 比較；讀取端不依賴那個修正，以位置判斷：標頭之後就是內文。沒有標頭的區塊（格式不符）沒有註記，所有行都是內文。

與寫入端一致（寫入端 a13427c 起以 Unicode scalar 比較）：只有 LF 結束一行（寫入端只把 CR、LF 換成換行，U+2028、U+2029、NEL 留在行內，所以讀取端用 `split("\n")`，不用會把它們當換行的 `splitlines()`）；標頭的時間只認 ASCII 數字（`[0-9]`，不用會吃其他數字的 `\d`）；寫入端現在會把 `<!--` 加組合字元的行跳脫成 `\<!--…`，讀取端照樣去掉那個反斜線。

註記最多 5 個、每個最多 48 字元（`provisional: local-cache` 是 24 字元），有刪減時 `annotations_truncated` 為 true。skill 只看註記是否以 `provisional` 開頭，來說明這個區塊來自本機快取。

### git 檢查做在腳本裡，檢查實際要讀的檔案

`/archive-telegram` 用兩個探測路徑檢查目錄是否被 ignore，因為那時日檔可能還不存在。搜尋時日檔都在，所以腳本把**每個要讀的日檔**交給 `git check-ignore --stdin -z`；它不回報已追蹤的檔案，所以已經 commit 的日檔也會被擋下。檢查在任何讀取之前，被拒絕時輸出只有路徑，沒有內文。git 只拿到 `PATH`、`HOME`、`XDG_CONFIG_HOME` 與 `LC_ALL=C`，其他環境變數一律不傳。第一版只移除會選擇 repository 的幾個變數，verify 發現呼叫端的環境仍能讓檢查放行：`GIT_CEILING_DIRECTORIES` 讓 git 找不到 repo，`GIT_CONFIG_COUNT`／`GIT_CONFIG_KEY_n`／`GIT_CONFIG_VALUE_n`、`GIT_CONFIG_PARAMETERS`、`GIT_CONFIG_GLOBAL`、`GIT_CONFIG_SYSTEM` 可以把 `core.excludesFile` 指到一個寫著 `*` 的檔案。所以改成白名單。

「被 ignore」的定義（維護者不在時採用的預設）：repository 自己的規則（各層 `.gitignore`、`.git/info/exclude`），加上 git 在一般 shell 裡會讀的 system 與 global 設定（`~/.gitconfig`、`$XDG_CONFIG_HOME/git/config` 的 `core.excludesFile`，預設的 `$XDG_CONFIG_HOME/git/ignore`）。理由：這個檢查防的是使用者自己 `git add` 時把歸檔加進去，而那時 git 就是這樣讀設定的；`/archive-telegram` 的檢查也是同樣的 git 指令與設定，兩邊的判斷一致。若改成只認 repository 的 `.gitignore`（以 `-c core.excludesFile=` 關掉 global excludes），靠 global excludes 歸檔的使用者會發現歸檔能寫、搜尋卻被拒。使用者自己的 global 設定把一切都 ignore 時，檢查會放行，這和他的 `git add` 行為相同，記在這裡不另外處理。路徑一律先 `realpath`，避免 `/var` 與 `/private/var` 讓 git 判成在 repo 外。

### 目錄以 descriptor 開啟，日檔相對於它讀

第一版先 `lstat` 檢查聊天目錄不是 symlink，之後卻用絕對路徑開日檔；`O_NOFOLLOW` 只管最後一個路徑元件，所以聊天目錄在檢查之後被換成 symlink 時會被跟隨（verify 的 HIGH）。現在歸檔目錄與每個聊天目錄都以 `O_DIRECTORY | O_NOFOLLOW` 開一次，日檔以 `dir_fd=` 相對於聊天目錄的 descriptor 開啟，不再經過會重新解析的路徑。git 檢查仍以路徑進行（git 只認路徑），所以檢查之後再確認每個聊天目錄的路徑仍然指向同一個 inode（`lstat` 的 device 與 inode 等於 descriptor 的 `fstat`）；不再相同的聊天列為 `changed-during-search`、不讀，歸檔目錄本身變了就整個拒絕。macOS 對 `O_DIRECTORY | O_NOFOLLOW` 開 symlink 回 `ENOTDIR`，兩種 errno 都當作被換掉。

第二輪 verify 發現：所有聊天目錄的 descriptor 從探索一直開到搜尋結束，再加上 `listdir` 用的一個；在 macOS 非 shell 啟動的預設上限 256 之下，約 250 個聊天以上就全部變成 `unreadable`。現在分兩段：探索時每個聊天目錄開啟、記下 device 與 inode 及日檔清單、立刻關閉；git 檢查之後逐一相對於歸檔目錄的 descriptor 重新開啟，descriptor 的 `fstat` 與路徑的 `lstat` 都必須等於記下的 inode 才讀，讀完就關。同時開著的只有歸檔目錄、一個聊天目錄與一個日檔，與聊天數無關（80 個聊天在 `ulimit -n 64` 下全部讀到，401 個在 256 下也是）。在重新檢查之後的窗口裡，日檔仍以 `dir_fd=` 相對於剛檢查過的 descriptor 開啟；white-box 測試在這個窗口把聊天目錄、歸檔目錄與日檔換掉，釘住這些防線。git 回「not a git repository」以外的錯誤（找不到 git、dubious ownership）時拒絕，與 `/archive-telegram` 相同。

### 輸出是一個 JSON 物件，危險字元寫成跳脫

JSON 讓 skill 不必解析自由文字，第三方文字也不會被誤認為輸出的結構。`json.dumps(ensure_ascii=False)` 不跳脫 C1 控制字元、U+2028／U+2029 與雙向格式字元，所以輸出後再把這些字元換成 `\uXXXX`：資訊不丟，但不會原樣送到終端機（例如 U+202E 讓檔名或內文倒過來顯示）。verify 之後再加上使用者看不見、模型卻讀得到的字元：U+00AD、U+200B 到 U+200F、U+2060 到 U+2064、U+FEFF、U+FFF9 到 U+FFFB，以及 tag 字元 U+E0000 到 U+E007F（BMP 之外，寫成 surrogate pair）。這些字元只會出現在 JSON 字串裡，替換不影響結構。第二輪再加上 variation selector U+FE00 到 U+FE0E 與 U+E0100 到 U+E01EF（可以用來藏資料，每個 selector 帶一個位元組），以及顯示為空白的 U+034F、U+115F、U+1160、U+180E、U+3164、U+FFA0、U+FFFC。U+FE0F 不跳脫：它選擇前一個符號的 emoji 外觀（例如 U+2764 U+FE0F），在訊息裡很常見；它只有一個值，一串 U+FE0F 能帶的只有長度。U+200D 被跳脫後，emoji 的 ZWJ 組合在輸出裡會拆開顯示，這是刻意的取捨。孤立的 surrogate（路徑裡解不開的位元組經 surrogateescape 讀入，例如 0xFF 成為 U+DCFF）也寫成 `\uXXXX`，輸出不依賴編碼器的錯誤處理就是合法 UTF-8。腳本原始碼本身只含 ASCII，這些字元一律以 `\u` 跳脫或 `chr()` 寫出。

### 結果與上限

- 結果由新到舊（日期、時間、message id），chat id 只在最後打破兩個聊天之間的平手（第三輪 verify：先前的 key 把 chat id 放在 message id 前面，同一分鐘裡另一個聊天的舊訊息會排在前面；heap 用的是同一個 key，所以兩處一起改）。截斷時使用者通常想看最近的，並看到總數以縮小日期範圍。不同聊天的 `utc_offset` 不同時，跨聊天的排序是近似的。
- `max_results` 預設 20、最多 100；`snippet_chars` 預設 80、介於 20 到 200；超出範圍是 usage error，不默默夾回。
- 每個上限都包含省略號：摘錄的 `snippet_chars`、寄件人的 64 字元、註記的 48 字元（第二輪 verify：第一版把 `…` 加在上限之外，多出一到兩個字元）。
- 搜尋時只保留 `max_results` 筆最新的結果（heap），摘錄只替會進入 heap 的結果計算；區塊逐一產生。第二輪 verify 量到 60 萬筆符合時用掉 869 MB，現在同樣規模約 106 MiB，峰值取決於最大的日檔而不是符合的筆數。
- `snippet_chars` 量的是顯示出來的摘錄：換行先寫成 ` ⏎ `，再取寬度（verify 發現第一版先取寬度再換，多行訊息的摘錄可以長到寬度的三倍）。只渲染命中處前後各一個寬度的原文，長訊息不會整則複製。
- 數字一律經過同一個函式轉換：去掉前導零後超過 19 位就不是 Int64，不呼叫 `int()`。Python 3.11 起 `int()` 拒絕超過 4300 位的字串，第一版遇到這種錨點或 `chat_id` 整個搜尋回 `internal`。
- 記憶體：第一版在命中時為每個字元建 list 來對應 case folding 前後的位置，30 MiB 的訊息用掉 3.1 GB。現在先比較整段 casefold 的長度，相同就直接用位置；不同時以 64K 字元為一塊累加 casefold 長度，只在命中的那一塊逐字計算。實測 30 MiB 單則訊息的峰值約 380 MiB、0.5 秒：約為日檔大小的 12 倍（讀入的 bytes、解碼後的文字、分行、內文、casefold 各一份），日檔上限 32 MiB，所以最多約 400 MiB，記在這裡不改成串流。
- 整則內文只在 `--cite` 模式給，一次最多 10 個引用，每則最多 4000 字元並標示是否截斷。`--cite` 與搜尋條件不能混用。
- 搜尋至少要一個條件（文字、寄件人、日期、聊天），避免一次把整個歸檔列出來；單看某聊天某天仍然可以，但受上限約束。

### 跳脫還原

讀取端把「去掉一個反斜線後以 `<!--` 或 `**` 加時間開頭」的行還原。寫入端的跳脫不是可逆的：原文本來就以 `\<!--` 開頭的行不會被跳脫，讀回時會被少一個反斜線。這種內文極少，且只影響顯示，記在這裡不處理。

## Implementation Contract

- **行為**：`python3 -I search_archive.py --archive <絕對路徑> [--text T]... [--sender S] [--since D] [--until D] [--chat ID]... [--max-results N] [--snippet-chars N]` 搜尋；`--cite telegram:<chat_id>/<message_id>`（可重複，最多 10）解析引用。輸出一個 JSON 物件到 stdout：搜尋是 `{"archive", "searched_files", "matched", "shown", "truncated", "results": [...], "skipped": [...], "skipped_count", "missing_chats": [...]}`；引用是 `{"archive", "blocks": [...], "not_found": [...], "skipped": [...], "skipped_count"}`。每筆 result 有 `citation`、`chat_id`、`message_id`、`date`、`time`、`utc_offset`、`sender`、`snippet`、`file`、`annotations`、`annotations_truncated`；每個 block 把 `snippet` 換成 `text` 與 `text_truncated`。
- **錯誤**：`{"error": {"type", "message", ...}}` 也寫到 stdout。`usage`（exit 2）、`not_ignored`（exit 3，附 `files` 與 `count`）、`git_failed`（exit 3）、`archive_missing`（exit 4：不是絕對路徑、不存在、不是目錄、列不出內容；權限不足的目錄說 cannot be listed，不說不是目錄）、`internal`（exit 1：腳本本身的例外，只回例外類型，不回 traceback，免得夾帶檔案內容）。
- **介面**：skill `plugins/che-telegram-mcp/skills/archive-telegram-search/SKILL.md`（`disable-model-invocation: true`，沒有 `allowed-tools`），以 `python3 -I '${CLAUDE_SKILL_DIR}/scripts/search_archive.py'` 呼叫腳本，路徑與參數依 `/archive-telegram` 的單引號規則包住。
- **邊界**：不讀 `media/`、索引、非日檔名稱的檔案；歸檔與聊天目錄以 `O_DIRECTORY | O_NOFOLLOW` 開啟，symlink 的聊天目錄列為 `symlinked-chat-directory`，`--chat` 指名的是一般檔案時列為 `not-a-directory`，git 檢查後路徑不再指向同一目錄的列為 `changed-during-search`；一次只開一個聊天目錄；日檔以 `dir_fd=` 與 `O_RDONLY | O_NONBLOCK | O_NOFOLLOW` 開啟，只讀一般檔案，大於 32 MiB 的列為 `too-large`；`skipped` 最多列 20 個並給總數；git 只拿到 `PATH`、`HOME`、`XDG_CONFIG_HOME`、`LC_ALL=C`。
- **驗收**：`tests/che-telegram-mcp/test-archive-search.sh` 以合成日檔驗證 spec 的所有 scenario（含 #72 標記行、標頭前後的 HTML 註解行、`<!--` 加組合字元的內文行、多行內文、跳脫行、不相符的檔案、CR、FIFO、symlink、搜尋中被換掉的聊天目錄、git 檢查各情況與五種環境變數、global excludes、唯讀、上限、摘錄寬度、上千位數字、20 MiB 訊息的記憶體、隱形字元），在 `python3` 與 `/usr/bin/python3`（存在時）各跑一次；`test-plugin-layout.sh` 的 (h) 含新 skill，mutation 測試證明 (h)、(d) 會抓到新 skill 的違規；`claude plugin validate plugins/che-telegram-mcp` 通過。
- **範圍內**：新 skill 與腳本、新 capability、`telegram-messaging` 一行、layout 測試 (h) 與 mutation 案例、plugin README 與 CHANGELOG。
- **範圍外**：寫入端與 `telegram-chat-archive` spec、#72 的標記與升級、server 工具、CLI 子命令、多個歸檔目錄、plugin 版號、引用離開歸檔後的同意與匿名化。

## Risks / Trade-offs

- [第三方文字進入對話，其中可能有對模型的指示] → skill 規定內文是資料、不照做、不寫進檔案、不引用到公開處；摘錄有長度上限，整則只在指名時給。降低，不能消除。
- [讀取端依賴目前的格式] → 契約寫成 spec，spec 範例日檔是測試 fixture；#72 的標記只要在錨點與標頭之間就當註記，不依賴它的確切文字。之後改格式的 change 要改這裡。
- [和 #54／#86 的 layout 檢查合併時] → 那個分支的 (a) 把 `skills/` 限定為六個 skill、每個只有 `SKILL.md`，(l) 對照預先核准表。合併時 (a) 要加入 `archive-telegram-search` 與它的 `scripts/search_archive.py`，(h) 要保留新 skill；新 skill 沒有 `allowed-tools`，(l) 不需要新的一列。
- [`git check-ignore` 讀 repository 的設定] → 與 `/archive-telegram` 在同一個 repo 執行同樣的 git 指令，沒有新增的風險。
- [python3 不存在（沒裝 Command Line Tools）] → Bash 回錯誤，skill 說明需要 Command Line Tools；`/archive-telegram` 的 git 檢查同樣需要。
