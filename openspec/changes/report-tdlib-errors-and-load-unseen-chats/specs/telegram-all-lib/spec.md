## ADDED Requirements

### Requirement: A chat TDLib has not loaded is loaded by its id

Before its first request on a chat, every `TDLibClient` method that takes a chat id SHALL make that chat known to TDLib: `getChat`, `getChatHistory`, `searchMessages`, `sendMessage`, `editMessage`, `deleteMessages`, `forwardMessages` (the source chat and the destination chat), `getChatMembers`, `pinMessage`, `unpinMessage`, `setChatTitle`, `setChatDescription`, `addChatMember`, `markAsRead`, and the archive's history source (on every page, whatever the cursor) and single-message read. The call SHALL be made unconditionally, on a line of its own, before the method's first request. The MCP tools and CLI commands built on these methods, including `dump_chat_to_markdown`, `archive_chat_to_markdown` and `download_message_media`, inherit this. Making a chat known SHALL send `getChat`; when `getChat` fails with code 400, the client SHALL create the chat from its id by TDLib's id ranges: `createPrivateChat` for a user id (1 to 2^40 − 1), `createBasicGroupChat` for a basic group id (−1 to −999 999 999 999), and `createSupergroupChat` for a supergroup or channel id (−1 000 000 000 001 to −1 997 852 516 352), each with `force: false`. Creating a chat changes only TDLib's local state: it sends no message and changes nothing in the chat, also when it runs before a write request.

When the chat cannot be created, because its id is in none of these ranges (for example a secret chat) or because the create request fails with code 400, the method SHALL throw `TDError.unknownChat(chatId:code:message:)` carrying the code and message of the `getChat` error, not those of the create request. The MCP server SHALL report it as a JSON content block `{"type": "tdlib_error", "code": <code>, "message": <message>, "hint": <string>}` with `isError: true`, where the hint names the chat id, says that TDLib has not loaded the chat and could not load it by its id, and tells the caller to call `get_chats` with a limit large enough to reach the chat and then try again; the `telegram-all` CLI SHALL print the code, the message and the same hint. Any other error, from `getChat` (a code other than 400) or from the create request (a code other than 400, such as a rate limit, or a closed session), SHALL be thrown unchanged, and no create request SHALL be sent after a `getChat` error other than 400 (PsychQuant/che-msg#71).

#### Scenario: a known chat is used as it is

- **WHEN** `get_chat_history` is called with a chat id and `getChat` succeeds
- **THEN** no create request is sent and the history is read

#### Scenario: an unseen one-to-one chat is created from its id

- **WHEN** `get_chat_history` is called with the chat id of a user that TDLib has not loaded, and `getChat` answers `Error{code: 400, message: "Chat not found"}`
- **THEN** the client sends `createPrivateChat(force: false, userId: <that id>)` and, when it succeeds, reads the history

#### Scenario: a chat that cannot be created is reported with TDLib's original error

- **WHEN** `getChat` answers `Error{code: 400, message: "Chat not found"}` for a supergroup chat id and `createSupergroupChat` answers `Error{code: 400, message: "Supergroup not found"}`
- **THEN** the MCP response is `{"type": "tdlib_error", "code": 400, "message": "Chat not found", "hint": <string>}` with `isError == true`, and the hint names the chat id and `get_chats`

#### Scenario: an id no chat can be created from

- **WHEN** `getChat` answers code 400 for a secret chat id
- **THEN** no create request is sent and the client throws `TDError.unknownChat` with the `getChat` error's code and message

#### Scenario: a rate limit while creating the chat stays a rate limit

- **WHEN** `getChat` answers code 400 and `createPrivateChat` answers `Error{code: 429, message: "Too Many Requests: retry after 30"}`
- **THEN** the client throws `TDError.tdlibError(code: 429, message: "Too Many Requests: retry after 30")`, so the archive can wait it out

#### Scenario: an archive page below a cursor makes the chat known too

- **WHEN** the archive's history source is asked for a page below a non-zero message id for a chat that TDLib has not loaded
- **THEN** the client makes the chat known before it requests the page, as it does for the first page

#### Scenario: a write tool makes the chat known first

- **WHEN** `send_message` is called with the chat id of a user that TDLib has not loaded, and `createPrivateChat` succeeds
- **THEN** the message is sent to that chat, and nothing else is sent to it

##### Example: what each id is created as

| Chat id | Created with |
| ------- | ------------ |
| `123456789` | `createPrivateChat(userId: 123456789)` |
| `-123456789` | `createBasicGroupChat(basicGroupId: 123456789)` |
| `-1001234567890` | `createSupergroupChat(supergroupId: 1234567890)` |
| `-1997852516353` (secret chat range) | nothing; `unknownChat` |
| `0` | nothing; `unknownChat` |
