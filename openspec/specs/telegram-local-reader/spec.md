# telegram-local-reader Specification

## Purpose

Defines the read-only local reader in `TelegramAllLib` that answers chat and message queries directly from TDLib's encrypted on-disk cache while another process holds TDLib. It exists so a session that does not hold TDLib can still read Telegram, without opening a second TDLib instance or writing to TDLib's files.

## Requirements

### Requirement: Reader obtains the SQLite key from the binlog

The local reader SHALL derive the binlog AES-CTR key from TDLib's default key `cucumber` using PBKDF2-SHA256 with the salt recorded in the binlog encryption event and the 2 iterations TDLib uses for a raw key such as `cucumber`, decrypt `td.binlog`, and read the SQLite key from the binlog `sqlite_key` entry. The reader SHALL use only binlog events whose length and CRC are valid and SHALL skip an incomplete event at the end of the file.

#### Scenario: Key extracted from a fixture binlog

- **WHEN** the reader decodes a fixture `td.binlog` created by TDLib 1.8.60 with an empty `databaseEncryptionKey`
- **THEN** it returns the 32-byte `sqlite_key` stored in that binlog

#### Scenario: Truncated last event is skipped

- **WHEN** the fixture `td.binlog` ends with a partially written event
- **THEN** the reader ignores that event and still returns the `sqlite_key` from the complete events

#### Scenario: No sqlite_key in the binlog

- **WHEN** the binlog contains no `sqlite_key` entry
- **THEN** the reader returns `local_reader_unavailable` with reason `key_not_found`


<!-- @trace
source: telegram-all-sqlite-reader
updated: 2026-10-10
code:
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatListTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalTDLibReader.swift
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - .agents/skills/spectra-review/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalMessage.swift
  - .agents/skills/spectra-verify/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalReaderError.swift
  - CLAUDE.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibProcessLock.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatDecodingTests.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalChat.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/db.sqlite
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderMessageDecodingTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibProcessLockTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibMessageDecoder.swift
  - .agents/skills/spectra-debug/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibLifecycleTests.swift
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Messages.swift
  - plugins/che-telegram-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.no-sqlite-key
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-propose/SKILL.md
  - tests/che-telegram-mcp/test-wrapper-mcp-error.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderDatabaseTests.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.sh
  - che-telegram-all-mcp/Package.swift
  - .agents/skills/spectra-drift/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/DialogKind.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase.swift
  - AGENTS.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderTestSupport.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthorizationSettleTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.truncated
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderBinlogTests.swift
  - tests/lib/wrapper_harness.sh
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCP/main.swift
  - .claude-plugin/marketplace.json
  - tests/che-telegram-mcp/test-plugin-layout-mutations.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibLifecycle.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderRealDataComparisonTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Chats.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/expected.json
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CLIBootstrapTests.swift
  - tests/che-telegram-mcp/test-wrapper-pid.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibRecordDecoder.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Sources/CTDLibSQLite/shim.c
  - plugins/che-telegram-mcp/README.md
  - .agents/skills/spectra-commit/SKILL.md
  - che-telegram-all-mcp/Sources/CTDLibSQLite/include/CTDLibSQLite.h
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibBinlogReader.swift
-->

---
### Requirement: Reader never writes TDLib files

The local reader SHALL open `db.sqlite` with `SQLITE_OPEN_READONLY` through the SQLCipher functions bundled in TDLibFramework and SHALL open `td.binlog` read-only. It SHALL NOT modify `db.sqlite`, `db.sqlite-wal` or `td.binlog`, and SHALL NOT create or delete any file in the TDLib database directory. Updates that SQLite itself makes to `db.sqlite-shm`, the shared-memory index it maintains for concurrent readers, are the one exception and SHALL NOT count as the reader writing TDLib files. When `db.sqlite-wal` does not exist, which is the case when no TDLib instance holds the database, the reader SHALL open `db.sqlite` as immutable, so that SQLite creates neither `db.sqlite-wal` nor `db.sqlite-shm`; when `db.sqlite-wal` exists, the reader SHALL read it, so that messages a holder has not yet checkpointed into `db.sqlite` are included.

