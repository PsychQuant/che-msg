# Changelog

## [Unreleased]

The first version. The server (`serverInfo.version`) and `slack-all --version` report 0.9.0; it ships with the che-msg release v0.9.0 ([#99](https://github.com/PsychQuant/che-msg/issues/99)).

### Added
- `SlackWebLib`, a Slack Web API client that depends only on Foundation. It authenticates with a browser session (a `xoxc-` token in the form, the `d` cookie in the `Cookie` header), sorts every failure into five classes (session invalid, rate limited, Enterprise Grid restricted, other Slack error, network error), retries a rate-limited call after `Retry-After` up to 3 times, and paces each workspace: 350 ms between request starts and 3 requests in flight by default, overridable with `SLACK_MCP_MIN_INTERVAL_MS` (0–60000) and `SLACK_MCP_MAX_CONCURRENCY` (1–10). No description, error or log it produces holds a credential.
- Keychain storage under the account `che-slack-mcp`: the index `SLACK_WORKSPACES`, and `SLACK_TOKEN_<TEAM_ID>` and `SLACK_COOKIE_<TEAM_ID>` per workspace. Values are read through `security find-generic-password` with a 10 s timeout and written through `security -i` on stdin, never on the command line.
- `slack-all auth import` (the browser console copies every signed-in workspace, then the `d` cookie; the clipboard is cleared), `slack-all auth import --from-desktop` (reads the Slack desktop app's cookie and Local Storage from temporary copies and decrypts the cookie with "Slack Safe Storage"), `slack-all auth status` and `slack-all auth remove <workspace>`.
- MCP server `CheSlackMCP` with nine tools for every imported workspace: `list_workspaces`, `auth_status`, `list_conversations`, `get_conversation_history`, `get_thread_replies`, `get_user`, `search_messages`, `send_message` and `archive_conversation_to_markdown`. Errors are tool results with `isError: true`.
- `archive_conversation_to_markdown`: one markdown file per local day in the che-telegram-mcp archive layout, merged by `ts` on re-runs, a `manifest.json` without message content, thread replies re-fetched for parents in the last `thread_lookback_days` days (default 30), attachments written as links and never downloaded, one archive per conversation and output directory at a time, and a rate limit that stops the run without moving the bookmark.
