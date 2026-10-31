## Context

使用者要以本人身分連上自己所在的任何 Slack workspace，包括別人管理、不一定核准 app 或 MCP 整合的 workspace，並且讀、搜尋、送訊息、把對話歸檔成 markdown（PsychQuant/che-msg#99）。#99 的 Diagnosis 調查了所有現有的 Slack MCP 與相關工具，結論是只有瀏覽器 session token（`xoxc` token 加 cookie `d`）同時滿足「本人身分」與「任何 workspace」；使用者在 #99 的 Decision comment 選了自建 Swift 版（S1），並在 spectra-discuss 定下 token 取得、送訊息、多 workspace、歸檔四件事。

現況：

- `che-telegram-bot-mcp` 拆成 client library、`*Core`、MCP 入口、CLI 四個 target，平台 macOS 13，依賴 `modelcontextprotocol/swift-sdk`（from 0.12.0）與 `swift-argument-parser`（from 1.5.0）。
- `che-telegram-all-mcp` 以 `/usr/bin/security find-generic-password -g` 讀 Keychain（`KeychainCredentials.swift` 的 `SecurityCLICredentialSource`）：固定 account、有逾時、不快取、描述字串不含值。
- `telegram-chat-archive` spec 規定每日 markdown 格式、可重跑不重複、只抓新訊息、不含內容的 manifest、限流時保留進度。
- `plugins/che-telegram-mcp/README.md` 的免確認表把 `send_message` 刻意排除。
- 使用者的 Mac 上裝的是 Mac App Store 版 Slack，資料在 `~/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack`，裡面有 `Cookies` 與 `Local Storage`，Keychain 有 `Slack Safe Storage` 項目（2026-10-29 只列目錄確認，未讀內容）。

## Goals / Non-Goals

**Goals:**

- 以本人身分、在多個 workspace 讀與搜尋訊息、送訊息、把 conversation 歸檔成每日 markdown。
- 憑證只存在 Keychain，不經過 MCP 工具參數、Claude 的對話、環境變數或命令列參數。
- 第一版同時提供剪貼簿匯入與 Slack 桌面 app 匯入。
- 歸檔格式與 `telegram-chat-archive` 一致，兩個平台的歸檔可以用同一種方式閱讀。

**Non-Goals:**

- 不走 Slack app 的 OAuth（`xoxp`）或 bot token（`xoxb`）：都需要管理員核准，不符 #99 的需求。
- 第一版不下載 Slack 檔案，歸檔只寫檔名與 permalink。
- 不提供編輯、刪除、reaction、標記已讀、未讀數等工具。
- 不從 Chrome 或 Safari 的 cookie 資料庫自動擷取。
- 不發布 GitHub release、不更新 marketplace 的遠端狀態：那是不可逆的動作，另外經使用者確認。
- 不定義 Telegram、LINE、Slack 共用的跨平台工具介面。

## Decisions

### 以瀏覽器 session token 認證

每個 workspace 以一組 `xoxc` token 加 cookie `d` 呼叫 Slack Web API：token 放在 form 欄位 `token`，cookie 放在 `Cookie: d=<value>` 標頭。

替代方案：`xoxp`（自建 app 的 OAuth）、官方 hosted MCP。兩者都要 workspace 管理員核准，不能連別人管理的 workspace，因此不採用（#99 Diagnosis 的 R1＋R2）。

### SlackWebLib 只依賴 Foundation

`SlackWebLib` 以 `URLSession` 打 HTTP，不引入第三方 Slack 套件（Swift 唯一較大的 SlackKit 已在 2022 年歸檔）。傳輸層抽成一個 protocol，正式版用 `URLSession`，測試用假的傳輸，因此 client 的行為（標頭、錯誤分類、重試）可以離線測試。

### Slack 錯誤分成五類

所有 Slack 回應與網路錯誤都歸到下列五類之一，MCP 工具與 CLI 依類別給出不同訊息：

