## ADDED Requirements

### Requirement: A chat TDLib has not loaded is loaded by its id

Before its first request on a chat, every `TDLibClient` method that takes a chat id SHALL make that chat known to TDLib: `getChat`, `getChatHistory`, `searchMessages`, `sendMessage`, `editMessage`, `deleteMessages`, `forwardMessages` (the source chat and the destination chat), `getChatMembers`, `pinMessage`, `unpinMessage`, `setChatTitle`, `setChatDescription`, `addChatMember`, `markAsRead`, and the archive's history source (on every page, whatever the cursor) and single-message read. The call SHALL be made unconditionally, on a line of its own, before the method's first request. The MCP tools and CLI commands built on these methods, including `dump_chat_to_markdown`, `archive_chat_to_markdown` and `download_message_media`, inherit this. Making a chat known SHALL send `getChat`; when `getChat` fails with code 400, the client SHALL create the chat from its id by TDLib's id ranges: `createPrivateChat` for a user id (1 to 2^40 − 1), `createBasicGroupChat` for a basic group id (−1 to −999 999 999 999), and `createSupergroupChat` for a supergroup or channel id (−1 000 000 000 001 to −1 997 852 516 352), each with `force: false`. Creating a chat changes only TDLib's local state: it sends no message and changes nothing in the chat, also when it runs before a write request.

The outcome of making a chat known SHALL follow TDLib's answers, as listed here (PsychQuant/che-msg#71); TDLib answers `getChat` for a chat it has not loaded with `Error{code: 400, message: "Chat not found"}`, and a create request with `Error{code: 400, message: "Chat info not found"}` when it has no information about the user or group and `Error{code: 400, message: "Can't access the chat"}` when it has some but the account cannot read the chat:

- When `getChat` fails with an error other than code 400 (for example a rate limit, or a closed session), the method SHALL throw that error unchanged and SHALL NOT send a create request.
- When `getChat` fails with code 400 and the chat id is in none of the ranges above (for example a secret chat id: this client opens TDLib with secret chats off), the method SHALL throw that `getChat` error unchanged, without a hint, and SHALL NOT send a create request.
- When the create request fails with code 400 and the message `Chat info not found`, the method SHALL throw `TDError.unknownChat(chatId:code:message:)` carrying the code and message of the `getChat` error, not those of the create request. The MCP server SHALL report it as a JSON content block `{"type": "tdlib_error", "code": <code>, "message": <message>, "hint": <string>}` with `isError: true`, where the hint names the chat id, says that TDLib has no information about the chat and could not load it by its id, tells the caller to call `get_chats` with a limit large enough to reach the chat and then try again, and says that `get_chats` reads only the main chat list, so it does not load a chat archived in Telegram; the `telegram-all` CLI SHALL print the code, the message and the same hint.
- When the create request fails in any other way (for example `Can't access the chat`, another code 400 message, a rate limit, or a closed session), the method SHALL throw that error unchanged, without a hint.

#### Scenario: a known chat is used as it is

- **WHEN** `get_chat_history` is called with a chat id and `getChat` succeeds
- **THEN** no create request is sent and the history is read

#### Scenario: an unseen one-to-one chat is created from its id

- **WHEN** `get_chat_history` is called with the chat id of a user that TDLib has not loaded, and `getChat` answers `Error{code: 400, message: "Chat not found"}`
- **THEN** the client sends `createPrivateChat(force: false, userId: <that id>)` and, when it succeeds, reads the history

#### Scenario: a chat TDLib has no information about is reported with TDLib's original error and a hint

- **WHEN** `getChat` answers `Error{code: 400, message: "Chat not found"}` for a supergroup chat id and `createSupergroupChat` answers `Error{code: 400, message: "Chat info not found"}`
- **THEN** the MCP response is `{"type": "tdlib_error", "code": 400, "message": "Chat not found", "hint": <string>}` with `isError == true`, and the hint names the chat id and `get_chats` and says that `get_chats` does not load a chat archived in Telegram

#### Scenario: a chat the account cannot access keeps the create request's error

- **WHEN** `getChat` answers code 400 for a supergroup chat id and `createSupergroupChat` answers `Error{code: 400, message: "Can't access the chat"}` (for example a private supergroup the account has left)
- **THEN** the MCP response is `{"type": "tdlib_error", "code": 400, "message": "Can't access the chat"}` with `isError == true` and no `hint`

#### Scenario: an id no chat can be created from

- **WHEN** `getChat` answers `Error{code: 400, message: "Chat not found"}` for a secret chat id
- **THEN** no create request is sent and the client throws `TDError.tdlibError(code: 400, message: "Chat not found")`, which the server reports without a `hint`

#### Scenario: a rate limit while creating the chat stays a rate limit

- **WHEN** `getChat` answers code 400 and `createPrivateChat` answers `Error{code: 429, message: "Too Many Requests: retry after 30"}`
- **THEN** the client throws `TDError.tdlibError(code: 429, message: "Too Many Requests: retry after 30")`, so the archive can wait it out

#### Scenario: an archive page below a cursor makes the chat known too

- **WHEN** the archive's history source is asked for `page(chatId: 123456789, fromMessageId: 5000, limit: 100)` and TDLib has not loaded chat 123456789
- **THEN** the client sends `getChat(chatId: 123456789)` (and, on its 400, `createPrivateChat(force: false, userId: 123456789)`) before it sends `getChatHistory`, as it does for the first page

#### Scenario: a write tool makes the chat known first

- **WHEN** `send_message` is called with the chat id of a user that TDLib has not loaded, and `createPrivateChat` succeeds
- **THEN** the message is sent to that chat, and nothing else is sent to it

##### Example: what each id is created as, and what a failure reports

| Chat id | Create request | Create answers | Thrown |
| ------- | -------------- | -------------- | ------ |
| `123456789` | `createPrivateChat(force: false, userId: 123456789)` | the chat | (the chat is used) |
| `-123456789` | `createBasicGroupChat(basicGroupId: 123456789, force: false)` | `400 "Chat info not found"` | `unknownChat` with the `getChat` error |
| `-1001234567890` | `createSupergroupChat(force: false, supergroupId: 1234567890)` | `400 "Can't access the chat"` | `tdlibError(400, "Can't access the chat")` |
| `-1001234567890` | `createSupergroupChat(force: false, supergroupId: 1234567890)` | `429 "Too Many Requests: retry after 30"` | that error |
| `-1997852516353` (secret chat range) | none | — | the `getChat` error |
| `0` | none | — | the `getChat` error |
