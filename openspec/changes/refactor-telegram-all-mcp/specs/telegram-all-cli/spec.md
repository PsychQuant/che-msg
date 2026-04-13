## ADDED Requirements

### Requirement: CLI executable for personal Telegram operations

The system SHALL provide a `telegram-all` CLI executable that exposes core Telegram personal account operations via ArgumentParser subcommands. The CLI SHALL depend on `TelegramAllLib` and `swift-argument-parser`, and SHALL NOT depend on the MCP SDK.

#### Scenario: CLI displays help

- **WHEN** user runs `telegram-all --help`
- **THEN** the CLI SHALL display available subcommands and usage information

#### Scenario: CLI reads environment variables for authentication

- **WHEN** `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` environment variables are set
- **THEN** the CLI SHALL use them to initialize the TDLib client
- **WHEN** the environment variables are not set
- **THEN** the CLI SHALL exit with an error message indicating the missing variables

### Requirement: CLI subcommands cover core read and write operations

The CLI SHALL provide subcommands for the following operations:

- `me` — display current user info
- `chats` — list recent conversations
- `history <chat_id>` — read message history from a chat
- `search <chat_id> <query>` — search messages within a chat
- `send <chat_id> <text>` — send a text message
- `contacts` — list contacts

#### Scenario: List recent chats

- **WHEN** user runs `telegram-all chats`
- **THEN** the CLI SHALL output a JSON array of recent conversations with id, title, type, and unread_count

#### Scenario: Read chat history

- **WHEN** user runs `telegram-all history <chat_id>`
- **THEN** the CLI SHALL output a JSON array of messages with id, date, sender, type, and text content

#### Scenario: Send a message

- **WHEN** user runs `telegram-all send <chat_id> <text>`
- **THEN** the CLI SHALL send the message via the authenticated personal account
- **AND** output the sent message as JSON

#### Scenario: Search messages

- **WHEN** user runs `telegram-all search <chat_id> <query>`
- **THEN** the CLI SHALL output matching messages as a JSON array