| 類別 | 判定 | 給使用者的訊息 |
|---|---|---|
| session 失效 | `ok:false` 且 error 為 `invalid_auth`、`not_authed`、`token_revoked`、`account_inactive` | 指出是哪個 workspace，並給 `slack-all auth import` 與 `slack-all auth import --from-desktop` 兩個重新匯入的指令 |
| 被限流 | HTTP 429 或 error 為 `ratelimited` | 依 `Retry-After` 等待後重試；超過重試上限才回報 |
| Enterprise Grid 限制 | error 以 `enterprise_` 開頭，或 `team_is_restricted` | 說明 Enterprise Grid 會偵測自動化，建議改用官方 MCP |
| 其他 Slack 錯誤 | 其餘 `ok:false` | 原樣帶出 Slack 的 error 字串 |
| 網路錯誤 | 傳輸層失敗 | 帶出 `URLError` 的描述 |

### 預設請求間隔與並行上限

同一個 workspace 的請求之間至少間隔 350 ms，同時最多 3 個請求；被限流時依 `Retry-After` 等待，最多重試 3 次。

這兩個數字取自 jtalk22/slack-mcp-server 的預設值（`SLACK_MCP_MIN_REQUEST_INTERVAL_MS` 350、`SLACK_MCP_MAX_CONCURRENCY` 3），**沒有在本專案量測過**；它們只降低觸發異常偵測的機率，不能消除。若實際使用時仍被登出，第一個要調的就是這兩個值，所以 MCP server 以環境變數 `SLACK_MCP_MIN_INTERVAL_MS`、`SLACK_MCP_MAX_CONCURRENCY` 讓使用者覆寫。

### 每個 workspace 一組 Keychain 項目加索引

Keychain 的 account 一律是 `che-slack-mcp`，service 分三種：

- `SLACK_WORKSPACES`：索引，值是 JSON 陣列的 base64 編碼（RFC 4648，含補位），每筆含 `team_id`、`domain`、`name`、`user_id`，不含任何憑證。以 base64 儲存是為了讓索引也走同一條寫入路徑：JSON 本身有引號、空白，workspace 名稱可能是中日文，都過不了寫入前的字元檢查（apply 時發現的矛盾，使用者 2026-10-29 選定此解法）。沒有索引項目視為尚未匯入任何 workspace。
- `SLACK_TOKEN_<TEAM_ID>`：該 workspace 的 `xoxc` token。
- `SLACK_COOKIE_<TEAM_ID>`：該 workspace 的 cookie `d`。

`d` 理論上可以多個 workspace 共用，但從不同瀏覽器或桌面 app 匯入時可能不同，所以每個 workspace 各存一份，避免後一次匯入覆蓋前一次。

讀取沿用 `SecurityCLICredentialSource` 的作法：呼叫 `/usr/bin/security find-generic-password -g`、stdin 接 null device、有逾時、值不快取，描述字串以 `<redacted>` 取代值。

匯入在最後寫索引的前一刻重新讀一次 `SLACK_WORKSPACES`，把這次匯入的併進去，而不是用開頭讀到的那份（第五次 review 發現兩個終端機同時匯入，或匯入等待時跑了 `auth remove`，會互相蓋掉：留下選不到也刪不掉的憑證，或讓刪掉的 workspace 復活）。重讀到寫入之間仍有極短的空檔，不另加鎖。索引寫成一行 `security -i` 指令，一行最多 4094 bytes，依 workspace 名稱長度大約可放 25 到 37 個（review 估算，未實測）。匯入在寫入任何憑證之前先檢查合併後的索引放不放得下，放不下就什麼都不寫並說明上限（第二次 review 發現原本會先寫入所有憑證、最後才在索引失敗）。

替代方案：Telegram 的 `KeychainCredential` 是寫死兩個 case 的 enum，Slack 的 workspace 數量不固定，因此改成「索引＋依 team id 組 service 名稱」。

### 寫入 Keychain 不經過 argv

CLI 寫入時執行 `/usr/bin/security -i`，把 `add-generic-password -U -a che-slack-mcp -s <service> -w "<value>"` 這一行從 stdin 送進去，值不出現在任何程序的命令列參數（`ps` 看得到 argv）。寫入前檢查值只含 `A-Z a-z 0-9 - _ . % + / =`、service 名稱裡的 team id 只含 1 到 32 個 `A-Z 0-9`，否則拒絕，避免破壞 `security -i` 的引號解析。

