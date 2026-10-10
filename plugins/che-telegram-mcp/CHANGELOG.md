# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> ⚠ This file was bootstrapped by `changelog-tools:changelog-init` from the
> `plugin.json` description field. Section categorization is best-effort —
> review and refine `Added` / `Changed` / `Fixed` etc. as needed.

## [Unreleased]

Ship together with the che-telegram-all-mcp binary that has these changes ([#63](https://github.com/PsychQuant/che-msg/issues/63)); the binary pinned now (0.6.0) still sends a log-out request to Telegram on `logout`.

### Changed
- `telegram-messaging` skill: `auth_status` returns `connection_state`, `unsynced_seconds` and `sync_stalled`; a stalled session is reported to the user, and `logout` (now a local reset) is never called without the user's agreement. After `logout`, the old session is ended in Telegram → Settings → Devices — in that order. Read answers carrying `sync: not-synced` are passed on as possibly stale.
- README: new section "When telegram-all stops syncing".

## [1.5.0] - 2026-10-09

Several Claude Code sessions can enable telegram-all together ([che-msg#58](https://github.com/PsychQuant/che-msg/issues/58)). The wrappers pin binary `DESIRED_VERSION` 0.6.0.

### Changed
- **Behavior change:** the telegram-all wrapper takes no lock and never refuses to start because another session runs telegram-all. It keeps no shared PID file (`~/.cache/che-telegram-all-mcp.pid`) and signals only the binary it started; before, a second wrapper without a lock would have killed the first session's server. The server (binary 0.6.0) now decides who opens TDLib: it opens TDLib on first use, closes it after `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` seconds idle (default 600), and while another session holds it answers the five read tools from TDLib's local cache, marked `source: local-cache`.
- **Behavior change:** the telegram-all wrapper does not run a binary older than 0.6.0 (it asks the binary for `--version`; older binaries do not answer). Before, a failed download kept the previous binary; with this wrapper's lock gone, a 0.5.x binary would open TDLib without coordinating with other sessions.
- When the wrapper stops before starting the server — API credentials missing from the Keychain, no binary to be had, or only a binary older than 0.6.0 — it answers the pending `initialize` request with a JSON-RPC error whose `data.docsUrl` links the README section "When telegram-all does not start", so `/mcp` shows the reason instead of a generic -32000.
- README: "Multiple sessions" replaces "Multi-session limitation", including how sessions still on 1.4.x coexist and how to remove a lock directory left by a killed 1.4.x wrapper. "Manual install" downloads v0.6.0 and records the installed version, so the wrapper does not download it again; "Version" states 1.5.0 and v0.6.0.

### Tests
- `test-wrapper-pid.sh` and `test-wrapper-mcp-error.sh` run the real wrapper against a private HOME (`tests/lib/wrapper_harness.sh`: fake binary, fake `security`, a fake `curl` that never reaches the network) instead of a hand-copied excerpt. They cover a second wrapper leaving the first binary running, a wrapper exit stopping only its own binary, a live `CheTelegramAllMCP` in the old shared PID file left alone, a 1.4.x lock directory not stopping the wrapper, and the three startup errors: missing credentials, no binary, and a binary older than 0.6.0 (kept after a failed download, silent on `--version`, or outside `~/bin`), each with the reason `/mcp` shows.

## [1.4.2] - 2026-10-08

The plugin moved from PsychQuant/psychquant-claude-plugins to PsychQuant/che-msg, which now publishes it as the `che-msg` marketplace ([che-msg#42](https://github.com/PsychQuant/che-msg/issues/42)). No change to the skills, hooks or binaries; the wrappers still pin `DESIRED_VERSION` 0.5.0.

### Changed
- **Behavior change:** the install id is now `che-telegram-mcp@che-msg` (`/plugin marketplace add PsychQuant/che-msg`). psychquant-claude-plugins no longer lists the plugin: once its marketplace is updated, an existing `che-telegram-mcp@psychquant-claude-plugins` install stays installed but stops loading. Observed on Claude Code 2.1.293 with a directory-hosted copy of the old marketplace: the first load after `claude plugin marketplace update` still lists it as enabled and removes its key from `enabledPlugins`; from the next load it is listed as disabled; `claude plugin uninstall` then removes it. No "Removed from the … marketplace" notice appeared in `claude plugin list`, although Claude Code's documentation describes one. The README gives the switch-over steps; uninstall the old copy first, since with both enabled two telegram-all wrappers start and the second is refused by the TDLib lock. Nothing has to be re-entered: binaries, Keychain credentials and the TDLib login live outside the plugin directory.
- The telegram-all wrapper's lock-refused error (`error.data.docsUrl`) links to the README in che-msg.

### Tests
- The plugin's tests moved with it, to `tests/che-telegram-mcp/` in che-msg. New check (j), five rules in `tests/lib/install_refs.py`. It guards against references to the old marketplace left behind by mistake, not against deliberate evasion. The marketplace name M comes from the repository's own `.claude-plugin/marketplace.json`. In every plugin file except the top-level CHANGELOG.md, in the repository README and in marketplace.json, the former marketplace name `psychquant-claude-plugins` may appear only in three listed shapes — an install id after `uninstall`, a link to one of the old repository's issues or pull requests, or the name as a word — so `<owner>/psychquant-claude-plugins` (a `GITHUB_REPO`, a clone URL, a `marketplace add`, a plugin `source`) and any other link into the old repository are reported, whatever surrounds them. Every `che-telegram-mcp@X` in the README is `@che-msg` unless it follows `uninstall`, and the README has `install che-telegram-mcp@che-msg` and `marketplace add …/che-msg` (options allowed; `--scope` takes a value). A file in `bin/` has a docsUrl; each docsUrl is exactly the README URL in its file's `GITHUB_REPO`, and its anchor matches a README heading. Files that are not regular, unreadable or over 2 MB, symlinks to directories and directories that cannot be listed are reported, not skipped. The rules parse no URLs: verify rounds 1–4 each found text that an URL parser read wrongly. The docstring lists what is deliberately not checked. Mutation cases 54 → 144.

## [1.4.1] - 2026-10-08

Documentation corrections found while verifying [#139](https://github.com/PsychQuant/psychquant-claude-plugins/issues/139), which shares this plugin's skill layout ([#138](https://github.com/PsychQuant/psychquant-claude-plugins/issues/138)). No change to the skills, wrappers or binaries; the wrappers still pin `DESIRED_VERSION` 0.5.0.

### Fixed
- The 1.4.0 README and Security note said that "in the default permission mode Claude Code asks before sending" with `send`. On recent Claude Code — every plan and provider since v2.1.284 per the changelog (the permission-modes page says v2.1.283), Pro, Max and Team plans earlier — interactive terminal and VS Code sessions start in auto mode, where a classifier reviews the call and normally nothing is asked, so most readers would have drawn the opposite conclusion. The README now names the modes as Claude Code does — Manual (config value `default`) and `acceptEdits` ask unless an allow rule matches; auto lets the classifier decide, and a matching allow rule skips the classifier; `bypassPermissions` does not ask; `dontAsk` refuses the call unless an allow rule matches — and recommends ask rules as the one setting that asks in any mode (in `dontAsk`, an ask rule refuses instead), unless a `PermissionRequest` hook or a mod approves the call: for `send_message` on both servers, since `send` does not tie itself to one, and for every other tool that sends or changes something, listed per server; or a whole-server ask rule.
- The bare-name note no longer says that `search` and `send` collide with other plugins: whether a name collides depends on what else is installed. As in 1.4.0, the bare `/auth` and the others work while no other command or skill uses the name (the 1.3.2 commands set `name` too).

### Tests
- `tests/che-telegram-mcp/test-plugin-layout.sh` (marketplace repo) now reads skill frontmatter the way Claude Code does, or refuses to. The shared `tests/lib/frontmatter_subset.py` finds the boundary as Claude Code does (the first `---` after the opening line, even inside a value, with JavaScript's whitespace class and no newline translation) and rejects a block outside the plain YAML in which PyYAML (YAML 1.1, used by the test) and Bun.YAML (YAML 1.2, used by Claude Code) read the same thing: control or line-separator characters such as NEL or U+2028, a quoted value left open on its line, `---` or `...` anywhere (bun 1.3.11 treats both as document markers even inside a value; Bun 1.4.2 does not, and the Bun 1.4.3 inside Claude Code 2.1.293 has not been tested; the ban is kept because it only rejects more), anchors, aliases, tags, block scalars, flow collections, explicit or duplicate keys. Such a block is not parsed at all; the checks that need its values fail as unverifiable. Outside that subset Claude Code could drop or rewrite `disable-model-invocation` while the test passed. `tests/frontmatter-subset-fuzz/run.sh` (needs bun) compares PyYAML with Bun.YAML on random blocks the subset accepts; its latest run (bun 1.3.11, two seeds × 50,000 blocks, 4,568 accepted) found no failed first parse and no structural, string or numeric disagreement. That is evidence for its generator, not a proof: verify round 5 of #139 found values starting with `:`, YAML 1.1 boolean keys and leading-zero numbers it had never generated; all three are now generated and rejected.
- Check (h) accepts only an unquoted `true` (YAML's `True`/`TRUE` spellings read the same) for the four slash skills, since Claude Code before 2.1.218 recognises nothing else; check (g) accepts only an absent key or the literal `false` on the router, in both the typed and the string view, since Claude Code also reads yes/on/1 and numbers such as `1.0` as true. New check (i): no skill registers `hooks` (they outlast the turn's grant) or has a `` !`command` `` / ```` ```! ```` block (it runs when the skill is invoked, before Claude reads it).
- Mutation cases 31 → 54; the 1.4.0 test misses 18 of the 22 new failure cases.

## [1.4.0] - 2026-10-06

Plugin-shell upgrade to the current `harness-devtools:plugin-upgrade` baseline and the official plugin reference ([#138](https://github.com/PsychQuant/psychquant-claude-plugins/issues/138), parent PsychQuant/che-msg#39). No binary change — the wrappers still pin `DESIRED_VERSION` 0.5.0.

### Changed
- **Behavior change:** `commands/{auth,chats,search,send}.md` are now skills (`skills/<name>/SKILL.md`), invoked as `/che-telegram-mcp:<name>` (the bare `/auth` still works while no other command uses the name). They set `disable-model-invocation: true`, so Claude no longer invokes them on its own — up to 1.3.2 these were commands that Claude could also load by itself. The same setting also stops scheduled tasks whose prompt is one of these skills, and subagent skill preloads, from running them. Natural-language requests go through `telegram-messaging`, which stays model-invocable.
- The wrapper tests (`test-wrapper-mcp-error.sh`, `test-wrapper-pid.sh`) moved out of the shipped plugin to `tests/che-telegram-mcp/` in the marketplace repo, so only the two wrappers remain in `bin/` and on the Bash tool's `PATH`.
- The wrappers themselves stay in `bin/`, because the harness-devtools release tooling finds them only there: `plugin-binary-meta.sh` (used by `plugin-update`) scans `bin/` and `hooks/`, and `plugin-deploy`'s release gate globs `bin/*wrapper.sh`. A move to `scripts/` was tried while preparing this release and reverted, because it made the `DESIRED_VERSION` pin detection and that gate silently stop working. A consequence is that the plugin still has `bin/`, so claude.ai and Cowork will not install it — which does not cost anything here, since both servers need a local TDLib binary and Keychain.
- `plugin.json` description now states the real tool counts (telegram-all 28, telegram-bot 31) instead of "28+".

### Fixed
- `allowed-tools` in the four entry points named `mcp__che-telegram-mcp__*`, which matches no tool, so the pre-approval never applied. They now use `mcp__plugin_che-telegram-mcp_telegram-all__*`.
- SessionStart hook command quotes `${CLAUDE_PLUGIN_ROOT}` (the only `claude plugin validate` warning).

### Security
- **Net effect is a widening for `auth`, `chats` and `search`:** before, nothing was pre-approved (the names were wrong); now each skill pre-approves the tools it lists, but only for the turn in which it is invoked — the grant clears when the user sends the next message. For `auth` the list includes the credential-entry tools `auth_set_parameters`, `auth_send_phone`, `auth_send_code` and `auth_send_password`; in practice the later steps happen after the user has replied with a phone number or code, so they usually go through the normal permission settings anyway. The marketplace-repo test `tests/che-telegram-mcp/test-plugin-layout.sh` keeps this list on an explicit read-only allowlist (login steps only in `auth`).
- `send` deliberately does not pre-approve `send_message`, because a sent message cannot be recalled. That leaves `send_message` under the user's normal permission settings: in the default permission mode Claude Code asks before sending; in `bypassPermissions` or auto mode, or with an allow rule for the tool, it does not, and the skill's instruction to confirm the recipient and text first is the only remaining guard.

## [1.3.2] - 2026-05-22

### Fixed
- `che-telegram-all-mcp-wrapper.sh`: lock-refused branch now emits a JSON-RPC 2.0 error envelope to stdout before exiting, so Claude Code's MCP client parses the human-readable message + structured data instead of seeing only `-32000 Server error`. Envelope carries:
  - `error.code: -32000` (JSON-RPC server-defined errors range)
  - `error.message: "Another instance of CheTelegramAllMCP is already running (lock held by PID NNNN). Use the existing Claude Code window, or kill the previous wrapper first."`
  - `error.data.lockHolderPid: <pid>` (machine-readable lock holder)
  - `error.data.recoveryCommand: "pkill CheTelegramAllMCP 2>/dev/null; rm -rf ~/.cache/che-telegram-all-mcp.lock ~/.cache/che-telegram-all-mcp.lock.flock"` (semicolon, not `&&`, so cleanup runs even when no process exists)
  - `error.data.docsUrl: https://.../README.md#multi-session-limitation`

  The original stderr message is retained for direct-shell debug.

  **PR-1b id matching (added 2026-05-22 after empirical verification)**: wrapper reads the first line of stdin (with 2s timeout) to extract the JSON-RPC `initialize` request's `id` field, then emits the response envelope with **matching id**. This was required because empirical two-session reproduction in Claude Code v2.1.148 showed that `id: null` responses (the v1.3.2 first attempt) are not matched to pending `initialize` requests and don't surface in Claude Code's MCP error state. With matching-id (PR-1b), debug-log capture confirmed Claude Code's MCP client correctly parses the envelope + stores the full `error.message` internally.

  Stdin extraction uses `jq` when available (preferred) and a bash regex fallback for environments without jq. Handles MCP 1.0 spec id forms: integer, quoted string, or null.

  New `test-wrapper-mcp-error.sh` covers 6 cases: happy path / lock refused emits valid JSON / stale-lock self-recovery / recoveryCommand validation / id-matching with initialize request / timeout fallback to null. Resolves [#31](https://github.com/PsychQuant/che-msg/issues/31).

  **Known UX gap** (out of plugin scope): Claude Code's `/mcp` short-list UI may display only `-32000` (truncated form) instead of the full message. The full message IS captured in Claude Code's internal MCP error state (verified via `--debug mcp` debug logs) and is available to downstream tool consumers. The display truncation is a Claude Code UI policy concern, not a plugin issue.

### Documentation
- `README.md`: added `## Multi-session limitation` section explaining the TDLib single-instance constraint, the v1.3.2+ human-readable error message, and a recovery cookbook (`pkill CheTelegramAllMCP 2>/dev/null; rm -rf ~/.cache/che-telegram-all-mcp.lock ~/.cache/che-telegram-all-mcp.lock.flock`). Documents the pre-v1.3.2 generic `-32000` symptom for users upgrading.

## [1.3.1] - 2026-05-07

### Fixed
- `che-telegram-all-mcp-wrapper.sh`: add atomic-claim lock (flock with mkdir fallback) before PID-tracking section. Prevents the multi-window race where window B reads window A's PID, sees an alive `CheTelegramAllMCP` process, sends SIGTERM and unannouncedly kills window A's MCP server. Lock is portable: uses `flock -n` when available (Linux / macOS Sequoia+ if shipped), falls back to atomic `mkdir` directory-claim on systems without flock (verified macOS 26.4.1). Stale-lock cleanup removes orphaned locks whose owner PID is dead. Failure mode is now fail-fast with clear stderr message instead of silent SIGTERM cross-fire. `che-telegram-bot-mcp-wrapper.sh` deliberately unchanged — bot HTTPS API is stateless, multi-instance safe. New regression test (`test-wrapper-pid.sh` test 9) verifies second instance fail-fast + first instance survival. Resolves #10.

## [1.3.0] - (date unknown — please fill in)

### Changed
- Telegram MCP Server Plugin — Bot API + 個人帳號 TDLib 全功能存取，28+ 工具，Keychain 密鑰管理
