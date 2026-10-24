## Purpose

Defines `TelegramAllLib`, the TDLib wrapper that the MCP server and the `telegram-all` CLI share, and the dependency boundary that keeps it free of the MCP SDK.

## ADDED Requirements

### Requirement: Standalone TDLib wrapper library

The system SHALL provide a `TelegramAllLib` Swift package target that wraps TDLib functionality without any MCP SDK dependency. The library SHALL expose the `TDLibClient` public methods (authentication, chat operations, message operations, contact/user operations, group management, read state, logout) and SHALL depend only on Foundation, TDLibKit, TDLibFramework and the package's own `CTDLibSQLite` C target, which the local TDLib cache reader uses.

#### Scenario: MCP server imports TelegramAllLib

- **WHEN** the `CheTelegramAllMCPCore` target is built
- **THEN** it SHALL successfully import `TelegramAllLib` and access all `TDLibClient` public methods

#### Scenario: CLI imports TelegramAllLib without MCP dependency

- **WHEN** the `telegram-all` CLI target is built
- **THEN** it SHALL compile without the MCP SDK in its dependency graph
- **AND** it SHALL access all `TDLibClient` public methods