替代方案：`SecItemAdd` 建立的項目，其 ACL 只信任建立它的那個 binary；MCP server 是另一個 executable，讀取時會跳出 Keychain 授權視窗。改用 `security` 寫入與讀取，兩端都經過同一個工具，與 Telegram 的現況一致。`security -i` 從 stdin 讀指令這條路要在實測 task 中確認。

### 剪貼簿匯入：console 一行複製全部 workspace

`slack-all auth import` 分兩步，每步提示使用者複製、按 Enter 後從剪貼簿讀取：

1. 在瀏覽器已登入的 `app.slack.com` 頁面開 console，貼上 CLI 印出的一行指令。它從 `localStorage.localConfig_v2` 取出這個瀏覽器登入的所有 workspace（`id`、`domain`、`name`、`token`、`user_id`），以 JSON 複製到剪貼簿。
2. 從開發者工具的 Storage 分頁複製 cookie `d` 的值。

CLI 對每個 workspace 呼叫 `auth.test` 驗證，只儲存驗證成功的，逐一印出 workspace 名稱與結果，從不印出 token 或 cookie。讀完後清空剪貼簿。

Safari 的 console 是否提供 `copy()` 尚未確認；若沒有，CLI 改印出以 `navigator.clipboard.writeText` 寫入的版本。這一點在實測 task 中確認。

### 桌面版匯入：先實測再實作

`slack-all auth import --from-desktop` 讀 Slack 桌面 app 的本機資料：依序尋找 App Store 版路徑與官網下載版路徑（`~/Library/Application Support/Slack`）。

- cookie `d`：從 `Cookies`（SQLite）讀 `host_key` 為 `.slack.com`、`name` 為 `d` 的列，以 Chromium 在 macOS 的方式解密：Keychain 項目 `Slack Safe Storage` 的密碼經 PBKDF2-HMAC-SHA1（salt `saltysalt`、1003 次）得到 16 bytes 金鑰，AES-128-CBC、IV 為 16 個空白，去掉 `v10` 前綴；新版 Chromium 會在明文前加 32 bytes 的 host 雜湊，要一併處理。
- token：從 `Local Storage/leveldb` 找出 `localConfig_v2` 的值。

這兩個格式都是 Slack 與 Chromium 的私有格式，有三個未知數：LevelDB 檔案是否經過 Snappy 壓縮、新版 Chromium 的明文前綴、讀別的 app 的沙盒資料夾時 macOS 會跳哪些授權。所以 tasks 的第一組是**唯讀實測**，在使用者的 Mac 上確認讀得到、解得開，全程不印出任何值。實測結論寫回本 design 的 Open Questions；若結論是做不到，`--from-desktop` 改開後續 issue，剪貼簿匯入照常完成。

讀 `Slack Safe Storage` 時，macOS 會詢問是否允許 `security` 存取。CLI 要提示使用者按「允許」，**不要按「永遠允許」**：後者會把 `/usr/bin/security` 加進 Slack 這個項目的 ACL，之後任何程式都能透過 `security` 讀出它。

### 一個 process 管多個 workspace

一個 MCP server process 服務所有已匯入的 workspace。所有 Slack 工具都接受選填的 `workspace` 參數，值可以是 team id（例如 `T0123ABCD`）或 domain（例如 `myteam`，即 `myteam.slack.com`），比對不分大小寫、必須完全相符：

- 只匯入一個 workspace 時，可以省略。
- 匯入兩個以上卻省略、或值不符任何 workspace 時，回傳 `isError: true`，訊息列出所有可用的 team id 與 domain，不自動挑一個。

替代方案：korotovsky 的一個 workspace 一個 process。使用者要「都能連」，workspace 一多，每個都要在 MCP 設定裡各加一條，因此不採用。

### send_message 不列入免確認清單

`send_message` 預設可用，與 telegram-all 一致。plugin README 的免確認表照 Telegram 的寫法把它排除，並寫明：Manual（`default`）與 `acceptEdits` 模式下每次送出都會詢問；auto 模式由分類器審核、通常不詢問；要每次都被問，就加 ask 規則 `mcp__plugin_che-slack-mcp_slack__send_message`。

替代方案：像 korotovsky 以環境變數預設關閉送訊息。使用者要求「全部都要」，而 Claude Code 的權限機制已經提供逐次確認，因此不再另設開關。

