## Why

使用者要讓 Claude 以本人身分連上自己所在的任何 Slack workspace（包含別人管理、不一定核准 app 或 MCP 整合的 workspace），能讀、搜尋、送訊息，並把對話歸檔成本機 markdown（PsychQuant/che-msg#99）。Slack 官方 MCP 與自建 Slack app 都要 workspace 管理員核准，只有瀏覽器 session token（`xoxc` token 加 cookie `d`）同時滿足「本人身分」與「任何 workspace」；現有使用這種 token 的工具不是只支援 Chromium、就是一個 workspace 一個 process、或沒有歸檔，Swift 也沒有還在維護的 Slack client（調查見 #99 Diagnosis）。

## What Changes

- 新增 Swift package `che-slack-mcp/`，比照 `che-telegram-bot-mcp/` 拆成 `SlackWebLib`（只依賴 Foundation 的 Slack Web API client）、`CheSlackMCPCore`、`CheSlackMCP`（MCP server 入口）、`SlackAllCore`（CLI 的匯入邏輯，與 AppKit 分開以便測試）、`slack-all`（CLI）五個 target。
- `SlackWebLib` 以 session token 呼叫 Slack Web API，把錯誤分成「session 失效」「被限流」「Enterprise Grid 限制」「其他 Slack 錯誤」「網路錯誤」五類，並預設在請求之間保持最小間隔、限制並行數。
- 憑證存 macOS Keychain：每個 workspace 一組 token 與 cookie，加一個記錄已匯入 workspace 的索引項目；binary 自己讀 Keychain，wrapper 不 export 成環境變數。
- CLI 提供兩種匯入方式，token 都只經過 CLI，不經過 MCP 工具參數：
  - `slack-all auth import`：從剪貼簿讀使用者在瀏覽器 console 複製的 workspace 清單與 cookie `d`。
  - `slack-all auth import --from-desktop`：從 Mac App Store 版 Slack 桌面 app 的本機資料讀出所有已登入 workspace 的憑證。
- MCP 工具（一個 process 管多個 workspace，工具帶 `workspace` 參數）：`list_workspaces`、`auth_status`、`list_conversations`、`get_conversation_history`、`get_thread_replies`、`search_messages`、`get_user`、`send_message`、`archive_conversation_to_markdown`。
- `archive_conversation_to_markdown` 的每日 markdown 格式對齊 `telegram-chat-archive`，路徑為 `<output_dir>/<team_id>/<conversation_id>/<YYYY-MM-DD>.md`，以訊息的 `ts` 當錨點與書籤。
- 新增 Claude Code plugin `plugins/che-slack-mcp/`（wrapper 從本 repo 的 GitHub release 下載 binary）並登記到 `.claude-plugin/marketplace.json`；`send_message` 不列入 plugin README 的免確認清單。
- 新增 `openspec/LANGUAGE.md`，記下 workspace、conversation、session token 三個用詞。

## Capabilities

### New Capabilities

- `slack-web-client`: 以 session token 呼叫 Slack Web API 的 client，涵蓋認證標頭、錯誤分類、限流重試與預設的請求間隔。
- `slack-credentials`: 每個 workspace 的 session 憑證如何存進、讀出 Keychain，以及兩種匯入方式（剪貼簿、Slack 桌面 app）。
- `slack-mcp-tools`: MCP server 對外提供的讀、搜尋、送訊息與 workspace 工具，以及多 workspace 的選擇規則。
- `slack-chat-archive`: 把 Slack conversation 歸檔成每日 markdown 的工具，含 thread 回覆與增量更新的規則。

### Modified Capabilities

（無）

## Impact

- 新增：che-slack-mcp/（Package.swift、Sources/SlackWebLib、Sources/CheSlackMCPCore、Sources/CheSlackMCP、Sources/slack-all、Tests）、plugins/che-slack-mcp/、tests/che-slack-mcp/、openspec/LANGUAGE.md。
- 修改：.claude-plugin/marketplace.json（新增一個 plugin 條目）、README.md（伺服器表與待辦清單）、CLAUDE.md（結構表與開發指令）。
- 不修改：che-telegram-bot-mcp/、che-telegram-all-mcp/、plugins/che-telegram-mcp/、plugins/che-archive-lines/ 的程式碼。
- 外部依賴：Swift MCP SDK（與 Telegram server 同版本）、swift-argument-parser；不引入 Slack 或 LevelDB 的第三方 Swift 套件。
- 使用風險：session token 等同登入狀態；Enterprise Grid 可能偵測到自動化而登出、並通知管理員；歸檔碰到 Slack API Terms 的「archive」字眼。使用者已在 #99 知情接受。
