## Purpose

The MCP tools that che-slack-mcp exposes to Claude for acting as the signed-in user across every imported Slack workspace: listing workspaces and conversations, reading history and threads, searching, looking up users and sending messages. It exists so that one server process covers all of the user's workspaces with one consistent workspace-selection rule.

## ADDED Requirements

### Requirement: Workspace selection

Every tool except `list_workspaces` SHALL accept an optional string argument `workspace` matched case-insensitively and exactly against the team id and the domain of each imported workspace. When exactly one workspace is imported the argument SHALL be optional, and that workspace SHALL be used when it is omitted. When the argument is omitted while two or more are imported, or when it matches no imported workspace, the tool SHALL return a result with `isError: true` whose message lists every imported team id with its domain, and SHALL NOT call Slack. When no workspace is imported, every tool except `list_workspaces` SHALL return `isError: true` telling the user to run `slack-all auth import` or `slack-all auth import --from-desktop`.

#### Scenario: Ambiguous call is refused

- **WHEN** `alpha` (`T01`) and `beta` (`T02`) are imported and `get_conversation_history` is called without `workspace`
- **THEN** the result has `isError: true`, lists `T01 alpha` and `T02 beta`, and no request is sent to Slack

##### Example: selection outcomes

| Imported | `workspace` argument | Outcome |
| --- | --- | --- |
| `T01 alpha` | (omitted) | uses `T01` |
| `T01 alpha`, `T02 beta` | `BETA` | uses `T02` |
| `T01 alpha`, `T02 beta` | `t01` | uses `T01` |
| `T01 alpha`, `T02 beta` | `gamma` | error listing both |
| (none) | (omitted) | error suggesting `slack-all auth import` |

### Requirement: Workspace and session tools

`list_workspaces` SHALL return each imported workspace's team id, domain and name without calling Slack. `auth_status` SHALL call `auth.test` for the selected workspace, or for every imported workspace when `workspace` is omitted, and SHALL report per workspace whether the session is valid and, when it is not, the error class from the client.

#### Scenario: Expired session is reported per workspace

- **WHEN** `auth_status` is called without `workspace`, `alpha` answers `auth.test` successfully and `beta` answers `invalid_auth`
- **THEN** the result reports `alpha` as valid and `beta` as `sessionInvalid`, and is not an error result

### Requirement: Conversation read tools

`list_conversations` SHALL return the conversations the user is a member of, covering public channels, private channels, direct messages and group direct messages, each with its id, type and name (for a direct message, the other user's display name). `get_conversation_history` SHALL take a required `conversation_id` and optional `limit` (1 to 200, default 50), `oldest` and `latest` timestamps, and return messages newest first with `ts`, sender, text and, for a thread parent, `reply_count`. `get_thread_replies` SHALL take a required `conversation_id` and `thread_ts` and return the parent followed by its replies oldest first. `get_user` SHALL take a required `user_id` and return the user's display name, real name and whether the account is a bot. An argument outside its allowed form or range SHALL produce `isError: true` naming the argument, without calling Slack.

#### Scenario: Limit out of range is refused

- **WHEN** `get_conversation_history` is called with `limit` 500
- **THEN** the result has `isError: true`, names `limit`, and no request is sent to Slack

### Requirement: Message search

`search_messages` SHALL take a required non-empty `query` and an optional `count` (1 to 100, default 20), pass the query unchanged to Slack's `search.messages` so that Slack modifiers such as `in:#general` and `from:@name` keep working, and return each match's conversation id, conversation name, `ts`, sender, text and permalink.

#### Scenario: Empty query is refused

- **WHEN** `search_messages` is called with `query` consisting only of spaces
- **THEN** the result has `isError: true`, names `query`, and no request is sent to Slack

### Requirement: Send message

`send_message` SHALL take a required `conversation_id`, a required non-empty `text` of at most 40000 characters and an optional `thread_ts`, post the message as the user with `chat.postMessage`, and return the new message's `ts` and conversation id. When `thread_ts` is given the message SHALL be posted as a reply in that thread. When the call fails in a way after which the message may still have been posted — a network error, an answer that is not the expected JSON, an HTTP status other than 200 and 429 (a rate limit, which Slack answers without posting), or Slack's `internal_error` or `fatal_error` — the error result SHALL say that the message may have been posted, and tell the caller to check the conversation before sending again.

#### Scenario: Reply in a thread

- **WHEN** `send_message` is called with `conversation_id` `C01`, `text` `收到`, and `thread_ts` `1730000000.000100`
- **THEN** `chat.postMessage` is called with `channel=C01`, `text=收到` and `thread_ts=1730000000.000100`, and the result returns the new `ts`

#### Scenario: internal_error may have posted

- **WHEN** `chat.postMessage` answers `{"ok": false, "error": "internal_error"}`
- **THEN** the result has `isError: true` and says the message may have been posted, and tells the caller to check the conversation before sending again

### Requirement: Tool error results

Any failure from the Slack client SHALL be returned as a tool result with `isError: true`, never as a JSON-RPC protocol error. A `sessionInvalid` result SHALL name the workspace and include both `slack-all auth import` and `slack-all auth import --from-desktop`. An `enterpriseRestricted` result SHALL say that Enterprise Grid can end automated sessions and suggest Slack's official MCP server. No tool result SHALL contain a token or cookie value.

#### Scenario: Session expired during a read

- **WHEN** `get_conversation_history` for `beta` receives `invalid_auth`
- **THEN** the result has `isError: true`, names `beta`, and includes the commands `slack-all auth import` and `slack-all auth import --from-desktop`