### 歸檔格式對齊 telegram-chat-archive

`archive_conversation_to_markdown` 沿用 `telegram-chat-archive` 的每日檔案格式：

- 路徑：`<output_dir>/<team_id>/<conversation_id>/<YYYY-MM-DD>.md`，日期是訊息在 `utc_offset` 下的本地日期。
- 檔頭：YAML frontmatter，含 `team_id`、`conversation_id`、`date`、`utc_offset`。
- 每則訊息：`<!-- msg:<ts> -->`、`**<HH:mm> <sender>**：`、內容、空行。`<ts>` 是 Slack 的訊息 timestamp（例如 `1730000000.123456`）。
- 寄件者：自己的訊息寫 `我`（以 `auth.test` 的 user id 判斷），能解析時寫顯示名稱，否則寫 `User <user_id>`；bot 訊息寫 `Bot <bot_id>`。
- 內容：Slack 標記轉成 markdown，`<@U123>` 轉成 `@<顯示名稱>`、`<#C123|general>` 轉成 `#general`、`<https://x|標籤>` 轉成 `[標籤](https://x)`。行首跳脫規則與 Telegram 相同。
- 權限：目錄 0700、檔案 0600。
- 書籤：`after_ts`，對應 Telegram 的 `after_message_id`。
- 沿用：可重跑不重複（以 `ts` 合併）、不含內容的 manifest（`manifest.json`）、同一 conversation 同一輸出目錄不得同時歸檔、被限流時保留已抓到的部分。

### thread 回覆以回顧窗口補抓

`conversations.history` 只回傳主訊息，回覆要以 `conversations.replies` 另抓；Slack 也沒有「哪些舊 thread 有新回覆」的 API。所以：

- 回覆寫在它自己日期的檔案裡，標頭寫成 `**<HH:mm> <sender>** ↳ thread:<parent_ts>：`，主訊息的區塊不變。
- 每次歸檔時，對 `ts` 落在最近 `thread_lookback_days` 天內（預設 30，範圍 0 到 365）、且 `latest_reply` 比 manifest 紀錄更新的主訊息，重新抓回覆。

抓回覆時，若 manifest 已記錄該 thread 的回覆 `ts`，就以它為 `oldest` 從那之後接著抓，超過單次頁數上限的長 thread 會在後續呼叫補齊（review 發現原本每次都從第一則重讀）。被頁數上限截斷的 thread 不論主訊息多舊都保留回覆書籤，直到抓完；在那之前回報 `complete: false`（第二次 review 發現窗口外的長 thread 會在第 1000 則停住）。限流中斷的那一次也要記下這次才截斷的 thread（第三次 review 發現它會被丟掉，接續點又在主訊息下面，剩下的回覆永遠抓不到）。回顧窗口只用來查舊 thread 有沒有新回覆，不影響 `complete`：新訊息都寫完、沒有截斷的 thread 就回報 `complete: true`，窗口沒列完另外回報 `lookback_complete: false` 並建議調小 `thread_lookback_days`（第三次 review 發現很忙的頻道窗口超過每次 50 頁，`complete` 永遠是 false；使用者選擇不另記窗口的接續點）。

30 天是選定的預設值，**沒有量測依據**。更早的 thread 若有遲到的回覆，不會被補抓，這是第一版刻意接受的漏洞；使用者可以用更大的 `thread_lookback_days` 重跑一次補齊。

### 第一版不下載檔案

訊息附帶的 Slack 檔案只寫成 `[file: <name>](<permalink>)`，不下載到本機。下載 `url_private` 需要帶憑證，又會讓歸檔更接近 API Terms 說的「bulk export」；等使用者實際需要時再另開 issue。

### 獨立的 che-slack-mcp plugin

新增 `plugins/che-slack-mcp/`，不併入 `che-telegram-mcp`：使用者可能只用其中一個平台，而 plugin 的 SessionStart hook 與 wrapper 都會在每次啟動時執行。wrapper 沿用 Telegram 的作法，以 `DESIRED_VERSION` pin 本 repo 的 release 並下載 binary，但**不 export 任何憑證**（binary 自己讀 Keychain）。

## Implementation Contract

**使用者看到的行為**