#### Scenario: Directory unchanged after reading

- **WHEN** the reader answers `get_chat_history` against a copy of a TDLib database directory
- **THEN** every file in that directory other than `db.sqlite-shm` has the same size and modification time as before the call, and no file was added or removed

#### Scenario: Directory unchanged when no TDLib instance holds the database

- **WHEN** the reader reads a copy of a TDLib database directory that contains `td.binlog` and `db.sqlite` but no `db.sqlite-wal`
- **THEN** every file in that directory has the same size and modification time as before, and no file was added, `db.sqlite-wal` and `db.sqlite-shm` included

#### Scenario: Data a holder has not checkpointed is read

- **WHEN** a TDLib instance holding the database has committed a row that is still only in `db.sqlite-wal`, and the reader reads the directory
- **THEN** the reader's result includes that row, and only `db.sqlite-shm` changed


<!-- @trace
source: telegram-all-sqlite-reader
updated: 2026-10-10
code:
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatListTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalTDLibReader.swift
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - .agents/skills/spectra-review/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalMessage.swift
  - .agents/skills/spectra-verify/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalReaderError.swift
  - CLAUDE.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibProcessLock.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatDecodingTests.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalChat.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/db.sqlite
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderMessageDecodingTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibProcessLockTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibMessageDecoder.swift
  - .agents/skills/spectra-debug/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibLifecycleTests.swift
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Messages.swift
  - plugins/che-telegram-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.no-sqlite-key
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-propose/SKILL.md
  - tests/che-telegram-mcp/test-wrapper-mcp-error.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderDatabaseTests.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.sh
  - che-telegram-all-mcp/Package.swift
  - .agents/skills/spectra-drift/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/DialogKind.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase.swift
  - AGENTS.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderTestSupport.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthorizationSettleTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.truncated
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderBinlogTests.swift
  - tests/lib/wrapper_harness.sh
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCP/main.swift
  - .claude-plugin/marketplace.json
  - tests/che-telegram-mcp/test-plugin-layout-mutations.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibLifecycle.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderRealDataComparisonTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Chats.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/expected.json
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CLIBootstrapTests.swift
  - tests/che-telegram-mcp/test-wrapper-pid.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibRecordDecoder.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Sources/CTDLibSQLite/shim.c
  - plugins/che-telegram-mcp/README.md
  - .agents/skills/spectra-commit/SKILL.md
  - che-telegram-all-mcp/Sources/CTDLibSQLite/include/CTDLibSQLite.h
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibBinlogReader.swift
-->

---
### Requirement: Reader reads only a logged-in TDLib directory

The local reader SHALL read a TDLib database directory only when the binlog key-value store, replayed as TDLib replays it (a rewrite replaces the entry with the same event id, an `Empty` rewrite erases it), holds the entry `auth` with the value `ok`, which TDLib writes on login and replaces with `logout` or `destroy` when the session ends. Otherwise the reader SHALL return `local_reader_unavailable` with reason `not_authenticated`.

#### Scenario: Directory that was never logged in

- **WHEN** the reader is pointed at a TDLib directory whose binlog has no `auth` entry
- **THEN** it returns `local_reader_unavailable` with reason `not_authenticated` and reads no chat or message

#### Scenario: Directory that was logged out

- **WHEN** the binlog's latest `auth` entry is `logout`
- **THEN** the reader returns `local_reader_unavailable` with reason `not_authenticated`


