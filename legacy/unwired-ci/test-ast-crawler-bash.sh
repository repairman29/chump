#!/usr/bin/env bash
# scripts/ci/test-ast-crawler-bash.sh — INFRA-1821 regression gate.
#
# The AST crawler's bash parser (crates/ast-crawler/src/lib.rs::parse_bash)
# used a shallow `root.named_children()` scan for `function_definition`
# nodes. tree-sitter-bash nests function defs inside wrapper nodes (`list`,
# `compound_statement`) for common idioms like source guards
# (`[[ guard ]] || { fn() { ...; }; }`, e.g. scripts/lib/disk-check.sh), so
# the shallow scan silently dropped some fraction of real bash functions.
#
# This gate runs crawl-cli against scripts/ (which has hundreds of bash
# functions) and asserts the extracted symbol count is well above a
# regression floor, so a future shallow-scan reintroduction gets caught.
#
# Usage: bash scripts/ci/test-ast-crawler-bash.sh
# Exit:  0 = bash symbol count > 100
#        1 = bash symbol count <= 100 (regression)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

echo "[ast-crawler-bash] cargo run crawl-cli -- scripts"
SHAPE_JSON="$(mktemp)"
trap 'rm -f "$SHAPE_JSON"' EXIT
PATH="${HOME}/.cargo/bin:${PATH}" \
  cargo run --quiet -p chump-ast-crawler --bin crawl-cli -- scripts > "$SHAPE_JSON"

python3 - "$SHAPE_JSON" <<'PY'
import json, sys, pathlib

shape = json.loads(pathlib.Path(sys.argv[1]).read_text())
bash_files = [f for f in shape["files"] if f["language"] == "bash"]
total_symbols = sum(len(f["top_level_symbols"]) for f in bash_files)

assert bash_files, "expected at least one bash file under scripts/"
assert total_symbols > 100, (
    f"bash symbol extraction regressed: got {total_symbols} symbols across "
    f"{len(bash_files)} bash files (want > 100) — INFRA-1821 shallow-scan bug?"
)

print(f"OK ast-crawler-bash: {total_symbols} symbols across {len(bash_files)} bash files")
PY

echo "[ast-crawler-bash] PASS"
