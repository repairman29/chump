#!/usr/bin/env bash
# scripts/ci/test-ast-crawler-bash.sh — INFRA-1821 regression test.
#
# tree-sitter-bash nests function_definition nodes below root (idempotent
# guard blocks like `[[ cond ]] || { fn() { ...}; }`, and ERROR-node
# recovery from earlier grammar edge cases in the same file), so a shallow
# root.named_children() scan used to find 0 top-level symbols in nearly
# every real bash file. This asserts the fix holds against the real
# scripts/ tree, where Chump has hundreds of top-level bash functions.
#
# Pillar: RESILIENT. Run via `chump preflight` and on every PR touching
# crates/ast-crawler/.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "[ast-crawler-bash] cargo run -p chump-ast-crawler --bin crawl-cli -- scripts/"
SHAPE_JSON="$(mktemp)"
trap 'rm -f "$SHAPE_JSON"' EXIT

PATH="${HOME}/.cargo/bin:${PATH}" \
  cargo run -q -p chump-ast-crawler --bin crawl-cli -- scripts/ > "$SHAPE_JSON"

python3 - "$SHAPE_JSON" <<'PY'
import json, sys, pathlib

shape = json.loads(pathlib.Path(sys.argv[1]).read_text())
bash_files = [f for f in shape["files"] if f["language"] == "bash"]
assert bash_files, "expected at least one bash file under scripts/"

bash_symbols = sum(len(f["top_level_symbols"]) for f in bash_files)
assert bash_symbols > 100, (
    f"expected > 100 top-level bash symbols under scripts/, got {bash_symbols} "
    "-- tree-sitter-bash fn-definition extraction may have regressed to the "
    "0-symbol bug (INFRA-1821)"
)

print(f"OK ast-crawler-bash smoke ({len(bash_files)} bash files, {bash_symbols} symbols)")
PY

echo "[ast-crawler-bash] PASS"
