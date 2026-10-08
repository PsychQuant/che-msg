#!/bin/bash
# Fuzz evidence for tests/lib/frontmatter_subset.py (#139 verify round 4).
#
# Generates random frontmatter blocks heavy in the cases where PyYAML and
# Claude Code's Bun.YAML disagree (open quotes, `: `, `#`, `---`, `...`, NEL,
# U+2028, list indentation, CRLF), keeps the blocks subset_problems() accepts,
# and compares PyYAML with Bun.YAML.parse. Fails if Bun's first parse fails on
# an accepted block (Claude Code would then rewrite and re-parse it), or if the
# two disagree on structure or on a string value. Scalar type differences
# (yes/on/1e0) are counted, not failed: the layout tests compare the values
# they care about as exact strings.
#
# Requires bun (https://bun.sh) and PyYAML. Not part of the layout tests.
#
# Usage:
#   bash tests/frontmatter-subset-fuzz/run.sh [blocks-per-seed] [seed ...]
#   bash tests/frontmatter-subset-fuzz/run.sh 50000 13 29

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/../lib" && pwd)"
command -v bun >/dev/null 2>&1 || { echo "✗ bun not found — install from https://bun.sh"; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "✗ PyYAML not found for $(command -v python3) — pip install pyyaml"; exit 1; }
N="${1:-50000}"; shift || true
SEEDS=("$@"); [ "${#SEEDS[@]}" -gt 0 ] || SEEDS=(13 29)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-fuzz-XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
echo "bun $(bun --version), $N blocks per seed, seeds ${SEEDS[*]}"
STATUS=0
for seed in "${SEEDS[@]}"; do
    python3 "$HERE/gen.py" "$N" "$seed" > "$WORK/blocks.jsonl" || exit 1
    bun "$HERE/bun_parse.js" "$WORK/blocks.jsonl" > "$WORK/bun.jsonl" || exit 1
    OUT=$(python3 "$HERE/compare.py" "$WORK/blocks.jsonl" "$WORK/bun.jsonl" "$LIB") || exit 1
    echo "seed $seed: $(printf '%s\n' "$OUT" | head -1)"
    if printf '%s\n' "$OUT" | head -1 | grep -qE "'(BUN_FAIL|STRUCT|STRING|VALUE)'"; then
        printf '%s\n' "$OUT" | tail -n +2 | sed 's/^/    /'; STATUS=1
    fi
done
[ "$STATUS" -eq 0 ] && echo "✓ no disagreement on accepted blocks" || echo "✗ PyYAML and Bun.YAML disagree on accepted blocks"
exit "$STATUS"
