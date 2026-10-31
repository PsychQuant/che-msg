## Purpose

How che-slack-mcp stores, reads, imports and removes the per-workspace Slack session credentials in the macOS Keychain. It exists so that a credential that is equivalent to the user's signed-in session never passes through MCP tool arguments, the conversation with Claude, environment variables or process arguments.

## ADDED Requirements

### Requirement: Keychain credential layout

All items SHALL use the Keychain account `che-slack-mcp`. The service `SLACK_WORKSPACES` SHALL hold a JSON array of objects with the keys `team_id`, `domain`, `name` and `user_id`, and no credential, stored as the standard base64 encoding (RFC 4648, with padding) of its UTF-8 bytes so that the stored value contains only characters the write path accepts. A missing `SLACK_WORKSPACES` item SHALL be read as an empty list; a value that is not valid base64 or does not decode to such an array SHALL be reported as an error naming `SLACK_WORKSPACES`. For each workspace in that array the service `SLACK_TOKEN_<team_id>` SHALL hold its `xoxc` token and the service `SLACK_COOKIE_<team_id>` SHALL hold its `d` cookie value. Before an import writes any token or cookie, it SHALL check that the merged `SLACK_WORKSPACES` value can be written in a single write as defined by "Keychain write keeps values off argv"; when it cannot, the import SHALL write nothing and stop with an error that gives the number of workspaces, says the index would not fit, and suggests removing workspaces with `slack-all auth remove`.

#### Scenario: Index lists workspaces without credentials

- **WHEN** workspaces `T01` (domain `alpha`) and `T02` (domain `beta`) have been imported
- **THEN** the `SLACK_WORKSPACES` item base64-decodes to a JSON array of two objects with those team ids and domains, and the items `SLACK_TOKEN_T01`, `SLACK_COOKIE_T01`, `SLACK_TOKEN_T02` and `SLACK_COOKIE_T02` exist

#### Scenario: Index that would not fit is refused before any write

- **WHEN** an import would merge 40 workspaces into an index longer than one write accepts
- **THEN** no `SLACK_TOKEN_*`, `SLACK_COOKIE_*` or `SLACK_WORKSPACES` item is created or changed, and the error names 40 and `slack-all auth remove`

### Requirement: Credential lookup is bounded

Reading an item SHALL run `/usr/bin/security find-generic-password -g` with the account `che-slack-mcp`, the item's service name, and the standard input connected to the null device. A lookup still running after 10 seconds SHALL be terminated and reported as timed out. The read value SHALL NOT be cached by the reader. A missing item SHALL be reported as absent, naming the service, not the value.

#### Scenario: Missing token is reported by name

- **WHEN** `SLACK_WORKSPACES` lists `T01` but `SLACK_TOKEN_T01` does not exist
- **THEN** the lookup result is absent and the message names `SLACK_TOKEN_T01`

### Requirement: Keychain write keeps values off argv

Writing an item SHALL start `/usr/bin/security -i` and send the line `add-generic-password -U -a che-slack-mcp -s <service> -w "<value>"` on its standard input, so that the value never appears in any process argument list. Before writing, the value SHALL be checked to contain only the characters `A-Z a-z 0-9 - _ . % + / =`, and the team id inside the service name SHALL be checked to consist of 1 to 32 characters from `A-Z 0-9`; a value or team id that fails its check SHALL be refused with an error naming the service, and nothing SHALL be written.

#### Scenario: Team id with a quote is refused

- **WHEN** a token is about to be written for team id `T01"x`
- **THEN** the write is refused with an error naming the service and no Keychain item is created or changed

#### Scenario: Value with a quote is refused

- **WHEN** a cookie value containing `"` is about to be written for `T01`
- **THEN** the write is refused with an error naming `SLACK_COOKIE_T01` and no Keychain item is created or changed

### Requirement: Clipboard import

`slack-all auth import` SHALL print a one-line browser console command that copies, as JSON, the `id`, `domain`, `name`, `token` and `user_id` of every workspace in `localStorage.localConfig_v2` of `app.slack.com`, wait for the user to press Enter, and read the clipboard. It SHALL then ask the user to copy the `d` cookie value, wait for Enter, and read the clipboard again. For each workspace it SHALL call `auth.test` with that token and cookie, store only the workspaces whose call succeeds, update `SLACK_WORKSPACES`, and print one line per workspace with its name and the result. The update SHALL merge the stored workspaces into `SLACK_WORKSPACES` as read immediately before it is written, not as read when the import started, so that a workspace another import added, or `slack-all auth remove` removed, while this import waited is kept, or stays removed. It SHALL clear the clipboard after the second read. It SHALL NOT print any token or cookie value. When the first clipboard read is not a JSON array of workspace objects, it SHALL stop with an error before asking for the cookie.

#### Scenario: One of two workspaces fails verification

- **WHEN** the clipboard holds workspaces `alpha` and `beta`, the cookie is valid for `alpha`, and `auth.test` for `beta` returns `invalid_auth`
- **THEN** only `alpha` is stored, the output reports `alpha` as imported and `beta` as rejected with `invalid_auth`, and no line contains a token or cookie value

#### Scenario: Index changed while the import waits

- **WHEN** `SLACK_WORKSPACES` lists `gamma` and `delta` when the import starts, and while it waits for the cookie another process removes `gamma` and adds `epsilon`
- **THEN** after `alpha` is imported the index lists `delta`, `epsilon` and `alpha`, and not `gamma`

### Requirement: Desktop import

`slack-all auth import --from-desktop` SHALL look for the Slack desktop app's data under `~/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack` and then under `~/Library/Application Support/Slack`, read the `d` cookie for host `.slack.com` from its `Cookies` database decrypted with the Keychain item `Slack Safe Storage`, read `localConfig_v2` from its `Local Storage/leveldb`, and then verify and store the workspaces exactly as the clipboard import does. Before reading `Slack Safe Storage` it SHALL tell the user to answer the macOS prompt with Allow and not Always Allow. It SHALL read the databases from temporary copies and delete the copies before exiting, whether or not the import succeeded. When neither data folder exists, or the cookie or `localConfig_v2` cannot be read or decrypted, it SHALL stop with an error that names the step that failed and suggests `slack-all auth import`.

#### Scenario: Slack desktop app is not installed

- **WHEN** neither Slack data folder exists
- **THEN** the command exits non-zero with a message saying no Slack desktop data was found and suggesting `slack-all auth import`, and no Keychain item is changed

### Requirement: Workspace removal

`slack-all auth remove <workspace>` SHALL accept a team id or a domain, delete that workspace's `SLACK_TOKEN_<team_id>` and `SLACK_COOKIE_<team_id>` items, and remove its entry from `SLACK_WORKSPACES` as read after those items are deleted, not as read when the command started, so that a workspace another `slack-all` imported or removed meanwhile is kept, or stays removed. A workspace that does not match SHALL produce an error listing the imported workspaces and SHALL change nothing.

#### Scenario: Remove by domain

- **WHEN** `alpha` (`T01`) and `beta` (`T02`) are imported and the user runs `slack-all auth remove alpha`
- **THEN** the `T01` token and cookie items no longer exist, `SLACK_WORKSPACES` lists only `T02`, and the `T02` items are unchanged

#### Scenario: Index changed during removal

- **WHEN** `SLACK_WORKSPACES` lists `alpha` and `beta` when `slack-all auth remove alpha` starts, and another process adds `gamma` while alpha's items are deleted
- **THEN** the index afterwards lists `beta` and `gamma`
