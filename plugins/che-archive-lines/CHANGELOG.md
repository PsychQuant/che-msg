# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> ⚠ This file was bootstrapped by `changelog-tools:changelog-init` from the
> `plugin.json` description field. Section categorization is best-effort —
> review and refine `Added` / `Changed` / `Fixed` etc. as needed.

## [Unreleased]

## [1.1.1] - 2026-10-08

The plugin moved from PsychQuant/psychquant-claude-plugins to PsychQuant/che-msg, which now publishes it as the `che-msg` marketplace ([che-msg#42](https://github.com/PsychQuant/che-msg/issues/42)). No change to the skill or `scripts/line-save-chat.sh`.

### Changed
- **Behavior change:** the install id is now `che-archive-lines@che-msg` (`/plugin marketplace add PsychQuant/che-msg`). psychquant-claude-plugins no longer lists the plugin: once its marketplace is updated, an existing `che-archive-lines@psychquant-claude-plugins` install is dropped from `enabledPlugins` and reported as removed. The README gives the switch-over steps. The calibration in `~/.config/che-archive-lines/config.json` is kept.

### Tests
- The plugin's tests moved with it, to `tests/che-archive-lines/` in che-msg. New check (j): the README's install ids and `marketplace add` must name the marketplace in the repository's own `.claude-plugin/marketplace.json`; a README that is not UTF-8 makes (j) unverifiable instead of crashing the test (`tests/lib/install_refs.py`). Mutation cases 60 → 68.

## [1.1.0] - 2026-10-08

Plugin-shell upgrade to the current `harness-devtools:plugin-upgrade` baseline and the official plugin reference ([#139](https://github.com/PsychQuant/psychquant-claude-plugins/issues/139), parent PsychQuant/che-msg#39). `scripts/line-save-chat.sh` changes only in how it reads, checks and writes the values it does arithmetic on, and in its calibration prompt ([#149](https://github.com/PsychQuant/psychquant-claude-plugins/issues/149); see Security).

### Changed
- **Behavior change:** `commands/archive-lines.md` is now `skills/archive-lines/SKILL.md`, invoked as `/che-archive-lines:archive-lines`. It sets `disable-model-invocation: true`, so Claude no longer starts this GUI automation on its own; scheduled tasks whose prompt is this skill, and subagent skill preloads, no longer run it either.
- **Behavior change:** `calibrate` is no longer run by Claude. Calibration waits for the user to press Enter in a terminal, and the Bash tool has none: running it there exits at that prompt, and piping two or more lines in would record wherever the mouse happens to be, overwriting a good calibration (an empty second line stores the default menu offset, 240) ([#145](https://github.com/PsychQuant/psychquant-claude-plugins/issues/145)). The skill now shows the full command for the user to run in their own terminal. Because the script first brings LINE to the front, keystrokes then go to LINE — pressing Enter there can send a draft — so the README and the skill say to switch back to the terminal with Cmd-Tab before pressing Enter.
- The skill only ever passes one of the four literal verbs (`calibrate`, `save`, `test`, `help`) to the script; any other argument is answered with the list of verbs, and an empty one means `help`.

### Fixed
- The script path is now `${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh`, which Claude Code substitutes with the installed plugin location. Before, the command derived it with `$(dirname "$(dirname "$0")")`, but in command and skill content `$0` is the first argument (`save`, `test`, …), so this resolved to `.`, the user's working directory. It also listed a fixed install location under `~/.claude/plugins/` (marketplace installs live in the plugin cache instead) and ran `./scripts/line-save-chat.sh` relative to the user's project directory.
- The bare `/archive-lines` now works while no other command uses the name: the skill sets `name: archive-lines`, and a plugin skill gets its bare alias only from that field. In 1.0.0 only the namespaced form worked, although the repository's CLAUDE.md documented the bare one.
- README install instructions use the marketplace name (`che-archive-lines@psychquant-claude-plugins`) and no longer describe copying the plugin into `~/.claude/plugins/`.

### Security
- `allowed-tools` narrowed from `Bash(*), Read, Write, Glob` to three exact rules: `Bash(${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh save)`, `… test)` and `… help)`. Before, any shell command and any file write ran without a prompt in the turn the command was invoked. Now only those three commands do, in the turn the skill is invoked, unless the user's own deny or ask rules or managed settings say otherwise; `calibrate`, any other argument and any other command go through the user's normal permission settings. The grant clears when the user sends the next message. `Read`, `Write` and `Glob` are no longer pre-approved.
- Exact rules rather than a trailing `*`: Claude Code matches a rule against each subcommand of a pipeline or chain, and read-only commands such as `printf` need no approval, so `Bash(${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh *)` would also pre-approve `calibrate`, including `printf '\n\n' | … calibrate`. A grant cannot be tied to the verb the user typed: in the invoking turn all three commands run unprompted whichever verb was given, and after that turn the script goes through the user's normal permission settings again (in auto mode the classifier decides).
- Checked with `claude -p --plugin-dir` probes on Claude Code 2.1.291 (`--permission-mode default --setting-sources project`, execution detected by marker files written by a stand-in script, with this skill's `allowed-tools` block copied verbatim): `"…" help` ran; `"…" calibrate`, `printf '\n\n' | "…" calibrate`, `"…" save; touch …` and `"…" calibrate2` were denied and nothing ran. `printf 'x\n' | "…" save` ran — piped input does reach the script — but only `calibrate` reads stdin, and it is not pre-approved.
- `scripts/line-save-chat.sh` now accepts only integers for every value that reaches shell arithmetic ([#149](https://github.com/PsychQuant/psychquant-claude-plugins/issues/149)): the three config values, the LINE window position and size from `osascript`, and the cursor position from `cliclick`. bash evaluates array subscripts inside `$((…))`, so a value such as `a[$(command)]` ran that command — from the config, on every `save` or `test`, the pre-approved ones included. An accepted value has at most six digits, an optional minus and no leading zero (bash reads `010` as octal). `load_config` stops with an error on any other value, including a `menu_offset_y` key whose value it cannot read. **Behavior change:** a config without that key now uses 240; 1.0.0 added 0 there, so its second click re-clicked ⋮ (every 1.0.0 calibration wrote the key, so only hand-edited configs are affected). When LINE is not running, not installed or has no window, `save`, `test` and `calibrate` now say so (「無法取得 LINE 視窗資訊」); before, osascript's failure ended the script silently under `set -e`, and the existing empty-window checks never ran. `save_config` refuses to write a non-integer, and `calibrate` rejects one as the menu offset; its prompt now asks for pixels below ⋮ rather than an item number. A config with a bad value is reported as such, no longer as "not calibrated". The old reading was not a defence: `grep` stopped at the first `,` or `}`, `cut` at the next `:`, and `tr` deleted spaces, so only a payload containing one of those characters was cut short. Covered by `tests/che-archive-lines/test-config-validation.sh` (29 cases, including an `osascript` stub that fails the way the real one does when LINE has no window, run through the script's own `/bin/bash`, with a positive control that the payload really runs there, with stub `cliclick` and `osascript` on `PATH` and a scratch `HOME`).

### Removed
- A hard-coded absolute path to one machine's cloud-sync folder in the command file (this repository is public).

### Docs
- README notes that LINE's local message database (`.edb`) is encrypted; the readable source is the "Save chat" `.txt` export. A LINE MCP that reads those exports is tracked in PsychQuant/che-msg#41.

## [1.0.0] - (date unknown — please fill in)

### Changed
- 歸檔 LINE macOS 聊天記錄到文字檔