<!-- @trace
source: telegram-all-sqlite-reader
updated: 2026-10-10
code:
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatListTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalTDLibReader.swift
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - .agents/skills/spectra-review/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalMessage.swift
  - .agents/skills/spectra-verify/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalReaderError.swift
  - CLAUDE.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibProcessLock.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatDecodingTests.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalChat.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/db.sqlite
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderMessageDecodingTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibProcessLockTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibMessageDecoder.swift
  - .agents/skills/spectra-debug/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibLifecycleTests.swift
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Messages.swift
  - plugins/che-telegram-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.no-sqlite-key
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-propose/SKILL.md
  - tests/che-telegram-mcp/test-wrapper-mcp-error.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderDatabaseTests.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.sh
  - che-telegram-all-mcp/Package.swift
  - .agents/skills/spectra-drift/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/DialogKind.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase.swift
  - AGENTS.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderTestSupport.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthorizationSettleTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.truncated
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderBinlogTests.swift
  - tests/lib/wrapper_harness.sh
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCP/main.swift
  - .claude-plugin/marketplace.json
  - tests/che-telegram-mcp/test-plugin-layout-mutations.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibLifecycle.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderRealDataComparisonTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Chats.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/expected.json
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CLIBootstrapTests.swift
  - tests/che-telegram-mcp/test-wrapper-pid.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibRecordDecoder.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Sources/CTDLibSQLite/shim.c
  - plugins/che-telegram-mcp/README.md
  - .agents/skills/spectra-commit/SKILL.md
  - che-telegram-all-mcp/Sources/CTDLibSQLite/include/CTDLibSQLite.h
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibBinlogReader.swift
-->

---
### Requirement: Reader never exposes the database key

The local reader SHALL NOT log, cache to disk, return, or include in any error message the binlog key or the SQLite key.

#### Scenario: Key absent from outputs

- **WHEN** the reader answers any supported tool or returns any error
- **THEN** neither key's bytes, hex form, nor base64 form appear in the tool result, in stderr, or in any file the reader writes


<!-- @trace
source: telegram-all-sqlite-reader
updated: 2026-10-10
code:
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatListTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalTDLibReader.swift
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - .agents/skills/spectra-review/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalMessage.swift
  - .agents/skills/spectra-verify/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalReaderError.swift
  - CLAUDE.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibProcessLock.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatDecodingTests.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalChat.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/db.sqlite
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderMessageDecodingTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibProcessLockTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibMessageDecoder.swift
  - .agents/skills/spectra-debug/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibLifecycleTests.swift
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Messages.swift
  - plugins/che-telegram-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.no-sqlite-key
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-propose/SKILL.md
  - tests/che-telegram-mcp/test-wrapper-mcp-error.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderDatabaseTests.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.sh
  - che-telegram-all-mcp/Package.swift
  - .agents/skills/spectra-drift/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/DialogKind.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase.swift
  - AGENTS.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderTestSupport.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthorizationSettleTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.truncated
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderBinlogTests.swift
  - tests/lib/wrapper_harness.sh
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCP/main.swift
  - .claude-plugin/marketplace.json
  - tests/che-telegram-mcp/test-plugin-layout-mutations.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibLifecycle.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderRealDataComparisonTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Chats.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/expected.json
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CLIBootstrapTests.swift
  - tests/che-telegram-mcp/test-wrapper-pid.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibRecordDecoder.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Sources/CTDLibSQLite/shim.c
  - plugins/che-telegram-mcp/README.md
  - .agents/skills/spectra-commit/SKILL.md
  - che-telegram-all-mcp/Sources/CTDLibSQLite/include/CTDLibSQLite.h
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibBinlogReader.swift
-->

---
### Requirement: Reader accepts only verified TDLib versions

The local reader SHALL check the TDLib version and the SQLite `user_version` before reading and SHALL proceed only for TDLib 1.8.60 (commit `cb863c16`) and its SQLite `user_version`. For any other version it SHALL return `local_reader_unavailable` with reason `unsupported_tdlib_version` and SHALL NOT return partial results.

#### Scenario: Unknown SQLite user_version

- **WHEN** `db.sqlite` reports a `user_version` that differs from the verified value
- **THEN** the reader returns `{"type":"local_reader_unavailable","reason":"unsupported_tdlib_version","message":...}` with `isError: true`


