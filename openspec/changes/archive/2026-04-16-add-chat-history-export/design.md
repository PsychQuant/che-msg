## Context

`che-telegram-all-mcp` 透過 TDLib 提供 Telegram 個人帳號 MCP tools。既有 `get_chat_history` MCP tool 與 library method `TDLibClient.getChatHistory(chatId:limit:fromMessageId:)` 是 TDLib `getChatHistory` 的 thin wrapper：單次呼叫、回傳 JSON array of raw messages、欄位為 TDLib 原始 schema。

TDLib 本身的限制：
- `getChatHistory` 單次呼叫最多回 100 筆訊息
- 只吃 `fromMessageId` + `limit`，沒有 date range 參數
- 需要透過 `fromMessageId` chain 才能翻頁到更早訊息
- Rate limit 存在（多次快速呼叫可能被 throttle）

現況：MCP server 已註冊約 20+ tools（`Server.swift` 的 `defineTools()`），CLI `telegram-all history` 直接呼叫 library 方法 print JSON。`openspec/specs/` 目前為空（前一個 change `refactor-telegram-all-mcp` 已 archive 但未留下正式 capability spec）。

Stakeholders：
- GitHub Issue #1 `feat(all-mcp): 支援一次抓取完整對話歷史（自動分頁）`
- GitHub Issue #2 `feat(all-mcp): 新增 dump 對話為 Markdown 的 tool`（depends on #1）
- 使用者實際 use case：備份 / 歸檔對話、對話引用進學術文件、純文字版供後續語意搜尋

## Goals / Non-Goals

**Goals:**

- 一次 MCP tool call 即可取得完整對話歷史並匯出為可讀 Markdown 檔
- Library 層維持單一 function 契約，單頁與全量走同一個 method 以降低 maintenance cost
- MCP 層每個 tool 語意單一（thin peek vs heavy dump），tool description 不需多義句解釋
- 既有 `get_chat_history` MCP tool 與 `TDLibClient.getChatHistory` 原始呼叫點 100% 向後相容
- CLI `telegram-all history` 與 MCP dump tool 共用 library 實作，無程式碼重複
- 日期過濾語意一致：`sinceDate` / `untilDate` 永遠在 client-side 生效，與 `maxMessages` 獨立（不綁定）

**Non-Goals:**

- **不**暴露 `get_chat_history_full` 為 MCP tool — 中間層（整批 JSON 回到 MCP response）實務上 AI 總會再轉 markdown，token 成本高且無獨立使用情境
- **不**在 MCP tool `get_chat_history` 增加 flag（`auto_paginate` / `max_messages` / `since_date` / `until_date`）— 違反「tool 語意單一」原則，AI 讀 tool description 判斷成本高
- **不**使用 TDLib `searchChatMessages` 等其他 API — 語意與 `getChatHistory` 不同，混用會讓 library 契約混亂
- **不**支援 markdown → JSON 的反向轉換或 markdown 匯入 Telegram
- **不**在 MVP 支援 FormattedText entities（bold / italic / link / code）的 markdown 保留 — 純文字優先
- **不**支援 sticker、voice、video note、location 等 media 的實際下載 — 只產 `[sticker]`、`[voice]` 等 placeholder
- **不**追加新的外部依賴（沿用 TDLibKit、MCP SDK、ArgumentParser、Foundation）
- **不**改動 `che-telegram-bot-mcp`（Bot API 範疇不同）

## Decisions

### 砍掉中間層 `get_chat_history_full` MCP tool

**決定**：MCP 層只暴露兩個 tool：`get_chat_history`（既有 thin wrapper 保留）與 `dump_chat_to_markdown`（新增）。

**理由**：
- 分析實際使用情境，AI 拿到整批 JSON 後永遠會轉可讀格式 → JSON 中間層只是多一次 token 浪費
- MCP tool 數量越少，AI agent decision cost 越低（每個 tool schema 都在 context 裡）
- Library 層（非 MCP 層）仍可透過擴充 `getChatHistory` 提供「整批 JSON」能力給 CLI 或其他內部呼叫者

**替代方案**：
- **A. 暴露三層（`get_chat_history` + `get_chat_history_full` + `dump_chat_to_markdown`）**：駁回。Layer 2 無獨立使用情境，屬 over-engineering
- **B. 合併成單一 tool 加 flag**：駁回。見下一決策

### 既有 `get_chat_history` MCP tool 維持 thin wrapper 不加 flag

