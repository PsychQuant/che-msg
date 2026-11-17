## Why

`archive_chat_to_markdown`（#69）在另一個程序持有 TDLib 時從 TDLib 的本機快取寫日檔。這些區塊缺少本機讀取器給不出的東西：寄件人名稱（寫成 `User <id>`）、說明文字、投票／貼圖／位置的細節（#82），而且音訊讀成 `[other]`、沒有 `media/<id>/` 連結。之後透過 TDLib 再跑同一段範圍時，合併規則把已存在的區塊原樣保留，所以這些區塊永遠不會變好；只會補上缺的訊息與媒體檔（PsychQuant/che-msg#72）。#69 的保守做法是讓 skill 在 TDLib 被占用時停下來、文件寫明不會改寫；本 change 是完整的修法。

## What Changes

- 從本機快取寫入的區塊，在不變的錨點行之後多一行標記，內容恰為 `<!-- provisional: local-cache -->`，之後才是 `**HH:mm sender**：` 標頭與內文。錨點的格式不變，所以 v0.8.0 的解析器、skill 的結尾核對與 #80 的搜尋都照舊從錨點切區塊。
- 來源是 TDLib 的呼叫遇到帶標記的區塊時，用這則訊息現在的寫法換掉整個區塊（升級，沒有標記）。來源是本機快取的呼叫不換任何區塊（不會降級），沒有標記的區塊一律原樣保留。
- manifest 新增 `upgraded_messages`：這次換掉的帶標記區塊數，不算進 `new_messages` 與 `media_messages`。`files` 改為「這次加了訊息或升級了區塊的日檔」，讓 skill 的結尾核對也檢查被升級的日檔。
- 「同樣參數重跑、沒有新訊息時檔案位元組不變」的保證仍成立：沒有帶標記的區塊剩下時（或來源是本機快取時）不寫任何檔。
- 工具說明、README 與 `/archive-telegram` 改寫：快取寫入的區塊是暫時的，之後透過 TDLib 跑同一段範圍會換成完整版本；報告寫出升級了幾則；`last_run` 記 `upgraded_messages`。skill 遇到 `tdlib_in_use` 仍預設停下（沒有下載媒體），理由改寫。

## Non-Goals

- 不加 `refresh` 參數（#72 Open question 2 的預設）：書籤以下的區塊要升級時，用較舊的 `after_message_id` 重跑即可，升級規則一樣適用。
- 不移除工具的本機快取路徑（Open question 1 的另一個選項）。
- v0.8.0 從本機快取寫的區塊沒有標記，不會被升級；不從文字猜測哪些區塊是快取寫的（Diagnosis 第 4 點 (a)：真的顯示名稱也可能長得像 `User <id>`）。
- 不反映訊息的編輯或刪除（歸檔照舊只增不改）；升級時寫的是 TDLib 當下的訊息。
- 不改本機快取的解碼能力。

## Defaults chosen while the maintainer was away

#72 的 Diagnosis 留了兩個 Open questions；維護者不在，以下照 Diagnosis 的建議或預設選項，並記在 design 與 commit message：

| 問題 | 採用的預設 |
|------|------------|
| Q1 標記並升級，或移除工具的本機快取路徑 | 標記並升級（建議選項）；標記放在錨點之後自己的一行，內容照 Diagnosis 寫的 `<!-- provisional: local-cache -->` |
| Q2 書籤以下的區塊要不要另外提供升級方式（`refresh` 參數） | 不提供；用較舊的 `after_message_id` 重跑 |

Diagnosis 留給 spec 決定的兩點，這裡的選擇：`files` 列出有升級的日檔（Diagnosis 第 3 點）；帶標記的區塊屬於工具，升級時手動加進去的內容會被換掉（Risks 第 2 點）。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `telegram-chat-archive`：修改五個 requirement——「Day file format」（標記行的確切格式與位置、內文不能偽造標記）、「Merge and idempotent rewrite」（升級規則、不降級、重跑位元組不變的條件）、「Content-free manifest」（`upgraded_messages`、`files` 的定義）、「Archive from the local cache」（新區塊帶標記、之後由 TDLib 升級、舊版沒有標記的區塊不動）、「archive-telegram end-of-run check and report」（報告升級數與快取區塊是暫時的）。

## Impact

- 受影響的 spec：`telegram-chat-archive`。這五個 requirement 中有四個也被進行中的 `harden-chat-archive-media-and-day-files`（#75、#76）修改，「Day file format」也被 `keep-poll-sticker-location-details`（#82）修改；本 change 的 MODIFIED 文字以它們修改後的版本為底，archive 順序必須是 harden → keep-poll → 本 change。
- 程式：`che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift`（標記、`block`、`merged`、`write`）、`che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift`（傳入來源、`upgradedMessages`、manifest）、`che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift`（工具說明）
- 測試：`che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift`、`ChatArchiverTests.swift`、`LocalCacheArchiveTests.swift`
- skill 與文件：`plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md`、`che-telegram-all-mcp/README.md`、`plugins/che-telegram-mcp/README.md`、`che-telegram-all-mcp/CHANGELOG.md`、`plugins/che-telegram-mcp/CHANGELOG.md`
- 相容性：舊 binary 讀到帶標記的日檔時，錨點照舊、區塊原樣保留，不會重複；它透過 TDLib 跑時不升級，新 binary 之後會。新 skill 配舊 binary 時 `upgraded_messages` 不存在，當作 0。
