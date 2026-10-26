# Releasing

How a binary release of `che-telegram-all-mcp`, `che-telegram-bot-mcp` and `che-slack-mcp` is cut. The three binaries (`CheTelegramAllMCP`, `CheTelegramBotMCP`, `CheSlackMCP`) share one version number ([#114](https://github.com/PsychQuant/che-msg/issues/114)). `slack-all` is not released: its README builds it from source ([#112](https://github.com/PsychQuant/che-msg/issues/112)). Releases are built on the maintainer's Mac, because the Developer ID signing identity and the notarytool profile live in that Mac's Keychain ([#40](https://github.com/PsychQuant/che-msg/issues/40)).

## Rules

- **A released version is never published again.** The plugin's wrappers download a binary only when the pinned version changes, so a re-signed `vX` would reach nobody who already has `vX`. A fix ships as a higher version. `make check-build-versions` and `make check-versions` refuse a version whose tag already exists, locally or on origin.
- **A release is built from a commit.** `make release-signed` refuses uncommitted changes to tracked files, and untracked or ignored files in a package's `Sources` or among its `Package*.swift` manifests (SwiftPM compiles them whatever git ignores, and reads a `Package@swift-6.swift` instead of `Package.swift`; a `.DS_Store` is left out); every build refuses a commit that tracks a symlink anywhere in a package. It prints the commit it built from, packs the `.mcpb` bundles from that commit, and the GitHub release targets it. It checks again before writing `.build/dist/vX/` and writes nothing if HEAD moved or the tree changed meanwhile ([#94](https://github.com/PsychQuant/che-msg/issues/94)). An edit made and undone in between goes unnoticed, so do not edit files or switch branches in this checkout while it runs (all three packages are built first, which takes several minutes, and each notarization can take 15 more).
- **A release builds the dependency versions in each package's `Package.resolved`.** All three files are tracked ([#114](https://github.com/PsychQuant/che-msg/issues/114) added `che-slack-mcp`'s), and every `swift build` in the release runs with `--force-resolved-versions`, so a tag records exactly what its binaries were built from; a package whose `Package.resolved` is untracked or missing stops the build. To update dependencies, do it as its own change: `swift package update` in the package, run its tests, and commit the new `Package.resolved` ([#92](https://github.com/PsychQuant/che-msg/issues/92)). If `Package.resolved` shows as modified and you did not mean to update anything, restore it with `git checkout -- <package>/Package.resolved`.
- **Only the files in `.build/dist/vX/` are released.** They are signed and notarized, and the directory appears only when all ten are done. `.build/dist/vX-sign-only/` and `.build/dist/vX-unsigned/` are for checking a build locally; from a tree with uncommitted changes, their binaries come from the working tree but their bundles hold the committed `manifest.json` and `PRIVACY.md`.
- **Until [#48](https://github.com/PsychQuant/che-msg/issues/48) ships, the plugin README keeps its note** that the `/che-telegram-mcp:auth` skill still asks for the phone number and the 2FA password, and that `auth_run` without arguments is the way to log in with both stored. Remove the note in the plugin release that ships #48 ([#97](https://github.com/PsychQuant/che-msg/issues/97)).
- **The plugin pins a version only together with its sha256, after the build.** Each wrapper installs a download only when its sha256 equals `SHA256_PIN`, the value of `.build/dist/vX/<Binary>.sha256` for the version in `SHA256_PIN_VERSION`, and downloads nothing without a pin for its `DESIRED_VERSION` ([#50](https://github.com/PsychQuant/che-msg/issues/50)). The pins can only come from the build, so step 1 bumps only the binary, and step 8 bumps the plugin to `vX` and pins it in one change. The build checks only the binary's places (`check-versions.sh --before-build`).
- **The release exists before the plugin's bump reaches `main`.** The `che-msg` marketplace serves `main`. A wrapper pinned to a version that has no release yet downloads nothing: it keeps an installed binary, and a first install fails ([#50](https://github.com/PsychQuant/che-msg/issues/50) removed the fallback to `releases/latest`, which installed another release and recorded the pinned version for it).
- Raw Mach-O binaries cannot be stapled. Gatekeeper checks the notarization online the first time a binary runs.

## One-time setup

- macOS 26 or later on the Mac that builds the release: the binaries need it, and the build starts telegram-all (`--version`) ([#91](https://github.com/PsychQuant/che-msg/issues/91)).
- A Developer ID Application certificate in the login keychain. `security find-identity -p codesigning -v` lists it.
- A notarytool keychain profile: `xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team-id>`. It prompts for an app-specific password; never pass the password on the command line. `xcrun notarytool history --keychain-profile <name>` checks that the profile still works.
- The `mcpb` CLI (`npm install -g @anthropic-ai/mcpb`), the Xcode Command Line Tools, and `python3`.

`DEVELOPER_ID` may be the identity's name or its SHA-1 hash, as `security find-identity` prints them.

## Steps

1. **Bump the binary version on a branch.** For a binary version `X`, change the binary's places that `scripts/release/check-versions.sh --before-build` checks:
   - `che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift` (`version`) and `che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift` (`version:`)
   - both `mcpb/manifest.json` files
   - the all-mcp and bot CHANGELOGs: `[Unreleased]` becomes `## [X] - <date>`
   - for `CheSlackMCP`: `che-slack-mcp/Sources/CheSlackMCPCore/Server.swift` (`version`), `che-slack-mcp/Sources/slack-all/main.swift` (`version:`), `DESIRED_VERSION` in `plugins/che-slack-mcp/bin/che-slack-mcp-wrapper.sh`, the manual-install commands in `plugins/che-slack-mcp/README.md` (the download URL and the `~/bin/.CheSlackMCP.version` line), and in `che-slack-mcp/CHANGELOG.md` `[Unreleased]` becomes `## [X] - <date>`

   Leave the che-telegram-mcp plugin as it is (its wrappers, `CLAUDE.md`'s pin note, the plugin README and the plugin version): it still pins the previous version, and step 8 bumps it to `X` with the build's sha256 pins. The che-slack-mcp plugin has a version of its own: change it only when the plugin changes, in `plugins/che-slack-mcp/.claude-plugin/plugin.json` and its `.claude-plugin/marketplace.json` entry together (`check-versions.sh` checks only that these two agree), with a section in the plugin's CHANGELOG. The Slack plugin README also names the binary version in prose (the installation note, "How the wrapper works", the Version section); those are not checked, so change them by hand.
2. **`make check-build-versions`**, and fix whatever it lists: the binary's places agree on `X`, and tag `vX` is unused, locally and on origin.
3. **Commit everything and push the branch.**
4. **Optionally `make sign-check`** with `DEVELOPER_ID` set: the full build, signed but not notarized, so signing problems show up before anything is submitted. Nothing is uploaded, but codesign still fetches a secure timestamp from Apple's timestamp service (only the signature's digest is sent), so it needs the network. macOS may ask once for permission to use the signing key.
5. **`make release-signed`** with `DEVELOPER_ID` and `NOTARY_PROFILE` set. It checks the binary's versions (as `make check-build-versions` does) and the commit, builds `CheTelegramAllMCP`, `CheTelegramBotMCP` and `CheSlackMCP` for arm64 and x86_64, and checks all three before it signs any: `otool` must show that every library they need at launch has a system library path (under `/usr/lib/` or `/System/Library/`, without a `..` component, and not a Swift back-deployment library `/usr/lib/swift/libswiftCompatibility*`; a weak load is allowed), because the release ships no library ([#91](https://github.com/PsychQuant/che-msg/issues/91)), and telegram-all and `CheSlackMCP` must answer `--version` (`che-telegram-all-mcp X`, `che-slack-mcp X`). Then it signs and notarizes each binary (usually 1–15 minutes per binary), runs both signed binaries' `--version` once more, packs the two Telegram `.mcpb` bundles (`che-slack-mcp` has no `mcpb` directory, so it gets no bundle), checks the commit and the tree again, and writes ten files to `.build/dist/vX/`: `CheTelegramAllMCP`, `CheTelegramBotMCP`, `CheSlackMCP`, `che-telegram-all-mcp.mcpb`, `che-telegram-bot-mcp.mcpb`, and a `.sha256` with the hash of each. It prints the commit it built from.

   The signed binaries' `--version` runs after `sign-and-notarize.sh` returns, so in this mode a failure there is reported after Apple already received the submission (nothing is published; a rerun rebuilds and resubmits).

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
   The reply to `id` 2 should report the session as authorized. Step 5 already started the signed binary once, for `--version`, which neither starts the server nor opens TDLib; this step is the only run of the hardened-runtime binary against your existing TDLib session before users get it.

7. **0.9.0 only, and required: log in once from scratch with the Keychain** ([#97](https://github.com/PsychQuant/che-msg/issues/97)). From 0.9.0 the server reads the phone number and the 2FA password from the Keychain ([#49](https://github.com/PsychQuant/che-msg/issues/49)), and no test runs that path against TDLib. Use a separate macOS user account: log in to it on screen (fast user switching), so its login Keychain is unlocked, with Claude Code installed and signed in there. It has its own Keychain and its own TDLib database (the server finds the database through Application Support, which `HOME` does not move). Use a Telegram test account that has a 2FA password:
   1. In that account, store `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `TELEGRAM_PHONE` and `TELEGRAM_2FA_PASSWORD` with the plugin README's commands (`-w` last, so `security` prompts for each value), and check that neither `TELEGRAM_PHONE` nor `TELEGRAM_2FA_PASSWORD` is in the environment.
   2. Copy `.build/dist/vX/CheTelegramAllMCP` somewhere that account can read (for example `/Users/Shared`), register it with Claude Code there in the form the che-telegram-all-mcp README gives (the API credentials read from the Keychain at launch), and ask Claude to call `auth_run` with no arguments. Give the login code with `auth_run(code:)`, then call `auth_run` until `state` is `ready`.
   3. Record in #97 (this check's own record, apart from the release issue step 5 mentions): that the login code was the only value typed; whether the answer to `auth_run(code:)` was already the state after the stored password, or asked for the password (its 15-second wait starts only if TDLib's state update arrives before the response to the code); and, if TDLib went to a state the client does not track (for example email setup), that `auth_run` waited the full 15 seconds. Take the time from when you send the request to when the answer appears, or from the session transcript's timestamps.

   Remove this step once 0.9.0 is released.
8. **Bump the plugin to `X` with the build's pins, then create the release.** In both wrappers, set the version and the pins together from the build ([#50](https://github.com/PsychQuant/che-msg/issues/50)):
   ```bash
   X=<version>
   for pair in che-telegram-all-mcp:CheTelegramAllMCP che-telegram-bot-mcp:CheTelegramBotMCP; do
       perl -pi -e "s/^DESIRED_VERSION=.*/DESIRED_VERSION=\"$X\"/; s/^SHA256_PIN_VERSION=.*/SHA256_PIN_VERSION=\"$X\"/; s/^SHA256_PIN=.*/SHA256_PIN=\"$(cat .build/dist/v$X/${pair#*:}.sha256)\"/" \
           "plugins/che-telegram-mcp/bin/${pair%%:*}-wrapper.sh"
   done
   ```
   Then, for a plugin version `P`, change the plugin's other places `scripts/release/check-versions.sh` checks:
   - the pin note in `CLAUDE.md` (「目前 X」)
   - `plugins/che-telegram-mcp/README.md`: the manual-install commands and the Version section
   - the plugin version `P`: `plugins/che-telegram-mcp/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, the README's "Plugin version", and a `## [P]` section in the plugin CHANGELOG that names `X`

   A feature's minimum version ("Needs `che-telegram-all-mcp` 0.8.0 or later") is not a pin; leave it unless the feature changed. Run `make check-sha256`, which passes only when every place agrees and both pins are for `X` and equal `.build/dist/vX/<Binary>.sha256`, then commit and push (`make check-pins` checks the same places without the build's files, for a tree whose version is already released). This commit comes after the one the build was made from; the release still targets the build's commit, and step 9's merge brings the plugin's bump to `main`. Then create the release at the commit `make release-signed` printed, with all ten files of `.build/dist/vX/` as assets:
   ```bash
   gh release create vX .build/dist/vX/* --target <commit> --title vX --notes-file <notes.md>
   ```
   Check that every asset's `digest` in `gh release view vX --json assets` matches its `.sha256` file (and so the pins set above), `CheSlackMCP` included: the Slack wrapper downloads only the asset `CheSlackMCP` of its pinned release and never falls back to `releases/latest`, so a release without it leaves new Slack users with no server.
9. **Merge the branch into `main` with a merge commit** (not squash or rebase), so the tagged commit is on `main`. The marketplace now offers the new plugin version, and its wrappers download `vX`.
10. **Close every Claude Code session, then update locally.** A session keeps the wrapper of the plugin version it started with; one still running an older plugin can put the older binary back over the new one ([#83](https://github.com/PsychQuant/che-msg/issues/83)). With all sessions closed: `claude plugin marketplace update che-msg`, `claude plugin update che-telegram-mcp@che-msg`, `claude plugin update che-slack-mcp@che-msg`. To install by hand instead, download each binary from the release, compare it with the release's digest, `rm -f ~/bin/<Binary>` before moving the new file into place (a fresh inode: macOS caches code signatures per inode), and write `X` to `~/bin/.<Binary>.version`. Then start sessions again.

## Tests

`make test-release` runs the release-tooling tests in `tests/release/`; `tests/release/test-check-versions.sh` covers the sha256 pin checks and `--before-build`, and `tests/che-telegram-mcp/test-wrapper-checksum.sh` what the wrappers do with a pin and without one. None of them builds, signs, notarizes or touches the Keychain: they use fake tools and scratch directories.
