## ADDED Requirements

### Requirement: Standalone TDLib wrapper library

The system SHALL provide a `TelegramAllLib` Swift package target that wraps TDLib functionality without any MCP SDK dependency. The library SHALL expose all current `TDLibClient` public methods (authentication, chat operations, message operations, contact/user operations, group management, read state, logout) and SHALL depend only on Foundation and TDLibKit.

#### Scenario: MCP server imports TelegramAllLib

- **WHEN** `CheTelegramAllMCPCore` target is built
- **THEN** it SHALL successfully import `TelegramAllLib` and access all `TDLibClient` public methods

#### Scenario: CLI imports TelegramAllLib without MCP dependency

- **WHEN** `telegram-all` CLI target is built
- **THEN** it SHALL compile without the MCP SDK in its dependency graph
- **AND** it SHALL access all `TDLibClient` public methods

### Requirement: TelegramAllLib preserves existing API surface

The `TelegramAllLib` target SHALL expose the identical public API as the current `TDLibClient` class. No method signatures, return types, or error types SHALL change.

#### Scenario: No breaking changes after extraction

- **WHEN** `TDLibClient.swift` is moved from `CheTelegramAllMCPCore` to `TelegramAllLib`
- **THEN** `Server.swift` SHALL compile with only the addition of `import TelegramAllLib`
- **AND** all 28 MCP tools SHALL produce identical behavior
