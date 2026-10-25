# Releasing

How a binary release of `che-telegram-all-mcp` and `che-telegram-bot-mcp` is cut. Both binaries share one version number. Releases are built on the maintainer's Mac, because the Developer ID signing identity and the notarytool profile live in that Mac's Keychain ([#40](https://github.com/PsychQuant/che-msg/issues/40)).

## Rules

- **A released version is never published again.** The plugin's wrappers download a binary only when the pinned version changes, so a re-signed `vX` would reach nobody who already has `vX`. A fix ships as a higher version. `make check-versions` refuses a version whose tag already exists, locally or on origin.
- **Only the files in `.build/dist/vX/` are released.** They are signed and notarized. `.build/dist/vX-sign-only/` and `.build/dist/vX-unsigned/` are for checking a build locally.
- **The release exists before the version bump reaches `main`.** The `che-msg` marketplace serves `main`; a wrapper pinned to a version that has no release falls back to the binary it already has.
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
   - the pin note in `CLAUDE.md`
   - `plugins/che-telegram-mcp/README.md`: the manual-install commands and the Version section
   - the all-mcp and bot CHANGELOGs: `[Unreleased]` becomes `## [X] - <date>`
   - the plugin version `P`: `plugins/che-telegram-mcp/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, the README's "Plugin version", and a `## [P]` section in the plugin CHANGELOG that names `X`

   A feature's minimum version ("Needs `che-telegram-all-mcp` 0.8.0 or later") is not a pin; leave it unless the feature changed.
2. **`make check-versions`**, and fix whatever it lists.
3. **Optionally `make sign-check`** with `DEVELOPER_ID` set: the full build, signed but not notarized, so signing problems show up without contacting Apple. macOS may ask once for permission to use the signing key.
4. **`make release-signed`** with `DEVELOPER_ID` and `NOTARY_PROFILE` set. It checks the versions again, builds both binaries for arm64 and x86_64, signs, notarizes (usually 1–15 minutes per binary), packs the `.mcpb` bundles and writes eight files to `.build/dist/vX/`: two binaries, two `.mcpb` bundles, and a `.sha256` with the hash of each.
5. **Push the branch and create the release** at its head:
   ```bash
   gh release create vX .build/dist/vX/* --target <branch> --title vX --notes-file <notes.md>
   ```
   Check that every asset's `digest` in `gh release view vX --json assets` matches its `.sha256` file.
6. **Merge the branch into `main`.** The marketplace now offers the new plugin version, and its wrappers download `vX`. Locally: `claude plugin marketplace update che-msg`, then `claude plugin update che-telegram-mcp@che-msg`.
7. **Install locally** if `~/bin` should have the release now: download each binary from the release, compare it with the release's digest, `rm -f ~/bin/<Binary>` before moving the new file into place (a fresh inode: macOS caches code signatures per inode), and write `X` to `~/bin/.<Binary>.version`.
8. **Restart every Claude Code session.** A session keeps the wrapper of the plugin version it started with until it restarts.

## Tests

`make test-release` runs the release-tooling tests in `tests/release/`. None of them builds, signs, notarizes or touches the Keychain: they use fake tools and scratch directories.
