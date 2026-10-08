<!-- SPECTRA:START v1.0.1 -->

# Spectra Instructions

This project uses Spectra for Spec-Driven Development(SDD). Specs live in `openspec/specs/`, change proposals in `openspec/changes/`.

## Use `/spectra:*` skills when:

- A discussion needs structure before coding → `/spectra:discuss`
- User wants to plan, propose, or design a change → `/spectra:propose`
- Tasks are ready to implement → `/spectra:apply`
- There's an in-progress change to continue → `/spectra:ingest`
- User asks about specs or how something works → `/spectra:ask`
- Implementation is done → `/spectra:archive`

## Workflow

discuss? → propose → apply ⇄ ingest → archive

- `discuss` is optional — skip if requirements are clear
- Requirements change mid-work? Plan mode → `ingest` → resume `apply`

## Parked Changes

Changes can be parked（暫存）— temporarily moved out of `openspec/changes/`. Parked changes won't appear in `spectra list` but can be found with `spectra list --parked`. To restore: `spectra unpark <name>`. The `/spectra:apply` and `/spectra:ingest` skills handle parked changes automatically.

<!-- SPECTRA:END -->

# che-msg

即時通訊 MCP Server monorepo，同時是 Claude Code plugin marketplace `che-msg`。

## 結構

| 目錄 | 說明 | 底層 |
|------|------|------|
| `che-telegram-bot-mcp` | Telegram Bot API | Swift + MCP SDK |
| `che-telegram-all-mcp` | Telegram 個人帳號 (MTProto/TDLib) | Swift + TDLibKit |
| `plugins/che-telegram-mcp` | Claude Code plugin：包上面兩個 MCP server（wrapper 從本 repo 的 release 下載 binary） | bash wrapper + skills |
| `plugins/che-archive-lines` | Claude Code plugin：LINE macOS「儲存聊天」自動化 | bash + cliclick |
| `.claude-plugin/marketplace.json` | marketplace `che-msg`，用相對路徑列出上面兩個 plugin | — |
| `tests/` | 兩個 plugin 的結構、wrapper、設定檔測試；`tests/lib/` 是共用 helper | bash + python3 |

## 架構

兩個 MCP 都拆為三層，共用一個底層 library：

**bot-mcp**

| Target | 用途 | 依賴 |
|--------|------|------|
| `TelegramBotAPI` | 純 Telegram HTTP client | Foundation only |
| `CheTelegramBotMCP` | MCP Server entry point | TelegramBotAPI + MCP SDK |
| `telegram-bot` | CLI 工具 | TelegramBotAPI + ArgumentParser |

**all-mcp**

| Target | 用途 | 依賴 |
|--------|------|------|
| `TelegramAllLib` | TDLib wrapper（個人帳號） | TDLibKit + TDLibFramework |
| `CheTelegramAllMCP` | MCP Server entry point | TelegramAllLib + MCP SDK |
| `telegram-all` | CLI 工具 | TelegramAllLib + ArgumentParser |

## Claude Code plugins

這兩個 plugin 原本在 PsychQuant/psychquant-claude-plugins，`06d073e` 時原樣搬進來（#42）。舊歷史留在那個 repo。

- 安裝：`claude plugin marketplace add PsychQuant/che-msg`，再 `claude plugin install <plugin>@che-msg`
- 改版：`plugins/<name>/.claude-plugin/plugin.json` 與 `.claude-plugin/marketplace.json` 的 `version` 一起改，CHANGELOG 同步
- binary 版本：wrapper 用 `DESIRED_VERSION` pin 本 repo 的 release（目前 0.5.0）。發新 binary 後要 bump 這個 pin，plugin 版號也跟著 bump
- README 寫給使用者打的安裝指令、GitHub 連結（含 wrapper 的 `docsUrl`）必須指向 `che-msg`，由結構測試的 check (j) 把關

## 開發

每個 MCP 都是獨立的 Swift Package，各自有 `Package.swift`。

```bash
# bot-mcp
cd che-telegram-bot-mcp && swift build -c release
swift build -c release --product telegram-bot

# all-mcp
cd che-telegram-all-mcp && swift build -c release
swift build -c release --product telegram-all
```

## 測試

```bash
# Unit tests（離線）
swift test --skip E2ETests

# E2E tests（需要真實 Telegram 認證）
export TELEGRAM_API_ID=... TELEGRAM_API_HASH=...
swift test --filter E2ETests
```

注意：TDLib receive loop 是 process-global，all-mcp 的 unit tests 和 E2E tests 必須分開跑。

Plugin 測試（repo 根目錄執行，需要 python3 + PyYAML；全部用 scratch 目錄與 stub，不會點擊滑鼠、不會碰真的 TDLib lock）：

```bash
for t in tests/che-telegram-mcp/*.sh tests/che-archive-lines/*.sh; do bash "$t" >/dev/null || echo "FAIL: $t"; done
claude plugin validate . && claude plugin validate plugins/che-telegram-mcp && claude plugin validate plugins/che-archive-lines
bash tests/frontmatter-subset-fuzz/run.sh   # 另需 bun：比對 PyYAML 與 Bun.YAML 對 frontmatter 的讀法
```

## all-mcp 認證流程（一次性）

```bash
telegram-all auth-phone +886912345678
telegram-all auth-code 12345
telegram-all auth-status   # 應顯示 "Authenticated ✓"
```

## 未來擴展

- LINE MCP（目前 `che-archive-lines` 是純腳本自動化，待升級為 MCP；見 #41）
- Slack / Discord 等即時通訊整合
- che-telegram-all-mcp 簡化：以讀取 local 對話記錄為主
