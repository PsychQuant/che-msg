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

即時通訊 MCP Server monorepo。

## 結構

| 目錄 | 說明 | 底層 |
|------|------|------|
| `che-telegram-bot-mcp` | Telegram Bot API | Swift + MCP SDK |
| `che-telegram-all-mcp` | Telegram 個人帳號 (MTProto/TDLib) | Swift + TDLibKit |

## 架構（bot-mcp）

bot-mcp 拆為三層，共用同一個 `TelegramBotAPI` library：

| Target | 用途 | 依賴 |
|--------|------|------|
| `TelegramBotAPI` | 純 Telegram HTTP client | Foundation only |
| `CheTelegramBotMCP` | MCP Server entry point | TelegramBotAPI + MCP SDK |
| `telegram-bot` | CLI 工具 | TelegramBotAPI + ArgumentParser |

## 開發

每個 MCP 都是獨立的 Swift Package，各自有 `Package.swift`。

```bash
# MCP Server
cd che-telegram-bot-mcp && swift build -c release
# CLI
swift build -c release --product telegram-bot

cd che-telegram-all-mcp && swift build -c release
```

## 未來擴展

- LINE MCP（目前 `che-archive-lines` 是純腳本自動化，待升級為 MCP）
- Slack / Discord 等即時通訊整合
- che-telegram-all-mcp 簡化：以讀取 local 對話記錄為主