<!-- @trace
source: telegram-all-sqlite-reader
updated: 2026-10-10
code:
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatListTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalTDLibReader.swift
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - .agents/skills/spectra-review/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalMessage.swift
  - .agents/skills/spectra-verify/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalReaderError.swift
  - CLAUDE.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibProcessLock.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatDecodingTests.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalChat.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/db.sqlite
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderMessageDecodingTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibProcessLockTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibMessageDecoder.swift
  - .agents/skills/spectra-debug/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibLifecycleTests.swift
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Messages.swift
  - plugins/che-telegram-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.no-sqlite-key
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-propose/SKILL.md
  - tests/che-telegram-mcp/test-wrapper-mcp-error.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderDatabaseTests.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.sh
  - che-telegram-all-mcp/Package.swift
  - .agents/skills/spectra-drift/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/DialogKind.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase.swift
  - AGENTS.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderTestSupport.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthorizationSettleTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.truncated
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderBinlogTests.swift
  - tests/lib/wrapper_harness.sh
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCP/main.swift
  - .claude-plugin/marketplace.json
  - tests/che-telegram-mcp/test-plugin-layout-mutations.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibLifecycle.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderRealDataComparisonTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Chats.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/expected.json
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CLIBootstrapTests.swift
  - tests/che-telegram-mcp/test-wrapper-pid.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibRecordDecoder.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Sources/CTDLibSQLite/shim.c
  - plugins/che-telegram-mcp/README.md
  - .agents/skills/spectra-commit/SKILL.md
  - che-telegram-all-mcp/Sources/CTDLibSQLite/include/CTDLibSQLite.h
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibBinlogReader.swift
-->

---
### Requirement: Reader answers five tools with the TDLib-mode JSON fields

The local reader SHALL answer `get_chats`, `search_chats`, `get_chat_history`, `search_messages` and `dump_chat_to_markdown`. Chat objects SHALL use the fields `id`, `title`, `type` and, when the cache holds a message for the chat, `last_message` (the newest cached message; one that cannot be decoded appears as "Undecodable records are reported, not guessed" describes). Message objects SHALL use the fields `id`, `chat_id`, `date`, `sender`, `is_outgoing`, `type` and `text` or `caption` when present. A field the reader cannot determine SHALL be omitted rather than filled with a placeholder value. `get_chat_history` SHALL accept the same arguments as in TDLib mode, including its date range filters. `dump_chat_to_markdown` SHALL produce the Markdown format defined by the `telegram-history-export` capability. Message text SHALL come from decoding the message `data`, not from the `text` column. `search_messages` SHALL return the messages whose decoded text contains the query as a case-insensitive substring.

#### Scenario: Search matches decoded text

- **WHEN** `search_messages` is called with query `HELLO` for a chat whose cached messages decode to the texts "hello there" and "bye"
- **THEN** the result contains only the message whose text is "hello there"

#### Scenario: Chat history from the local cache

- **WHEN** `get_chat_history` is called for a private chat whose messages exist in the cache
- **THEN** the first content item is a JSON array of message objects ordered as in TDLib mode, each with `id`, `chat_id`, `date`, `sender`, `is_outgoing`, `type`, and `text` for text messages

##### Example: one text message

- **GIVEN** the cache holds message 5242880 in chat 777 sent by user 1001 at Unix time 1760000000 with text "hello"
- **WHEN** `get_chat_history` is called with `chat_id` 777
- **THEN** the array contains `{"id":5242880,"chat_id":777,"date":1760000000,"sender":{"type":"user","user_id":1001},"is_outgoing":false,"type":"text","text":"hello"}`

#### Scenario: Unread count omitted

- **WHEN** `get_chats` is answered by the reader and the unread count is not decodable from the cache
- **THEN** chat objects omit `unread_count` instead of reporting 0


