# #114: Slack release prerequisites and integration handoff

This is an **incomplete release integration**, not a release procedure or a
replacement for `RELEASING.md` from #97. No binary has been built, signed,
notarized, or published by this change. Keep #114 open and #113 in draft.

## Source availability checked on 2026-11-01

- `main`: `2c98b988fe678bf13409b49c87c66dd08afe2f6f`.
- #113: draft, head `d34c841f000d07a24bbe2b84bb90f2acf5743ad1`, branch
  `idd/99-che-slack-mcp`. This change is stacked on that head.
- #94 reports verified local head `fc2474f`, branch
  `idd/94-release-build-commit-binding`, stacked on #92.
- #97 reports verified local head `084e549`, branch
  `idd/97-keychain-release-gate`, including #94 and #96.
- Neither release-tooling branch is advertised by GitHub or present in the
  clone. GitHub's commit endpoints return 422 for both recorded heads. Their
  scripts, tests and `RELEASING.md` are absent from every fetched branch.
- The GitHub release endpoint for `v0.9.0` returns 404.

The #94/#97 reports describe commit-bound packaging, clean-tree checks before
and after notarization, symlink rejection, ignored/untracked input checks,
pre/post-sign version execution and a required real Keychain login for 0.9.0.
Those reports establish the intended architecture; they do **not** supply the
implementation. Push the verified #97 branch with its ancestry before
modifying or merging that tooling. Do not reconstruct it from review summaries
or silently substitute an older release process.

## Changes available here

`CheSlackMCP --version` returns `che-slack-mcp X` before server construction,
using `CheSlackMCPServer.name` and `.version`, rather than a third version
literal. It leaves ordinary stdio MCP startup unchanged.

```sh
python3 scripts/release/check-slack-versions.py 0.9.0
python3 -m unittest discover -s tests/release -p 'test_slack_versions.py' -v
```

The standalone gate checks the Slack wrapper, server and CLI against the
requested binary version; plugin manifest against its single marketplace
entry; README download URLs and version sidecar command; and the existence of
both changelogs. `--release` additionally requires dated binary and plugin
release headings. The plugin version (currently 0.1.0) is independent of the
binary version (0.9.0). This gate does not check Telegram or contact GitHub.
The current Unreleased changelogs intentionally fail `--release`.

On macOS, build the real product and run its regression test:

```sh
cd che-slack-mcp
swift test
swift build -c release --product CheSlackMCP
cd ..
bash tests/release/test-slack-server-version.sh che-slack-mcp/.build/release/CheSlackMCP
```

The test holds stdin open, sets invalid pacing overrides that would warn if
server initialization ran, and requires exit 0 within five seconds, exactly
the expected version on stdout, and empty stderr. A missing binary fails; it
is not a skipped success. Run it again against the signed/notarized binary.
The available Linux environment has no Swift, so neither the Swift suite nor
this real-binary test has passed here.

Validation recorded here: all 15 Python gate tests pass, as does the gate on
the real checkout. Of the ten existing plugin shell suites, eight pass.
`tests/che-slack-mcp/test-wrapper.sh` reports four assertions failing in its
immutable-file case (`chflags` is unavailable on Linux).
`tests/che-telegram-mcp/test-wrapper-pid.sh` reports five process-liveness
assertions failing; that suite was not made green or diagnosed further in this
release-prerequisite change. Both wrappers and both suites are unchanged from
#113's head. `claude plugin validate` and the Bun frontmatter fuzz suite were
not run: neither CLI is installed. These results are not a full macOS pass.

## Integration still required after the original tooling is pushed

1. Integrate the verified #94/#97 ancestry and Slack sources on the maintainer's
   `release/0.9.0` branch. Preserve #92's dependency-lock checks and #94's input
   and commit-binding protections. Resolve any overlap with these additions.
2. Extend `build-release.sh` with `che-slack-mcp:CheSlackMCP`. Build arm64 and
   x86_64 and combine them into the universal asset named **CheSlackMCP**: the
   wrapper asks for that exact name, not architecture-suffixed files. Preserve
   both Telegram binaries and both existing Desktop bundles. Slack has no
   `mcpb/`; skip its bundle only, without making a missing Telegram bundle pass.
3. Apply the existing signing and notarization policy to Slack. Verify both
   architectures, the correct Developer ID/hardened runtime and notarization;
   run bounded `--version` checks before signing and after notarization.
   Generate checksums from the final signed payloads, never pre-sign bytes.
4. Call `check-slack-versions.py "$VERSION"` from the existing version/pin
   gates, and pass `--release` where release headings are required. Retain all
   existing Telegram checks. Do not bump Slack's plugin version to 0.9.0 merely
   to match the binary. `slack-all` remains source-only (#112).
5. Wire the new tests into `make test-release`. Extend the existing fake-tool
   build/sign tests for Slack's two architectures, signing/notarization calls,
   pre/post-sign version mismatch, nonzero exit after printing a version,
   timeout, optional Slack bundle, required Telegram bundles, final checksums,
   and failures leaving no publishable dist. Fake tools require no credentials;
   they cannot prove Apple signing or notarization succeeded.
6. Update the original `RELEASING.md`: name Slack in steps 1, 5 and 8; include
   `che-slack-mcp@che-msg` in step 10. Preserve #97's required first login in a
   separate macOS user account and its evidence on #97. Preserve the #48
   qualifier unless that auth-skill change actually ships. Follow the original
   signing/publishing approval procedure after reading it.

## Required published assets and verification

The documented release contract is five payloads and five sidecars:

| Payload | SHA-256 sidecar |
| --- | --- |
| `CheTelegramAllMCP` | `CheTelegramAllMCP.sha256` |
| `CheTelegramBotMCP` | `CheTelegramBotMCP.sha256` |
| `CheSlackMCP` | `CheSlackMCP.sha256` |
| `che-telegram-all-mcp.mcpb` | `che-telegram-all-mcp.mcpb.sha256` |
| `che-telegram-bot-mcp.mcpb` | `che-telegram-bot-mcp.mcpb.sha256` |

Confirm this naming against the actual #94 scripts once available. Keep the
Telegram contract unchanged. There is no Slack Desktop bundle or `slack-all`
release asset in this scope.

After the approved release procedure publishes, read the GitHub release back:
check tag/commit, non-draft status and all ten assets. Download every payload
and sidecar again; compare checksums with the uploaded bytes and the local
signed output. Check both Mach-O slices and Apple signing/notarization of the
downloaded binaries. A local build, a draft release or uploaded files alone
is not success.

For the final Slack install test, use a clean temporary install home with the
unmodified PR #113 wrapper, invoking it with `--version`. Confirm it queried
the exact tag and actually installed `bin/CheSlackMCP` and its version sidecar;
compare the installed bytes to the verified release download. A successful
version print alone is insufficient: `/usr/local/bin/CheSlackMCP` is a wrapper
fallback and could hide a failed download. This version-only test sends no
Slack message and should not import credentials. Only after the real release
and this installation test pass may #113 be considered ready for review.

Until the original tooling and a macOS signing environment are available,
the build/sign/notarize/publish and wrapper-download gates remain **blocked**.