**決定**：MCP 層 `get_chat_history` tool schema 保持三參數 `chat_id` / `limit` / `from_message_id`。自動分頁、日期過濾能力不在此 tool expose。

**理由**：
- Peek（< 1s、≤100 筆）與 dump（10s+、可能 10k+ 筆）行為特性差距大，AI 需要從 tool name 直接判斷「這個 call 多重」
- 加 flag 會讓 tool description 成為多義句（「若 auto_paginate=true 則…否則…」），增加 AI 讀 schema 成本
- 參數組合產生 invalid state（`auto_paginate=false` + `since_date` 語意不清），容易被 AI 誤用

**替代方案**：
- **在 `get_chat_history` 加 `auto_paginate: bool` + `max_messages` 等 flag**：駁回。違反「tool 語意單一」

### Library 層單一 function 承擔兩種語意

**決定**：擴充既有 `TDLibClient.getChatHistory(chatId:limit:fromMessageId:)` signature，新增三個 optional 參數：

```swift
public func getChatHistory(
    chatId: Int64,
    limit: Int = 50,
    fromMessageId: Int64 = 0,
    maxMessages: Int? = nil,
    sinceDate: Date? = nil,
    untilDate: Date? = nil
) async throws -> String
```

內部行為：
- `maxMessages == nil` → 單次 TDLib 呼叫，行為完全等同既有實作（向後相容）
- `maxMessages != nil` → 進入自動分頁迴圈，直到達 `maxMessages` 或 early-terminate
- `sinceDate` / `untilDate` 永遠在 Swift client-side 過濾（獨立於 `maxMessages`），單頁 + 過濾組合合法

**理由**：
- 符合使用者「不想 maintain 兩個 function」的偏好
- Swift optional parameter + internal if/else 分岔是慣用 pattern，不算語意混亂
- MCP 層靠 expose 參數子集達成「tool 語意單一」，library 層不必拆兩個 public method
- 既有 call site（`Server.swift:333`、`TelegramAllCLI.swift:105`）無需修改

**替代方案**：
- **新增獨立 `getChatHistoryFull()` method**：駁回。Library surface 變大、兩個 method 內部仍會共用大部分 helper（如 sender cache、過濾），拆分成本 > 收益

### 分頁方向 newest → oldest + early-terminate

**決定**：自動分頁從最新訊息往回抓（TDLib `getChatHistory` 的天然方向）。每批檢查訊息 `date`：
- 若最舊一筆 `date < sinceDate` → 截斷該批 + 停止分頁
- 若累積筆數達 `maxMessages` → 停止分頁
- 若該批空陣列 → 已到對話起點，停止分頁

**理由**：
- TDLib `getChatHistory(fromMessageId: 0)` 預設就是從 newest 開始，延用最自然
- 實際使用者通常想要「最近一段時間」而非「最早對話」，newest-first 符合直覺
- Early-terminate 避免多抓 → 丟棄的 rate limit 浪費

**替代方案**：
- **先抓全部再過濾**：駁回。10k+ 訊息對話會觸發 rate limit 且記憶體壓力大
- **先 binary search 找 `sinceDate` 對應 messageId 再往後抓**：駁回。TDLib 沒提供 date → messageId 的 API，實作成本高且收益有限

### Markdown dump 必填 `output_path`，回 summary metadata

**決定**：`dump_chat_to_markdown` MCP tool schema 將 `output_path` 設為 required。執行成功後回傳：

```jsonc
{
  "path": "/tmp/pei-chun-chat.md",
  "message_count": 327,
  "date_range": { "since": "2026-03-01", "until": "2026-04-15" },
  "senders": [{ "user_id": 12345, "display_name": "培鈞" }, ...],
  "truncated": false
}
```

**理由**：
- 完整 markdown 可能數十 KB ~ MB，塞回 MCP response 會爆 context 或超過 MCP message size 上限
- Summary metadata 讓 AI 能後續決定「要不要讀檔某段」、「要不要追加抓更早」
- 寫檔路徑明確，使用者可直接開啟檔案或 pipe 給其他工具

**替代方案**：
- **選配 `output_path`，預設回完整 markdown**：駁回。預設行為對大對話會出事
- **加 `return_content: bool` 讓使用者選**：暫緩。如有需求可後續加 flag，MVP 不加

### Sender name 批次 resolve + cache

**決定**：`dump_chat_to_markdown` 執行流程：
1. 先抓完所有訊息（呼叫 library `getChatHistory(maxMessages:sinceDate:untilDate:)`）
2. 掃一次訊息蒐集 unique `sender.user_id` set
3. 對每個 unique id 呼叫一次 TDLib `getUser` 並 cache 結果
4. 第二次掃訊息時用 cache 做 sender name resolve

