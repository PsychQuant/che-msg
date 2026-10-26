# Changelog

## [Unreleased]

### Changed
- The README's installation section recommends the plugin, and for a server run on its own reads `TELEGRAM_BOT_TOKEN` from the Keychain at launch (a `claude mcp add … /bin/sh -c` example); it says that a token in the environment is readable by other processes of the same user and that a token in `~/.claude.json` sits there in plain text ([#97](https://github.com/PsychQuant/che-msg/issues/97)).

### Distribution
- Starting with this release, the binary is signed with a Developer ID and notarized by Apple, and every release asset comes with a `.sha256` file holding its SHA-256 hash ([#40](https://github.com/PsychQuant/che-msg/issues/40)). The releases are built by `make release-signed` ([RELEASING.md](../RELEASING.md)). Releases up to `v0.8.0` stay as they were: ad-hoc signed, without `.sha256` files.
- `Package.resolved` is tracked, and the release build uses exactly the dependency versions it records (`--force-resolved-versions`), so a tag reproduces its binaries' dependencies ([#92](https://github.com/PsychQuant/che-msg/issues/92)). They are the versions the maintainer's checkout has resolved since 2026-04-12 (swift-sdk 0.12.0, swift-argument-parser 1.7.1), so most likely the ones the releases from then to `v0.8.0` were built with; a fresh clone used to resolve newer ones.
- The release build stays tied to the commit it prints until its files are written ([#94](https://github.com/PsychQuant/che-msg/issues/94)): the `.mcpb` bundles are packed from that commit, and `.build/dist/vX/` appears only if HEAD is still that commit and the tree still clean at the end. It also refuses a symlink tracked anywhere in a package and an untracked or ignored file in a package's `Sources` or `Package*.swift`, and runs the signed telegram-all binary once (`--version`).

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