<!-- @trace
source: telegram-all-sqlite-reader
updated: 2026-10-10
code:
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatListTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalTDLibReader.swift
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - .agents/skills/spectra-review/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalMessage.swift
  - .agents/skills/spectra-verify/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalReaderError.swift
  - CLAUDE.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibProcessLock.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatDecodingTests.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalChat.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/db.sqlite
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderMessageDecodingTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibProcessLockTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibMessageDecoder.swift
  - .agents/skills/spectra-debug/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibLifecycleTests.swift
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Messages.swift
  - plugins/che-telegram-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.no-sqlite-key
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-propose/SKILL.md
  - tests/che-telegram-mcp/test-wrapper-mcp-error.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderDatabaseTests.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.sh
  - che-telegram-all-mcp/Package.swift
  - .agents/skills/spectra-drift/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/DialogKind.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase.swift
  - AGENTS.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderTestSupport.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthorizationSettleTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.truncated
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderBinlogTests.swift
  - tests/lib/wrapper_harness.sh
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCP/main.swift
  - .claude-plugin/marketplace.json
  - tests/che-telegram-mcp/test-plugin-layout-mutations.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibLifecycle.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderRealDataComparisonTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Chats.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/expected.json
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CLIBootstrapTests.swift
  - tests/che-telegram-mcp/test-wrapper-pid.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibRecordDecoder.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Sources/CTDLibSQLite/shim.c
  - plugins/che-telegram-mcp/README.md
  - .agents/skills/spectra-commit/SKILL.md
  - che-telegram-all-mcp/Sources/CTDLibSQLite/include/CTDLibSQLite.h
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibBinlogReader.swift
-->

---
### Requirement: Reader marks its results as coming from the local cache

Every successful reader result SHALL contain a second text content item that states `source: local-cache`, the PID of the process holding TDLib, the number of records whose data could not be decoded, and, for each chat the result covers, the date of the newest message for that chat in the local cache as a calendar date in the server's local time zone (or that the cache holds no message for it). The note SHALL state that the cache contains only messages TDLib has loaded, so newer messages can exist on Telegram.

#### Scenario: Source note present

- **WHEN** `search_chats` is answered by the reader while process 4242 holds TDLib
- **THEN** the result has two content items, and the second contains `source: local-cache` and `4242`

#### Scenario: Source note states how old the cache is

- **WHEN** `get_chat_history` is answered by the reader for a chat whose newest cached message is dated 2026-04-30
- **THEN** the second content item states that the newest cached message for that chat is from 2026-04-30 and that newer messages can exist on Telegram

##### Example: freshness lines

The server's time zone is UTC+08:00.

| Chat | Newest cached message | Freshness line in the note |
| ---- | --------------------- | -------------------------- |
| 777 | Unix 1777507200 (2026-04-30) | chat 777: newest cached message 2026-04-30 |
| 888 | none | chat 888: no cached messages |


<!-- @trace
source: telegram-all-sqlite-reader
updated: 2026-10-10
code:
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatListTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalTDLibReader.swift
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - .agents/skills/spectra-review/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalMessage.swift
  - .agents/skills/spectra-verify/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalReaderError.swift
  - CLAUDE.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibProcessLock.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatDecodingTests.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalChat.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/db.sqlite
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderMessageDecodingTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibProcessLockTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibMessageDecoder.swift
  - .agents/skills/spectra-debug/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibLifecycleTests.swift
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Messages.swift
  - plugins/che-telegram-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.no-sqlite-key
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-propose/SKILL.md
  - tests/che-telegram-mcp/test-wrapper-mcp-error.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderDatabaseTests.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.sh
  - che-telegram-all-mcp/Package.swift
  - .agents/skills/spectra-drift/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/DialogKind.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase.swift
  - AGENTS.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderTestSupport.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthorizationSettleTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.truncated
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderBinlogTests.swift
  - tests/lib/wrapper_harness.sh
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCP/main.swift
  - .claude-plugin/marketplace.json
  - tests/che-telegram-mcp/test-plugin-layout-mutations.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibLifecycle.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderRealDataComparisonTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Chats.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/expected.json
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CLIBootstrapTests.swift
  - tests/che-telegram-mcp/test-wrapper-pid.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibRecordDecoder.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Sources/CTDLibSQLite/shim.c
  - plugins/che-telegram-mcp/README.md
  - .agents/skills/spectra-commit/SKILL.md
  - che-telegram-all-mcp/Sources/CTDLibSQLite/include/CTDLibSQLite.h
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibBinlogReader.swift
-->

