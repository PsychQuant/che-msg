# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The first version, 0.1.0 (`plugin.json` and the `che-msg` marketplace entry already say 0.1.0). The wrapper pins `CheSlackMCP` 0.9.0 (`DESIRED_VERSION`), which ships with the che-msg release v0.9.0 ([#99](https://github.com/PsychQuant/che-msg/issues/99)).

### Added
- MCP server `slack` (`CheSlackMCP`): nine tools — `list_workspaces`, `auth_status`, `list_conversations`, `get_conversation_history`, `get_thread_replies`, `get_user`, `search_messages`, `send_message`, `archive_conversation_to_markdown` — across every imported workspace, chosen with an optional `workspace` argument (team id or domain).
- Wrapper `bin/che-slack-mcp-wrapper.sh`: downloads the asset `CheSlackMCP` of the pinned release only (never `releases/latest`), records it in `~/bin/.CheSlackMCP.version`, keeps the existing binary when an upgrade download fails, never replaces a source build, and treats an HTTP error as a failed download. It reads no Keychain item and exports no variable; with no binary to start it answers `initialize` with a JSON-RPC error linking the README section "When slack does not start".
- README: installing from the `che-msg` marketplace, building `slack-all` from source, both imports (`slack-all auth import`, `slack-all auth import --from-desktop`: only workspaces signed in to the desktop app; click Allow, not Always Allow), `auth status` and `auth remove`, the tool list, a pre-approval table that leaves out `send_message` and `archive_conversation_to_markdown`, ask rules for both and what each permission mode does without them, the archive layout, and the risks: the session token is your signed-in session, Enterprise Grid, request pacing (`SLACK_MCP_MIN_INTERVAL_MS`, `SLACK_MCP_MAX_CONCURRENCY`), Slack's API Terms, and no file downloads.

### Tests
- `tests/che-slack-mcp/test-wrapper.sh` runs the real wrapper in an empty environment against a private HOME with a fake binary, `security` and `curl`: the binary gets the client's stdin, no Slack credential in its environment and the pacing overrides unchanged; `security` is never called; the download, upgrade, kept-binary, source-build and startup-error paths; only the pinned release is asked for.
- `tests/che-slack-mcp/test-plugin-layout.sh` checks what `claude plugin validate` does not: one server named `slack` (the README's rules depend on it), the pin equal to the version the server and `slack-all` report, plugin and marketplace versions, the README's tool table against the tools the server registers, the pre-approval table and permission examples, no skill pre-approving the two tools, the README's required notes, no home path, e-mail address or token-shaped string in the public files, install references (`tests/lib/install_refs.py`), and a wrapper that calls no `security` and exports nothing. `test-plugin-layout-mutations.sh` breaks each of these once and checks the right check fails.
