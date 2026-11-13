# Language

Canonical terms for specs, code, docs and tool text in this repository. Use the term in the first column; the "Avoid" column lists words that have been used for the same thing and should not be.

## Slack

| Term | Means | Identifier | Avoid |
|------|-------|------------|-------|
| workspace | One Slack workspace the user is signed in to (Slack's API calls it a team) | team id, e.g. `T0123ABCD`; also its domain, e.g. `myteam` for myteam.slack.com | "team" in prose (keep it only in API names such as `team_id`), "server", "org" |
| conversation | Anything messages are posted in: a public channel, a private channel, a direct message (DM) or a group DM | conversation id, e.g. `C0123ABCD` (`D…` for a DM, `G…` for some private channels and group DMs) | "chat" for Slack, "channel" when a DM or group DM may be meant, "room" |
| session token | The pair that signs requests in as the user: the `xoxc-` token from the browser's or desktop app's local storage, plus the `d` cookie (`xoxd-…`). One pair per workspace | Keychain services `SLACK_TOKEN_<TEAM_ID>` and `SLACK_COOKIE_<TEAM_ID>` | "API token", "bot token", "OAuth token" (those are `xoxb-` and `xoxp-`, which this server does not use), "password" |
| message ts | A message's Slack timestamp, unique within its conversation; the archive's anchor and bookmark | e.g. `1730000000.000100`, always written as a string | "message id" for Slack |
| thread parent | A top-level message with replies; replies carry its ts as `thread_ts` | its ts | "root message" |

## Telegram and Slack

| Telegram | Slack | Note |
|----------|-------|------|
| chat (`chat_id`) | conversation (`conversation_id`) | Both cover groups and one-to-one chats. Say "chat" only for Telegram and "conversation" only for Slack; in text about both, name both. |
| — | workspace (`team_id`) | Telegram has no level above the chat; a Slack archive path has one more directory, `<team_id>/<conversation_id>/`. |
| message id (`message_id`, bookmark `after_message_id`) | message ts (`ts`, bookmark `after_ts`) | Same role in the archive: the `<!-- msg:… -->` anchor and the bookmark. |
| API id and hash, then a TDLib login | session token | Both live only in the Keychain. Telegram's identify the app and are followed by a login; Slack's session token is the login itself. |
