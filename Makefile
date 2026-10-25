# Release tooling for the che-telegram binaries (PsychQuant/che-msg#40).
# Run from the repository root; RELEASING.md walks through a release.

.PHONY: check-versions release-signed sign-check test-release

# Every place that pins the binary or plugin version agrees, and tag vX is unused.
check-versions:
	./scripts/release/check-versions.sh

# The release build: universal, signed, notarized, packed, with .sha256 files,
# in .build/dist/vX/. Refuses to start unless signing and notarizing are set up.
release-signed:
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set. See RELEASING.md.}
	@: $${NOTARY_PROFILE:?NOTARY_PROFILE not set. See RELEASING.md.}
	REQUIRE_CODESIGN=1 ./scripts/release/build-release.sh

# The same build, signed but not notarized, in .build/dist/vX-sign-only/:
# checks signing locally without sending anything to Apple.
sign-check:
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set. See RELEASING.md.}
	REQUIRE_CODESIGN=1 ./scripts/release/build-release.sh --sign-only

test-release:
	bash tests/release/test-check-versions.sh
	bash tests/release/test-release-preflight.sh
	bash tests/release/test-build-release.sh
