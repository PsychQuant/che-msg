## ADDED Requirements

### Requirement: Every TDLib request reports TDLib's code and message

Every TDLib request that the TDLib client sends, other than the requests of the four authentication methods (`setParameters`, `sendPhoneNumber`, `sendAuthCode`, `sendPassword`), SHALL convert a `TDLibKit.Error` into `TDError.tdlibError(code:message:)` carrying TDLib's numeric `code` and its `message` unchanged. This covers chat, message, contact and group requests, every page of a paged history read, the `getChat` requests inside `getChats` and `searchChats`, the archive's history, message and download requests, and the requests that make an unseen chat known (defined by the `telegram-all-lib` capability). When the code is 406 the request SHALL still fail, with `TDError.tdlibError(code: 406, message: "")`: the caller needs a result it did not get, and the message must not be shown. An error that is not a `TDLibKit.Error` (for example `TDError.sessionClosed` or `TDError.notAuthenticated`) SHALL pass through unchanged.

The MCP server SHALL report such an error from any tool as a JSON content block `{"type": "tdlib_error", "code": <int>, "message": <string>}` with `isError: true`, and the `telegram-all` CLI SHALL print `TDLib error <code>: <message>`. Neither SHALL report a TDLib error as `TDLibKit.Error error <n>` or in any other form that drops the code or the message (PsychQuant/che-msg#71).

#### Scenario: a read reports TDLib's error with its code

- **WHEN** `get_user` is called and TDLib answers the request with `Error{code: 400, message: "User not found"}`
- **THEN** the MCP response has `isError == true` and the content `{"type": "tdlib_error", "code": 400, "message": "User not found"}`

#### Scenario: code 406 from a read is reported without its message

- **WHEN** a page request of `get_chat_history` is answered with `Error{code: 406, message: <any>}`
- **THEN** the client throws `TDError.tdlibError(code: 406, message: "")` and the MCP response is `{"type": "tdlib_error", "code": 406, "message": ""}` with `isError == true`

#### Scenario: a client error passes through

- **WHEN** a chat request is made while TDLib is closing
- **THEN** the client throws `TDError.sessionClosed`, not a `tdlib_error`

#### Scenario: no request bypasses the conversion

- **WHEN** the sources of `TelegramAllLib` are read
- **THEN** every line of code that sends a request through `openClient` either wraps it in the conversion or is one of the four authentication requests

##### Example: conversion per request kind

| Request | TDLibKit.Error | Thrown |
| ------- | -------------- | ------ |
| `getUser` | `code: 400, message: "User not found"` | `tdlibError(code: 400, message: "User not found")` |
| `getChatHistory` page | `code: 429, message: "Too Many Requests: retry after 30"` | `tdlibError(code: 429, message: "Too Many Requests: retry after 30")` |
| `sendMessage` | `code: 406, message: "internal"` | `tdlibError(code: 406, message: "")` |
| `setAuthenticationPhoneNumber` | `code: 406, message: "internal"` | nothing (authentication rule) |

## MODIFIED Requirements

### Requirement: Authentication scope of structured error contract

The requirements "Structured TDLib error propagation", "TDLib error code 406 silent-ignore rule" and "MCP response error serialization" SHALL apply to the authentication methods of the TDLib client: `setParameters`, `sendPhoneNumber`, `sendAuthCode`, and `sendPassword`. Every other request of the client (chat operations, message operations, contact lookups, group management, read state, the archive's requests) SHALL follow "Every TDLib request reports TDLib's code and message", which keeps the code and the message the same way and differs only for code 406: such a request fails with an empty message instead of completing silently.

#### Scenario: chat operation errors follow the general requirement

- **WHEN** `getChats(limit: 50)` throws a TDLib error with code 406
- **THEN** it throws `TDError.tdlibError(code: 406, message: "")`; only the four authentication methods complete silently on code 406
