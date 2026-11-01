"""Exercise the Slack release gate on real source fixtures, without credentials."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
CHECK = REPO / "scripts/release/check-slack-versions.py"
WRAPPER = "plugins/che-slack-mcp/bin/che-slack-mcp-wrapper.sh"
SERVER = "che-slack-mcp/Sources/CheSlackMCPCore/Server.swift"
CLI = "che-slack-mcp/Sources/slack-all/main.swift"
MANIFEST = "plugins/che-slack-mcp/.claude-plugin/plugin.json"
MARKETPLACE = ".claude-plugin/marketplace.json"
README = "plugins/che-slack-mcp/README.md"
CHANGELOG = "che-slack-mcp/CHANGELOG.md"
PLUGIN_CHANGELOG = "plugins/che-slack-mcp/CHANGELOG.md"
FILES = [WRAPPER, SERVER, CLI, MANIFEST, MARKETPLACE, README, CHANGELOG, PLUGIN_CHANGELOG]
# Fixed historical fixture: later version bumps must not silently change the
# expectations of these tests. The real checkout is checked separately.
FIXTURE = {
    WRAPPER: '#!/bin/bash\nDESIRED_VERSION="0.9.0"\n',
    SERVER: 'public static let version = "0.9.0"\n',
    CLI: '    version: "0.9.0",\n',
    MANIFEST: '{"name": "che-slack-mcp", "version": "0.1.0"}',
    MARKETPLACE: '{"plugins": [{"name": "che-slack-mcp", "version": "0.1.0", "source": "./plugins/che-slack-mcp"}]}',
    README: ('curl -fL https://github.com/PsychQuant/che-msg/releases/download/v0.9.0/CheSlackMCP -o ~/bin/CheSlackMCP\n'
             'echo 0.9.0 > ~/bin/.CheSlackMCP.version\n'),
    CHANGELOG: '# Changelog\n\n## [Unreleased]\n',
    PLUGIN_CHANGELOG: '# Changelog\n\n## [Unreleased]\n',
}


class SlackVersionsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in FILES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(FIXTURE[name])

    def run_check(self, *args):
        return subprocess.run(
            [sys.executable, str(CHECK), "0.9.0", "--root", str(self.root), *args],
            capture_output=True, text=True, timeout=10)

    def replace(self, name, old, new):
        path = self.root / name
        content = path.read_text()
        self.assertIn(old, content)
        path.write_text(content.replace(old, new))

    def assert_rejected(self, result, label):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(label, result.stderr)

    def test_current_development_pins_agree(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0.1.0", result.stdout)

    def test_each_binary_pin_mismatch_is_named(self):
        for name in (WRAPPER, SERVER, CLI):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_text()
                path.write_text(original.replace('"0.9.0"', '"0.8.0"'))
                self.assert_rejected(self.run_check(), name)
                path.write_text(original)

    def test_agreement_at_wrong_release_version_is_rejected(self):
        for name in (WRAPPER, SERVER, CLI, README):
            path = self.root / name
            path.write_text(path.read_text().replace("0.9.0", "0.8.0"))
        self.assert_rejected(self.run_check(), "0.9.0")

    def test_duplicate_wrapper_assignment_is_rejected(self):
        with (self.root / WRAPPER).open("a") as stream:
            stream.write('\nDESIRED_VERSION="0.9.0"\n')
        self.assert_rejected(self.run_check(), WRAPPER)

    def test_malformed_pin_is_rejected(self):
        self.replace(CLI, 'version: "0.9.0"', 'version: "release"')
        self.assert_rejected(self.run_check(), CLI)

    def test_plugin_version_is_independent_but_must_match_marketplace(self):
        self.replace(MANIFEST, '"0.1.0"', '"0.2.0"')
        self.assert_rejected(self.run_check(), MARKETPLACE)
        self.replace(MARKETPLACE, '"0.1.0"', '"0.2.0"')
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_duplicate_marketplace_entry_is_rejected(self):
        path = self.root / MARKETPLACE
        data = json.loads(path.read_text())
        entry = next(p for p in data["plugins"] if p["name"] == "che-slack-mcp")
        data["plugins"].append(entry)
        path.write_text(json.dumps(data))
        self.assert_rejected(self.run_check(), MARKETPLACE)

    def test_wrong_plugin_source_is_rejected(self):
        self.replace(MARKETPLACE, '"./plugins/che-slack-mcp"', '"./plugins/wrong"')
        self.assert_rejected(self.run_check(), MARKETPLACE)

    def test_wrong_manifest_name_is_rejected(self):
        self.replace(MANIFEST, '"name": "che-slack-mcp"', '"name": "wrong"')
        self.assert_rejected(self.run_check(), MANIFEST)

    def test_each_install_instruction_mismatch_is_named(self):
        for old in ("releases/download/v0.9.0/CheSlackMCP", "echo 0.9.0 >"):
            with self.subTest(old=old):
                path = self.root / README
                original = path.read_text()
                self.replace(README, old, old.replace("0.9.0", "0.8.0"))
                self.assert_rejected(self.run_check(), README)
                path.write_text(original)

    def test_missing_install_instruction_is_rejected(self):
        self.replace(README, "echo 0.9.0 > ~/bin/.CheSlackMCP.version", "# absent")
        self.assert_rejected(self.run_check(), README)

    def test_release_requires_both_changelog_headings(self):
        self.assert_rejected(self.run_check("--release"), CHANGELOG)
        self.replace(CHANGELOG, "## [Unreleased]", "## [0.9.0] - 2026-11-01")
        self.assert_rejected(self.run_check("--release"), PLUGIN_CHANGELOG)
        self.replace(PLUGIN_CHANGELOG, "## [Unreleased]", "## [0.1.0] - 2026-11-01")
        result = self.run_check("--release")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_file_fails_closed(self):
        for name in FILES:
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.unlink()
                self.assert_rejected(self.run_check(), name)
                path.write_bytes(original)

    def test_malformed_json_fails_closed(self):
        (self.root / MANIFEST).write_text("{")
        self.assert_rejected(self.run_check(), MANIFEST)

    def test_invalid_release_argument_fails(self):
        result = subprocess.run([sys.executable, str(CHECK), "../0.9.0"],
                                capture_output=True, text=True, timeout=10)
        self.assert_rejected(result, "version")


if __name__ == "__main__":
    unittest.main()