---
### Requirement: Undecodable records are reported, not guessed

When the internal data of a chat or message cannot be decoded, the reader SHALL still list the record with the fields it knows from table columns, SHALL set `type` to `unknown`, SHALL count the record in the source note, and SHALL NOT infer the missing values. For a message whose fixed prefix (flag words, `message_id`, sender user id, date) decodes and whose decoded `message_id` equals the `message_id` column, the reader SHALL also give the decoded `date` and `is_outgoing`. When the prefix has a flag bit TDLib 1.8.60 does not define, a version newer than TDLib 1.8.60, or a `message_id` different from the column, the message SHALL have only the fields from table columns.

#### Scenario: Message with an unknown content flag

- **WHEN** a message's `data` contains a flag the reader does not recognise
- **THEN** the message appears with `id`, `chat_id`, `sender` taken from the `sender_user_id` column, `type` set to `unknown` and no `text`, and the source note counts one undecodable record

#### Scenario: Message that stops before its content

- **WHEN** a message's `data` decodes up to its date but then carries forward information, which the reader does not decode
- **THEN** the message appears with `id`, `chat_id`, `sender` taken from the `sender_user_id` column, the decoded `date` and `is_outgoing`, `type` set to `unknown` and no `text`

##### Example: forwarded message

- **GIVEN** message 5242880 in chat 777 was sent by user 1001 at Unix time 1760000000, is not outgoing, and its `data` carries forward information
- **WHEN** `get_chat_history` is called with `chat_id` 777
- **THEN** the array contains `{"chat_id":777,"date":1760000000,"id":5242880,"is_outgoing":false,"sender":{"type":"user","user_id":1001},"type":"unknown"}`

<!-- @trace
source: telegram-all-sqlite-reader
updated: 2026-10-10
code:
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatListTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalTDLibReader.swift
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - .agents/skills/spectra-review/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalMessage.swift
  - .agents/skills/spectra-verify/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalReaderError.swift
  - CLAUDE.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibProcessLock.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderChatDecodingTests.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/LocalChat.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/db.sqlite
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderMessageDecodingTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderToolTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibProcessLockTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibMessageDecoder.swift
  - .agents/skills/spectra-debug/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibLifecycleTests.swift
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Messages.swift
  - plugins/che-telegram-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.no-sqlite-key
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-propose/SKILL.md
  - tests/che-telegram-mcp/test-wrapper-mcp-error.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderDatabaseTests.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.sh
  - che-telegram-all-mcp/Package.swift
  - .agents/skills/spectra-drift/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/DialogKind.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase.swift
  - AGENTS.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderTestSupport.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthorizationSettleTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/td.binlog.truncated
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderBinlogTests.swift
  - tests/lib/wrapper_harness.sh
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCP/main.swift
  - .claude-plugin/marketplace.json
  - tests/che-telegram-mcp/test-plugin-layout-mutations.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibLifecycle.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalReaderRealDataComparisonTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibCacheDatabase+Chats.swift
  - che-telegram-all-mcp/Tools/reader-fixtures/generate.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/Fixtures/tdlib-1.8.60-test-dc/expected.json
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CLIBootstrapTests.swift
  - tests/che-telegram-mcp/test-wrapper-pid.sh
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibRecordDecoder.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Sources/CTDLibSQLite/shim.c
  - plugins/che-telegram-mcp/README.md
  - .agents/skills/spectra-commit/SKILL.md
  - che-telegram-all-mcp/Sources/CTDLibSQLite/include/CTDLibSQLite.h
  - che-telegram-all-mcp/Sources/TelegramAllLib/LocalReader/TDLibBinlogReader.swift
-->