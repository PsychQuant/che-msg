## MODIFIED Requirements

### Requirement: Tool routing while TDLib is held by another process

While another process holds TDLib, the server SHALL route each tool as follows: `get_chats`, `search_chats`, `get_chat_history`, `search_messages` and `dump_chat_to_markdown` SHALL be answered by the local reader; `archive_chat_to_markdown` SHALL write its day files from the local reader's messages as the `telegram-chat-archive` capability defines, reporting `source: "local-cache"` and `bookmark_safe: false`; `download_message_media` SHALL return a `tdlib_in_use` error because the local cache holds no media files; `get_me`, `get_user`, `get_contacts`, `get_chat` and `get_chat_members` SHALL return a `local_reader_unsupported` error; every other tool, including `send_message`, `auth_run` and `logout`, SHALL return a `tdlib_in_use` error. Each error SHALL be an MCP tool result with `isError: true` whose single content item is a JSON object with a `type` field.

#### Scenario: Write tool while TDLib is held elsewhere

- **WHEN** `send_message` is called while process 4242 holds TDLib
- **THEN** the result has `isError: true` and content `{"type":"tdlib_in_use","lock_holder_pid":4242,"message":...}`

#### Scenario: Unsupported read tool while TDLib is held elsewhere

- **WHEN** `get_user` is called while another process holds TDLib
- **THEN** the result has `isError: true` and content `{"type":"local_reader_unsupported","tool":"get_user","message":...}`

#### Scenario: Supported read tool while TDLib is held elsewhere

- **WHEN** `get_chat_history` is called while another process holds TDLib
- **THEN** the local reader answers the call and no TDLib client is created in the server process

#### Scenario: Archive tool while TDLib is held elsewhere

- **WHEN** `archive_chat_to_markdown` is called while another process holds TDLib
- **THEN** day files are written from the local reader's messages, the manifest reports `source: "local-cache"` and `bookmark_safe: false`, and no TDLib client is created in the server process

##### Example: routing table

| Tool | TDLib free | TDLib held elsewhere |
| ---- | ---------- | -------------------- |
| `get_chats` | TDLib | local reader |
| `search_chats` | TDLib | local reader |
| `get_chat_history` | TDLib | local reader |
| `search_messages` | TDLib | local reader |
| `dump_chat_to_markdown` | TDLib | local reader |
| `archive_chat_to_markdown` | TDLib | local reader (`bookmark_safe: false`) |
| `download_message_media` | TDLib | `tdlib_in_use` |
| `get_me`, `get_user`, `get_contacts`, `get_chat`, `get_chat_members` | TDLib | `local_reader_unsupported` |
| `send_message`, `edit_message`, `delete_messages`, `forward_messages`, `pin_message`, `unpin_message`, `set_chat_title`, `set_chat_description`, `mark_as_read`, `create_group`, `add_chat_member` | TDLib | `tdlib_in_use` |
| `auth_set_parameters`, `auth_send_phone`, `auth_send_code`, `auth_send_password`, `auth_status`, `auth_run`, `logout` | TDLib | `tdlib_in_use` |
