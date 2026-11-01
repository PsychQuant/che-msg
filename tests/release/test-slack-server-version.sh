#!/bin/bash
# Exercise a real built binary. A missing macOS/Swift build is NOT a pass.
# Run before and after signing: bash tests/release/test-slack-server-version.sh /path/to/CheSlackMCP
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/CheSlackMCP" >&2
    exit 2
fi
python3 - "$ROOT" "$1" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

root, binary = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
source = (root / "che-slack-mcp/Sources/CheSlackMCPCore/Server.swift").read_text()
versions = re.findall(r'^\s*public static let version = "([0-9]+\.[0-9]+\.[0-9]+)"\s*$', source, re.M)
if len(versions) != 1:
    raise SystemExit("FAIL: could not read exactly one server version")
# Invalid pacing values would warn if the server were constructed. Keep stdin
# OPEN: communicate() would close it and let an accidentally started MCP exit.
env = {"PATH": "/usr/bin:/bin", "SLACK_MCP_MIN_INTERVAL_MS": "invalid",
       "SLACK_MCP_MAX_CONCURRENCY": "invalid"}
try:
    with subprocess.Popen([str(binary), "--version"], env=env,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE) as process:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise SystemExit("FAIL: --version did not exit with stdin still open")
        stdout, stderr = process.communicate()
        expected = f"che-slack-mcp {versions[0]}\n".encode()
        if process.returncode != 0 or stdout != expected or stderr:
            raise SystemExit(f"FAIL: exit={process.returncode}, stdout={stdout!r}, stderr={stderr!r}")
except OSError as error:
    raise SystemExit(f"FAIL: cannot run the real binary: {error}")
print("PASS: --version exits 0 without starting the stdio server")
PY
