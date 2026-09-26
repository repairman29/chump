#!/usr/bin/env bash
# scripts/ci/test-ast-crawler-bash.sh — INFRA-1821 regression test.
#
# tree-sitter-bash 0.25 does not guarantee `function_definition` nodes are
# direct children of `program` (conditional/case wrappers, and parser
# error-recovery around unsupported syntax elsewhere in a file, can nest
# them deeper). The old top-level-only scan in crates/ast-crawler's
# `parse_bash` silently dropped those symbols.
#
# This asserts the crawler, run against Chump's own scripts/ directory
# (hundreds of real bash fn defs), extracts a plausible symbol count —
# not the 0-symbols regression this gap fixed.
#
# Pillar: RESILIENT. Run via `chump preflight` and on every PR touching
# crates/ast-crawler/.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

MIN_SYMBOLS=100

echo "[ast-crawler-bash] cargo run -p chump-ast-crawler --bin crawl-cli -- scripts"
SHAPE_JSON="$(mktemp)"
trap 'rm -f "$SHAPE_JSON"' EXIT
PATH="${HOME}/.cargo/bin:${PATH}" \
  cargo run -q -p chump-ast-crawler --bin crawl-cli -- scripts > "$SHAPE_JSON"

python3 - "$SHAPE_JSON" "$MIN_SYMBOLS" <<'PY'
import json, sys, pathlib

shape = json.loads(pathlib.Path(sys.argv[1]).read_text())
min_symbols = int(sys.argv[2])

bash_files = [f for f in shape["files"] if f["language"] == "bash"]
assert bash_files, "expected at least one bash file under scripts/"

total_bash_symbols = sum(len(f["top_level_symbols"]) for f in bash_files)
assert total_bash_symbols > min_symbols, (
    f"expected > {min_symbols} bash symbols across scripts/, got "
    f"{total_bash_symbols} — the tree-sitter-bash top-level-scan "
    "regression (INFRA-1821) may have returned"
)

# Side-effect check (AC 6): bash should be among the top-3 symbol
# producers by language, not the 0-symbol outlier PR #2412 flagged.
by_language = {}
for f in shape["files"]:
    by_language.setdefault(f["language"], 0)
    by_language[f["language"]] += len(f["top_level_symbols"])
ranked = sorted(by_language.items(), key=lambda kv: kv[1], reverse=True)
top3 = [lang for lang, _ in ranked[:3]]
assert "bash" in top3, f"expected bash in top-3 symbol producers, got {ranked}"

print(
    f"OK ast-crawler-bash: {len(bash_files)} bash files, "
    f"{total_bash_symbols} symbols (> {min_symbols}), bash rank "
    f"{top3.index('bash') + 1} of {len(ranked)} languages"
)
PY

echo "[ast-crawler-bash] PASS"
