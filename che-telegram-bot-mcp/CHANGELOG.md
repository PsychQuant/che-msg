# Changelog

## [Unreleased]

### Distribution
- Starting with this release, the binary is signed with a Developer ID and notarized by Apple, and every release asset comes with a `.sha256` file holding its SHA-256 hash ([#40](https://github.com/PsychQuant/che-msg/issues/40)). The releases are built by `make release-signed` ([RELEASING.md](../RELEASING.md)). Releases up to `v0.8.0` stay as they were: ad-hoc signed, without `.sha256` files.

## [0.8.0] - 2026-10-14

### Changed
- Reports the shared release version `0.8.0`; the bot itself is unchanged (this release adds telegram-all's archive tools).

## [0.7.0] - 2026-10-10

The bot has no sections between `[0.1.0]` and this one: it was published in the repo's shared releases up to `v0.6.0` while still reporting `0.1.0`. From this release on it uses the shared version number.

### Fixed
- The mcpb manifest and the version the MCP server reports said `0.1.0`, although the bot ships in the repo's shared releases (latest `v0.6.0`). Both now say the release version (`0.7.0`); the bot itself is unchanged.

## [0.1.0] - 2026-02-07

### Added
- Initial release
- Bot info: `get_me`
- Messages: `send_message`, `forward_message`, `copy_message`, `edit_message_text`, `delete_message`
- Updates: `get_updates`
- Chat management: `get_chat`, `get_chat_member_count`, `get_chat_member`, `get_chat_administrators`
- Member management: `ban_chat_member`, `unban_chat_member`, `restrict_chat_member`, `promote_chat_member`
- Pin/unpin: `pin_chat_message`, `unpin_chat_message`, `unpin_all_chat_messages`
- Media: `send_photo`, `send_document`, `send_video`, `send_audio`, `send_location`, `send_poll`, `send_sticker`
- Bot commands: `set_my_commands`, `get_my_commands`, `delete_my_commands`
- Chat settings: `set_chat_title`, `set_chat_description`, `leave_chat`