若 `getUser` 失敗（封鎖、刪號、privacy）：fallback 為 `User {id}`（使用 id 當後備標識）。

**理由**：
- 1-1 chat 通常只有 2 個 sender，group 通常 < 50 人，即使 10k 訊息也只需少量 `getUser` call
- 逐筆 resolve 會 O(N) call，對 10k+ 訊息對話不可接受
- Fallback `User {id}` 確保格式化永遠成功，不因單一使用者資料查不到而整個 dump 失敗

**替代方案**：
- **逐筆 resolve**：駁回。N=10000 時 10000 次 TDLib call
- **不 resolve，直接印 user_id**：駁回。輸出可讀性極差，失去 dump 到 markdown 的意義

### Self 訊息用可覆寫的 label 區分

**決定**：訊息來源為自己（`is_outgoing == true`）時，sender 欄位使用 `self_label` 值。MCP tool schema 新增 optional `self_label: string` 參數，預設 `"我"`。CLI 透過 `--self-label <string>` flag 控制。

**理由**：
- Issue #2 example 用「我」，符合繁體中文直覺
- 使用者若想在匯出裡用真名（例如拿去做 LLM training data），透過 param override 即可

**替代方案**：
- **硬編碼「我」**：駁回。多語境彈性不足
- **預設用 `get_me` 回傳的 `first_name`**：駁回。多增一次 TDLib call、且「我」更符合對話紀錄語氣

## Risks / Trade-offs

- **TDLib rate limit 觸發** → 分頁迴圈中若連續呼叫過快可能被 throttle。Mitigation：每批之間保留最小 delay（例如 50ms），並在 `flood_wait` 錯誤時等待 TDLib 指定時間後重試（最多 N 次）。
- **超長對話記憶體壓力** → 10k+ 訊息在記憶體裡保存所有 message dict 可能吃掉數百 MB。Mitigation：MVP 設定 `maxMessages` 預設 5000（見 Open Questions）；未來可評估 streaming write（邊抓邊寫檔）。
- **Secret chat 抓不到歷史** → TDLib 限制，secret chat 的歷史訊息只在裝置本機，其他裝置無法拉取。Mitigation：偵測到 chat type 為 `chatTypeSecret` 時於 response 加 `warning` 欄位說明，不中止流程（仍 dump 能拿到的部分）。
- **Sender `getUser` 在 group 裡失敗** → 已退群/封鎖的成員可能 resolve 失敗。Mitigation：fallback `User {id}` 格式，不 throw。
- **Markdown 輸出路徑權限問題** → `output_path` 父目錄不存在或無寫入權限。Mitigation：寫檔前先 `FileManager` 檢查，失敗時 throw 明確錯誤 `outputPathNotWritable(path:)` 而非 generic IO error。
- **日期 parse 歧義** → `since_date` / `until_date` 傳入格式若不嚴格定義容易錯。Mitigation：MCP tool description 明確要求 `YYYY-MM-DD`（解釋為使用者 local timezone 的該日 00:00:00 ~ 23:59:59）；其他格式 throw `invalidDateFormat`。
- **Library signature 擴充破壞呼叫者** → Swift optional 參數預設值屬於 source-compatible change，既有 caller 不需改。Mitigation：補 unit test 覆蓋「既有三參數 call site」行為不變。

## Open Questions

以下在 specs 與 tasks 階段確認，或在 apply 過程由 implementer 做合理預設（可後續調整）：

1. **`maxMessages` 預設值** — 候選 5000 / 10000 / 無上限。本 design 預設採 **5000**（平衡記憶體與實用性），MCP tool schema 明確標注「若要更多需顯式設定」。
2. **FormattedText entities 是否保留** — MVP 決定：**丟棄**（只取 `text` 純文字）。保留 bold / italic / link 的 markdown 轉換延後到 follow-up change。
3. **連續同人訊息是否合併** — MVP 決定：**不合併**。每筆訊息一行帶完整時間戳，保留時序精度（對「查某時刻在聊什麼」更有用）。
4. **超長單則訊息（> 300 字）是否截斷** — MVP 決定：**不截斷**（保留完整內容）。Issue #2 example 的 `…（超過 300 字省略）` 行為延後為後續 flag。
5. **Markdown 日期分組粒度** — MVP 採**按日分組**（`## 2026-04-14`），訊息時間顯示 `HH:mm`。