- `slack-all auth import`：兩次複製、兩次 Enter，印出每個 workspace 的名稱與驗證結果，不印出任何憑證，結束時剪貼簿已清空。
- `slack-all auth import --from-desktop`：macOS 跳出授權視窗；成功後印出與上面相同格式的結果。
- `slack-all auth status`：列出已匯入的 workspace 與各自 `auth.test` 的結果。
- `slack-all auth remove <workspace>`：刪除該 workspace 的 token 與 cookie 兩個 Keychain 項目，並把它從索引移除。
- MCP 工具：`list_workspaces`、`auth_status`、`list_conversations`、`get_conversation_history`、`get_thread_replies`、`search_messages`、`get_user`、`send_message`、`archive_conversation_to_markdown`。

**介面與資料形狀**

- Keychain：account `che-slack-mcp`，service `SLACK_WORKSPACES`、`SLACK_TOKEN_<TEAM_ID>`、`SLACK_COOKIE_<TEAM_ID>`。
- 歸檔檔案格式與 manifest 見 `slack-chat-archive` spec。
- 錯誤：MCP 工具一律回傳 `isError: true` 的工具結果，訊息依五類錯誤的文字；CLI 以非零 exit code 結束。
- 參數上限與來源：`send_message` 的 `text` 上限 40000 字元，取自 Slack 文件「Slack will truncate messages containing more than 40,000 characters」，超過時改為報錯而不讓 Slack 截斷；`search_messages` 的 `count` 預設 20、上限 100，與 Slack 文件相同；`get_conversation_history` 的 `limit` 上限 200 取自 Slack 文件「We recommend no more than 200 results at a time」，預設 50 是自選值；Keychain 讀取逾時 10 秒是自選值，沒有量測依據。
- 頁數上限（自選值，沒有量測依據）：`list_conversations` 每頁 200、最多 10 頁；thread 回覆每頁 200、最多 5 頁；歸檔的主訊息每頁 200、最多 50 頁，碰到上限時回 `complete: false`、不推進書籤，並在 manifest 記下接續點，下一次從那裡往舊的方向接著抓；`list_conversations` 解析 DM 名稱每次呼叫最多查 50 位使用者。

**失敗模式**

- session 失效、Enterprise Grid 限制：明確告知，不自動重試。
- 被限流：自動等待重試，超過上限才回報；歸檔保留已抓到的部分，但書籤不推進。Slack 從新到舊列訊息，中斷時已寫入的是最新的一段，若把書籤設成它，較舊、還沒抓到的訊息會被永久跳過（apply 時發現，使用者 2026-10-29 選定此解法，與 Telegram 的 `bookmark_safe` 一致）。manifest 記下這一段的起點與已寫到的最舊 `ts`，下一次從那裡接著往舊的方向抓，走到下界才推進書籤（review 發現「重跑重抓」在範圍超過每次 50 頁的上限時永遠停在同一處，使用者 2026-10-30 改選記下接續點）。
- 帶 `after_ts`／`since_date` 時，起點晚於書籤則書籤不動；明確範圍沒走完也記下接續點與它的下界，用同樣的參數重跑就接著抓（第二次 review 發現起點晚於書籤時，書籤會跳過中間沒讀的訊息）。接續紀錄同時記下這個範圍已寫到的最新一則：走到下界的那次回報 `complete: false`，下一次只補比那一則新的訊息、追上後刪掉紀錄並回報 `complete: true`。否則呼叫端照說明「重跑到 complete 為 true」時，每次都會從頭讀起、在同一個頁數上限停住，永遠收不了尾。
- HTTP 傳輸不用 `URLSession.shared`：它會把 Slack 回應裡的 `Set-Cookie` 存到 `~/Library/HTTPStorages/<執行檔名>.binarycookies`（權限 0644），並附到之後所有 workspace 的請求上。改用 ephemeral session，不存 cookie、不用快取，每個請求只帶自己 workspace 的 `d`（第四次 review 發現實測後磁碟上留了一個 `xoxd-` 開頭、2027 年才到期的 `uc` cookie）。
- 再次歸檔保留既有區塊、不就地取代，與 telegram-chat-archive 一致：歸檔是長期紀錄，訊息被編輯或發言者改名後，歸檔仍保留第一次寫下的版本（2026-10-31 驗證後由使用者決定；原本的「以 ts 就地取代」會在重讀時覆寫原文）。回顧窗口只補已歸檔主訊息的回覆，避免寫出主訊息不在歸檔裡的孤兒回覆。
- `send_message` 遇到網路錯誤、非預期回應、非 200，以及 Slack 的 `internal_error`、`fatal_error` 時，結果說明訊息可能已送出、請先確認再重送（Slack 文件說這兩個錯誤可能已部分完成）。
- 正式 transport 不跟隨 redirect，避免手寫的 `Cookie` 與表單裡的 token 被帶到別的 URL。
- 憑證以 `security` 寫入，所以同一使用者下的任何程式都能透過 `/usr/bin/security` 免提示讀出（與 Telegram 一致的取捨）；README 的風險段照實寫出這一點。
- `slack-all` 暫時只能從原始碼 build，不隨 release 發佈（2026-10-31 使用者決定；發 binary 需要簽章、公證與 Gatekeeper 的處理，追蹤於 #112）。
- 任何錯誤訊息、日誌、工具結果都不含 token 或 cookie 的值。

