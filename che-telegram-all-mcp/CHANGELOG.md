# Changelog

## [0.2.0] - 2026-02-10

### Added
- Auto-authentication via environment variables (`TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `TELEGRAM_2FA_PASSWORD`)
- New tools: `create_group`, `add_chat_member`

### Changed
- TDLib parameters are now auto-set on startup when env vars are present (no manual `auth_set_parameters` call needed)
- Tool count: 26 → 28

## [0.1.0] - 2026-02-08

### Added
- Initial release with TDLib integration
- Authentication: `auth_set_parameters`, `auth_send_phone`, `auth_send_code`, `auth_send_password`, `auth_status`, `logout`
- User info: `get_me`, `get_user`, `get_contacts`
- Chat operations: `get_chats`, `get_chat`, `search_chats`
- Messages: `get_chat_history`, `send_message`, `edit_message`, `delete_messages`, `forward_messages`, `search_messages`
- Group management: `get_chat_members`, `pin_message`, `unpin_message`, `set_chat_title`, `set_chat_description`
- Read state: `mark_as_read`
