#!/usr/bin/env python3
"""Slack-only gate for integration into #94's check-versions/check-pins.

This does not replace the Telegram checks or verify a published release.
Plugin versions are independent of the binary release version. --release
also requires dated CHANGELOG headings; ordinary checks permit Unreleased.
Uses only the standard library and never reads credentials or the network.
"""
import argparse
import json
from pathlib import Path
import re
import sys

SEMVER = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
PLUGIN = "che-slack-mcp"


def check(root, version, release=False):
    problems = []

    def read(name):
        try:
            return (root / name).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            problems.append(f"{name}: cannot read: {error}")
            return ""

    def matches(name, pattern, expected, exactly_one=True):
        values = re.findall(pattern, read(name), re.M)
        if not values or (exactly_one and len(values) != 1) or any(v != expected for v in values):
            problems.append(f"{name}: expected {'one ' if exactly_one else ''}{expected!r}, found {values!r}")

    def read_object(name):
        try:
            data = json.loads(read(name))
            if not isinstance(data, dict):
                raise ValueError("expected a JSON object")
            return data
        except ValueError as error:
            problems.append(f"{name}: invalid JSON: {error}")
            return {}

    matches(f"plugins/{PLUGIN}/bin/che-slack-mcp-wrapper.sh",
            r'^\s*DESIRED_VERSION="([^"\n]*)"\s*$', version)
    matches(f"{PLUGIN}/Sources/CheSlackMCPCore/Server.swift",
            r'^\s*public static let version = "([^"\n]*)"\s*$', version)
    matches(f"{PLUGIN}/Sources/slack-all/main.swift",
            r'^\s*version: "([^"\n]*)",\s*$', version)

    manifest_path = f"plugins/{PLUGIN}/.claude-plugin/plugin.json"
    manifest = read_object(manifest_path)
    plugin_version = manifest.get("version")
    if manifest.get("name") != PLUGIN:
        problems.append(f"{manifest_path}: name must be {PLUGIN!r}")
    if not isinstance(plugin_version, str) or not re.fullmatch(SEMVER, plugin_version):
        problems.append(f"{manifest_path}: invalid plugin version {plugin_version!r}")

    marketplace_path = ".claude-plugin/marketplace.json"
    marketplace = read_object(marketplace_path)
    plugins = marketplace.get("plugins", [])
    entries = ([item for item in plugins if isinstance(item, dict) and item.get("name") == PLUGIN]
               if isinstance(plugins, list) else [])
    if len(entries) != 1:
        problems.append(f"{marketplace_path}: expected one {PLUGIN} entry, found {len(entries)}")
    else:
        if entries[0].get("version") != plugin_version:
            problems.append(f"{marketplace_path}: {PLUGIN} version must equal {manifest_path} ({plugin_version!r})")
        if entries[0].get("source") != f"./plugins/{PLUGIN}":
            problems.append(f"{marketplace_path}: incorrect {PLUGIN} source")

    readme_path = f"plugins/{PLUGIN}/README.md"
    matches(readme_path,
            r'https://github\.com/PsychQuant/che-msg/releases/download/v([^/\s]+)/CheSlackMCP\b',
            version, exactly_one=False)
    matches(readme_path,
            r'^\s*echo\s+([^\s]+)\s*>\s*~/bin/\.CheSlackMCP\.version\s*$', version)

    for name, expected in ((f"{PLUGIN}/CHANGELOG.md", version),
                           (f"plugins/{PLUGIN}/CHANGELOG.md", plugin_version)):
        content = read(name)
        if release and (not isinstance(expected, str) or not re.search(
                rf'^## \[{re.escape(expected)}\] - \d{{4}}-\d{{2}}-\d{{2}}\s*$', content, re.M)):
            problems.append(f"{name}: release requires a dated [{expected}] heading")
    return problems, plugin_version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="binary version, for example 0.9.0 (no v prefix)")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--release", action="store_true", help="require dated binary and plugin changelog headings")
    args = parser.parse_args()
    if not re.fullmatch(SEMVER, args.version):
        parser.error("version must be a numeric x.y.z release version")
    problems, plugin_version = check(args.root, args.version, args.release)
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}", file=sys.stderr)
        return 1
    print(f"PASS: Slack binary pins {args.version}; plugin and marketplace {plugin_version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