**驗收**

- `cd che-slack-mcp && swift build -c release` 成功，`swift test --skip E2ETests` 全部通過。
- 新套件的測試用 Swift Testing（`import Testing`，可直接用參數化測試對應 spec 的範例表）；兩個 Telegram 套件維持 XCTest。因此 che-slack-mcp 需要 Swift 6 toolchain。
- 測試以假的傳輸層驗證五類錯誤分類、請求標頭、重試與間隔；以暫存 keychain 檔案驗證 Keychain 讀寫（比照 Telegram 測試用 scratch keychain）。
- `bash tests/che-slack-mcp/*.sh` 通過，`claude plugin validate plugins/che-slack-mcp` 通過，`tests/lib/install_refs.py` 的檢查不回報新 plugin。
- 手動：在使用者自己的 workspace 跑一次桌面版匯入、`list_workspaces`、`get_conversation_history`、`archive_conversation_to_markdown`，結果記在 #99。（剪貼簿匯入：使用者只用 Slack 桌面版，無法真機驗證，見 #103）

**範圍**

- 範圍內：`che-slack-mcp/` 套件、`plugins/che-slack-mcp/`、`tests/che-slack-mcp/`、`.claude-plugin/marketplace.json` 的新條目、`README.md` 與 `CLAUDE.md` 的相關段落、`openspec/LANGUAGE.md`。
- 範圍外：兩個 Telegram server 與 `che-archive-lines` 的程式碼、GitHub release 的發布、Non-Goals 列出的功能。

## Risks / Trade-offs

- [帳號被登出或通知管理員] Enterprise Grid 與 Slack 的異常偵測可能作廢 session、甚至通知管理員（korotovsky #62、#86、#105；slackdump README）→ 預設請求間隔與並行上限、可覆寫；Enterprise Grid 錯誤明確警告；README 寫明風險。
- [條款] 歸檔碰到 Slack API Terms 的「archive」字眼，條文對象是否涵蓋個人使用不明確 → 第一版不下載檔案、manifest 不含內容、README 寫明由使用者自行判斷；使用者已在 #99 知情接受。
- [憑證外流] session token 等同登入狀態 → 只存 Keychain、不經 argv、環境變數、MCP 參數或對話；所有輸出以 `<redacted>` 取代值；寫入前驗證字元集。
- [私有格式改變] 桌面 app 的 LevelDB 與 Chromium cookie 格式可能改變 → `--from-desktop` 失敗時明確說明並引導改用剪貼簿匯入；兩條匯入路徑互不依賴。
- [遲到的 thread 回覆] 超過回顧窗口的 thread 新回覆不會被補抓 → 可調 `thread_lookback_days` 重跑補齊。
- [並行與間隔的預設值未量測] → 環境變數可覆寫；實際被登出時優先調整。

## Migration Plan

全新的 server 與 plugin，不影響既有使用者。發布順序：本 change 完成並驗證後，另外經使用者確認才發 GitHub release、bump wrapper 的 `DESIRED_VERSION` 與 plugin 版號。回滾：從 marketplace 移除 `che-slack-mcp` 條目即可，Keychain 資料以 `slack-all auth remove` 清除。

