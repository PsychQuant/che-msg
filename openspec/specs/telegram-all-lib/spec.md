# telegram-all-lib Specification

## Purpose

Defines `TelegramAllLib`, the TDLib wrapper that the MCP server and the `telegram-all` CLI share, and the dependency boundary that keeps it free of the MCP SDK.

## Requirements

### Requirement: Standalone TDLib wrapper library

The system SHALL provide a `TelegramAllLib` Swift package target that wraps TDLib functionality without any MCP SDK dependency. The library SHALL expose the `TDLibClient` public methods (authentication, chat operations, message operations, contact/user operations, group management, read state, logout) and SHALL depend only on Foundation, TDLibKit, TDLibFramework and the package's own `CTDLibSQLite` C target, which the local TDLib cache reader uses.

#### Scenario: MCP server imports TelegramAllLib

- **WHEN** the `CheTelegramAllMCPCore` target is built
- **THEN** it SHALL successfully import `TelegramAllLib` and access all `TDLibClient` public methods

#### Scenario: CLI imports TelegramAllLib without MCP dependency

- **WHEN** the `telegram-all` CLI target is built
- **THEN** it SHALL compile without the MCP SDK in its dependency graph
- **AND** it SHALL access all `TDLibClient` public methods

<!-- @trace
source: refactor-telegram-all-mcp
updated: 2026-10-25
code:
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientDateFilterTests.swift
  - .spectra.yaml
  - che-telegram-all-mcp/README.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderBinlogTests.swift
  - tests/che-archive-lines/test-plugin-layout-mutations.sh
  - .agents/skills/spectra-review/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CLIBootstrapTests.swift
  - che-telegram-all-mcp/mcpb/PRIVACY.md
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalMessage.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalTDLibReader.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.sh
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatListTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibSyncStateTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift
  - tests/frontmatter-subset-fuzz/compare.py
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibBinlogReader.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownSenderResolveTests.swift
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibLifecycleTests.swift
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/hooks/check-mcp.sh
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - AGENTS.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthStatusNextStepTests.swift
  - tests/che-telegram-mcp/test-plugin-layout-mutations.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthRunHandlerTests.swift
  - README.md
  - plugins/che-archive-lines/skills/archive-lines/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/LogoutFlowTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCP/main.swift
  - che-telegram-all-mcp/Tests/E2ETests/TelegramE2ETests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AutoFireChainTests.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/AuthCoalescing.swift
  - che-telegram-all-mcp/run.sh
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LogoutFlow.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ErrorResponses.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/JSONDecoderRegressionTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibSyncState.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientTests.swift
  - plugins/che-archive-lines/scripts/line-save-chat.sh
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthStateLockingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibSessionReset.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderTestSupport.swift
  - plugins/che-telegram-mcp/skills/send/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthCoalescingTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibSyncWaitTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientPaginationTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/DateParsing.swift
  - tests/frontmatter-subset-fuzz/bun_parse.js
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LogoutResetTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - plugins/che-telegram-mcp/skills/auth/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderRealDataComparisonTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/MessageFilters.swift
  - che-msg.code-workspace
  - plugins/che-telegram-mcp/skills/search/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/SyncNoteTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - .claude-plugin/marketplace.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthErrorResponseTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/SyncNote.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/AuthResponses.swift
  - che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - tests/che-archive-lines/test-plugin-layout.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibLifecycle.swift
  - tests/lib/install_refs.py
  - tests/lib/wrapper_harness.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibMessageDecoder.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ServerDumpChatToolTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Messages.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthorizationSettleTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/expected.json
  - plugins/che-archive-lines/.claude-plugin/plugin.json
  - che-telegram-bot-mcp/run.sh
  - tests/che-telegram-mcp/test-wrapper-mcp-error.sh
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/DialogKind.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalChat.swift
  - .agents/skills/spectra-verify/SKILL.md
  - plugins/che-telegram-mcp/README.md
  - tests/frontmatter-subset-fuzz/run.sh
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - plugins/che-archive-lines/CHANGELOG.md
  - che-telegram-all-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Package.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/HandlerArgs.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/TDLibClient.swift
  - tests/lib/frontmatter_subset.py
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Chats.swift
  - plugins/che-telegram-mcp/hooks/hooks.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownExporterContractTests.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/DateParsingTests.swift
  - tests/che-telegram-mcp/test-wrapper-pid.sh
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.truncated
  - tests/che-archive-lines/test-config-validation.sh
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibProcessLockTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientBackwardCompatTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibAuthErrorTests.swift
  - che-telegram-all-mcp/Sources/telegram-all/AuthHelper.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - .agents/skills/spectra-drift/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderDatabaseTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatDecodingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibRecordDecoder.swift
  - che-telegram-all-mcp/Sources/CTDLibSQLite/shim.c
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalReaderError.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/HandlerGlueTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.no-sqlite-key
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ServerHandlerLogicTests.swift
  - plugins/che-telegram-mcp/.mcp.json
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/E2ETests/DumpChatToMarkdownE2ETests.swift
  - CLAUDE.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/MarkdownExporter.swift
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - tests/frontmatter-subset-fuzz/gen.py
  - che-telegram-all-mcp/mcpb/che-telegram-all-mcp.mcpb
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownFormatTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibProcessLock.swift
  - che-telegram-all-mcp/Sources/CTDLibSQLite/include/CTDLibSQLite.h
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-bot-mcp/mcpb/PRIVACY.md
  - che-telegram-all-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/chats/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/db.sqlite
  - plugins/che-archive-lines/README.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderMessageDecodingTests.swift
-->