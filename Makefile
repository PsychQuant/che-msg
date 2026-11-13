# Release tooling for the che-telegram binaries (PsychQuant/che-msg#40).
# Run from the repository root; RELEASING.md walks through a release.

.PHONY: help check-pins check-versions release-signed sign-check test-release
.DEFAULT_GOAL := help

help:
	@echo "make check-pins      every place that pins the binary or plugin version agrees"
	@echo "make check-versions  the same, and tag vX is still unused (locally and on origin)"
	@echo "make sign-check      full build, signed, not notarized (.build/dist/vX-sign-only/)"
	@echo "make release-signed  the release build: signed and notarized (.build/dist/vX/)"
	@echo "make test-release    the release-tooling tests (fake tools; nothing is signed)"

# Consistency only; passes on a tree whose version is already released.
check-pins:
	./scripts/release/check-versions.sh --no-tag-check

# Every place that pins the binary or plugin version agrees, and tag vX is unused.
check-versions:
	./scripts/release/check-versions.sh

# The release build: universal, signed, notarized, packed, with .sha256 files,
# in .build/dist/vX/. Refuses to start unless signing and notarizing are set up
# and every tracked file is committed.
release-signed:
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set. See RELEASING.md.}
	@: $${NOTARY_PROFILE:?NOTARY_PROFILE not set. See RELEASING.md.}
	REQUIRE_CODESIGN=1 ./scripts/release/build-release.sh

# The same build, signed but not notarized, in .build/dist/vX-sign-only/.
# Nothing is submitted to Apple; codesign still fetches a secure timestamp
# from Apple's timestamp service, so this needs the network.
sign-check:
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set. See RELEASING.md.}
	REQUIRE_CODESIGN=1 ./scripts/release/build-release.sh --sign-only

test-release:
	bash tests/release/test-check-versions.sh
	bash tests/release/test-release-preflight.sh
	bash tests/release/test-build-release.sh
