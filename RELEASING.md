# Releasing

How a binary release of `che-telegram-all-mcp` and `che-telegram-bot-mcp` is cut. Both binaries share one version number. Releases are built on the maintainer's Mac, because the Developer ID signing identity and the notarytool profile live in that Mac's Keychain ([#40](https://github.com/PsychQuant/che-msg/issues/40)).

## Rules

- **A released version is never published again.** The plugin's wrappers download a binary only when the pinned version changes, so a re-signed `vX` would reach nobody who already has `vX`. A fix ships as a higher version. `make check-versions` refuses a version whose tag already exists, locally or on origin.
- **A release is built from a commit.** `make release-signed` refuses uncommitted changes to tracked files, and untracked or ignored files in a package's `Sources` or among its `Package*.swift` manifests (SwiftPM compiles them whatever git ignores, and reads a `Package@swift-6.swift` instead of `Package.swift`; a `.DS_Store` is left out); every build refuses a commit that tracks a symlink anywhere in a package. It prints the commit it built from, packs the `.mcpb` bundles from that commit, and the GitHub release targets it. It checks again before writing `.build/dist/vX/` and writes nothing if HEAD moved or the tree changed meanwhile ([#94](https://github.com/PsychQuant/che-msg/issues/94)). An edit made and undone in between goes unnoticed, so do not edit files or switch branches in this checkout while it runs (the second package is built after the first notarization, which can take 15 minutes).
- **A release builds the dependency versions in each package's `Package.resolved`.** Both files are tracked, and every `swift build` in the release runs with `--force-resolved-versions`, so a tag records exactly what its binaries were built from; a package whose `Package.resolved` is untracked or missing stops the build. To update dependencies, do it as its own change: `swift package update` in the package, run its tests, and commit the new `Package.resolved` ([#92](https://github.com/PsychQuant/che-msg/issues/92)). If `Package.resolved` shows as modified and you did not mean to update anything, restore it with `git checkout -- <package>/Package.resolved`.
- **Only the files in `.build/dist/vX/` are released.** They are signed and notarized, and the directory appears only when all eight are done. `.build/dist/vX-sign-only/` and `.build/dist/vX-unsigned/` are for checking a build locally; from a tree with uncommitted changes, their binaries come from the working tree but their bundles hold the committed `manifest.json` and `PRIVACY.md`.
- **Until [#48](https://github.com/PsychQuant/che-msg/issues/48) ships, the plugin README keeps its note** that the `/che-telegram-mcp:auth` skill still asks for the phone number and the 2FA password, and that `auth_run` without arguments is the way to log in with both stored. Remove the note in the plugin release that ships #48 ([#97](https://github.com/PsychQuant/che-msg/issues/97)).
- **The release exists before the version bump reaches `main`.** The `che-msg` marketplace serves `main`. A wrapper pinned to a version that has no release yet installs whatever `releases/latest` is and records the pinned version in its sidecar, so on that machine it never fetches the real release afterwards ([#50](https://github.com/PsychQuant/che-msg/issues/50) tracks the decision whether to remove that fallback).
- Raw Mach-O binaries cannot be stapled. Gatekeeper checks the notarization online the first time a binary runs.

## One-time setup

- A Developer ID Application certificate in the login keychain. `security find-identity -p codesigning -v` lists it.
- A notarytool keychain profile: `xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team-id>`. It prompts for an app-specific password; never pass the password on the command line. `xcrun notarytool history --keychain-profile <name>` checks that the profile still works.
- The `mcpb` CLI (`npm install -g @anthropic-ai/mcpb`), the Xcode Command Line Tools, and `python3`.

`DEVELOPER_ID` may be the identity's name or its SHA-1 hash, as `security find-identity` prints them.

## Steps

1. **Bump the version on a branch.** For a binary version `X` and a plugin version `P`, change exactly the places `scripts/release/check-versions.sh` checks:
   - `che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift` (`version`) and `che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift` (`version:`)
   - both `mcpb/manifest.json` files
   - `DESIRED_VERSION` in both wrappers under `plugins/che-telegram-mcp/bin/`
   - the pin note in `CLAUDE.md` (「目前 X」)
   - `plugins/che-telegram-mcp/README.md`: the manual-install commands and the Version section
   - the all-mcp and bot CHANGELOGs: `[Unreleased]` becomes `## [X] - <date>`
   - the plugin version `P`: `plugins/che-telegram-mcp/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, the README's "Plugin version", and a `## [P]` section in the plugin CHANGELOG that names `X`

   A feature's minimum version ("Needs `che-telegram-all-mcp` 0.8.0 or later") is not a pin; leave it unless the feature changed.
2. **`make check-versions`**, and fix whatever it lists. (`make check-pins` checks the same places without the tag check, for a tree whose version is already released.)
3. **Commit everything and push the branch.**
4. **Optionally `make sign-check`** with `DEVELOPER_ID` set: the full build, signed but not notarized, so signing problems show up before anything is submitted. Nothing is uploaded, but codesign still fetches a secure timestamp from Apple's timestamp service (only the signature's digest is sent), so it needs the network. macOS may ask once for permission to use the signing key.
5. **`make release-signed`** with `DEVELOPER_ID` and `NOTARY_PROFILE` set. It checks the versions and the commit, builds both binaries for arm64 and x86_64, checks telegram-all's `--version`, signs, notarizes (usually 1–15 minutes per binary), runs the signed telegram-all's `--version` once more, packs the `.mcpb` bundles, checks the commit and the tree again, and writes eight files to `.build/dist/vX/`: two binaries, two `.mcpb` bundles, and a `.sha256` with the hash of each. It prints the commit it built from.

   The signed telegram-all's `--version` runs after `sign-and-notarize.sh` returns, so in this mode a failure there is reported after Apple already received the submission (nothing is published; a rerun rebuilds and resubmits).

   If it stops at the `spctl` check right after a notarization succeeded, Apple's records may not have reached Gatekeeper yet: wait a few minutes and run it again (it rebuilds and resubmits). On the first release, note what `spctl` printed, including its exit status, in the release issue; the script prints it but does not rely on it yet.
6. **Optionally start the notarized telegram-all against your real TDLib session** before publishing: close every Claude Code session that uses telegram-all (it holds the TDLib lock), then from the repository root run
   ```bash
   { printf '%s\n' \
       '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
       '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
       '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"auth_status","arguments":{}}}'; sleep 15; } |
     TELEGRAM_API_ID="$(security find-generic-password -a che-telegram-all-mcp -s TELEGRAM_API_ID -w)" \
     TELEGRAM_API_HASH="$(security find-generic-password -a che-telegram-all-mcp -s TELEGRAM_API_HASH -w)" \
     .build/dist/vX/CheTelegramAllMCP
   ```
   The reply to `id` 2 should report the session as authorized. Step 5 already started the signed binary once, for `--version`, which neither starts the server nor opens TDLib; this step is the only run of the hardened-runtime binary against a real TDLib session before users get it.

7. **0.9.0 only, and required: log in once from scratch with the Keychain** ([#97](https://github.com/PsychQuant/che-msg/issues/97)). From 0.9.0 the server reads the phone number and the 2FA password from the Keychain ([#49](https://github.com/PsychQuant/che-msg/issues/49)), and no test runs that path against TDLib. Use a separate macOS user account that you log in to on screen (fast user switching), so its login Keychain is unlocked, with Claude Code installed and signed in; it has its own Keychain and its own TDLib database (the server finds the database through Application Support, which `HOME` does not move), and a Telegram test account that has a 2FA password:
   1. In that account, store `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `TELEGRAM_PHONE` and `TELEGRAM_2FA_PASSWORD` with the plugin README's commands (`-w` last, so `security` prompts for each value), and check that neither `TELEGRAM_PHONE` nor `TELEGRAM_2FA_PASSWORD` is in the environment.
   2. Copy `.build/dist/vX/CheTelegramAllMCP` somewhere that account can read (for example `/Users/Shared`), register it with Claude Code there in the form the che-telegram-all-mcp README gives (the API credentials read from the Keychain at launch), and ask Claude to call `auth_run` with no arguments. Give the login code with `auth_run(code:)`, then call `auth_run` until `state` is `ready`.
   3. Record in #97 (this check's own record, apart from the release issue step 5 mentions): that the login code was the only value typed; whether the answer to `auth_run(code:)` was already the state after the stored password, or asked for the password (its 15-second wait starts only if TDLib's state update arrives before the response to the code); and, if TDLib went to a state the client does not track (for example email setup), that `auth_run` waited the full 15 seconds. The time each call took is shown with the tool call.

   Remove this step once 0.9.0 is released.
8. **Create the release** at the commit `make release-signed` printed:
   ```bash
   gh release create vX .build/dist/vX/* --target <commit> --title vX --notes-file <notes.md>
   ```
   Check that every asset's `digest` in `gh release view vX --json assets` matches its `.sha256` file.
9. **Merge the branch into `main` with a merge commit** (not squash or rebase), so the tagged commit is on `main`. The marketplace now offers the new plugin version, and its wrappers download `vX`.
10. **Close every Claude Code session, then update locally.** A session keeps the wrapper of the plugin version it started with; one still running an older plugin can put the older binary back over the new one ([#83](https://github.com/PsychQuant/che-msg/issues/83)). With all sessions closed: `claude plugin marketplace update che-msg`, `claude plugin update che-telegram-mcp@che-msg`. To install by hand instead, download each binary from the release, compare it with the release's digest, `rm -f ~/bin/<Binary>` before moving the new file into place (a fresh inode: macOS caches code signatures per inode), and write `X` to `~/bin/.<Binary>.version`. Then start sessions again.

## Tests

`make test-release` runs the release-tooling tests in `tests/release/`. None of them builds, signs, notarizes or touches the Keychain: they use fake tools and scratch directories.