## Open Questions

task 1.1 的唯讀實測已在 2026-10-29 於使用者的 Mac（macOS 27.2、Mac App Store 版 Slack）完成。實測只記錄長度、前綴與成功與否，複製出來的 Slack 資料在實測後立即刪除。

- **`security -i` 從 stdin 寫入：可行。** 對暫存 keychain 檔案寫入含 `% + / = - _ .` 的假值，`security -i` 等待輸入時 `ps` 顯示的 argv 只有 `security -i`；以 `find-generic-password -g` 讀回與寫入值完全相同；keychain 搜尋清單前後不變。
- **Safari console 的 `copy()`：有。** WebKit 的 `Source/WebCore/inspector/CommandLineAPIModuleSource.js` 定義了 `CommandLineAPI.methods["copy"]`，所以剪貼簿匯入的 console 指令用 `copy()`，不需要 `navigator.clipboard.writeText` 的版本。
- **LevelDB：有 Snappy 壓縮。** `Local Storage/leveldb` 的兩個 `.ldb` 表格檔裡，index block 與 14 個 data block 全部是 Snappy 壓縮。`localConfig_v2` 的 key 是 `_https://app.slack.com` 加分隔字元再加 `localConfig_v2`，留有 4 個版本，要取 sequence 最大的一筆；值的第一個 byte 是編碼（1 為 Latin-1，0 為 UTF-16LE），實測是 1。最新值的 `teams` 裡每個 workspace 都有 `id`、`domain`、`name`、`token`、`user_id`，token 以 `xoxc-` 開頭（實測 114 字元）。這次 `.log` 裡沒有 `localConfig_v2`，但 `.log` 是尚未寫入表格的新資料，實作仍要讀 `.log` 才不會漏掉最新版本。因此 task 3.4 需要以 Swift 自行實作 Snappy 解壓（實測用的 Python 版約 20 行）、LevelDB 表格讀取與 `.log` 讀取，不引入第三方套件。
- **Chromium cookie 明文前綴：有。** `Cookies` 的 `meta` 表 `version` 與 `last_compatible_version` 都是 24；cookie `d` 那一列 host 為 `.slack.com`，`value` 欄為空，`encrypted_value` 共 291 bytes，以 `v10` 開頭。以 `Slack Safe Storage` 密碼經 PBKDF2-HMAC-SHA1（salt `saltysalt`、1003 次）得到金鑰、AES-128-CBC（IV 為 16 個空白）解密後得到 277 bytes，前 32 bytes 等於 `SHA256(".slack.com")`，去掉後是以 `xoxd-` 開頭、245 字元、全為可見 ASCII 的 cookie。實作要在 `meta.version` 大於等於 24 時去掉這 32 bytes。
- **macOS 授權：只有 Keychain 一次。** 從沙盒資料夾複製 `Cookies` 與 `Local Storage/leveldb` 時沒有跳出存取其他 app 資料的授權；讀 `Slack Safe Storage` 時跳出一次 Keychain 授權，使用者按「允許」後成功。
- **範圍提醒：** 桌面 app 只登入了 1 個 workspace，`--from-desktop` 只拿得到桌面 app 登入過的 workspace；其他 workspace 要先在桌面 app 登入，或改用剪貼簿匯入。這點要寫進 plugin README（task 6.1）。
- **未逐字元核對：** cookie `d` 是否只含寫入前檢查允許的字元（`A-Z a-z 0-9 - _ . % + / =`）沒有在實測中逐字元比對（避免再跳一次 Keychain 授權）；執行時由 Keychain write keeps values off argv 的寫入前檢查把關，不合法時會拒絕並點名 service。

## 驗證後的 follow-up（2026-10-31）

六方驗證中不擋合併的項目另開 issue：#104（單次歸檔的請求預算）、#105（`get_thread_replies` 的 `oldest`／`limit`）、#107（wrapper 的同時安裝與完整性檢查，含 Telegram）、#108（排隊請求的取消、`Retry-After` 上限）、#109（匯入的身分以 `auth.test` 為準、token 與 cookie 不留半套）、#110（夏令時間）、#111（歸檔位置與不受信任文字的標示）、#112（`slack-all` 的發佈）。
