#!/usr/bin/env bash
# scripts/ci/test-ast-crawler-bash.sh — INFRA-1821 regression test.
#
# Guards against the AST crawler's bash parser regressing to 0 extracted
# symbols. tree-sitter-bash nests `function_definition` nodes below the
# root node, so a shallow named_children() scan on the root missed every
# fn def in real-world bash files. crawl-cli against scripts/ (which has
# hundreds of bash fns) is the ground-truth regression signal.
#
# Pillar: EFFECTIVE. Run via `chump preflight` and on every PR touching
# crates/ast-crawler/.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "[ast-crawler-bash] cargo run --release --bin crawl-cli -- scripts/"
SHAPE_JSON="$(mktemp)"
trap 'rm -f "$SHAPE_JSON"' EXIT

PATH="${HOME}/.cargo/bin:${PATH}" \
  cargo run -q --release -p chump-ast-crawler --bin crawl-cli -- scripts/ \
  > "$SHAPE_JSON"

python3 - "$SHAPE_JSON" <<'PY'
import json, sys, pathlib

shape = json.loads(pathlib.Path(sys.argv[1]).read_text())

bash_files = [f for f in shape["files"] if f["language"] == "bash"]
assert bash_files, "expected at least one bash file to be crawled under scripts/"

bash_symbol_count = sum(len(f["top_level_symbols"]) for f in bash_files)
print(f"[ast-crawler-bash] {len(bash_files)} bash files, {bash_symbol_count} bash symbols")

assert bash_symbol_count > 100, (
    f"expected > 100 bash symbols across scripts/ (Chump has hundreds of "
    f"bash fns), got {bash_symbol_count} — the bash parser may have "
    f"regressed to 0-extraction (INFRA-1821)"
)

# Side-effect check (AC 6): bash should now be among the top-3 symbol
# producers by language, not silently absent.
by_language = {}
for f in shape["files"]:
    by_language[f["language"]] = by_language.get(f["language"], 0) + len(f["top_level_symbols"])
ranked = sorted(by_language.items(), key=lambda kv: kv[1], reverse=True)
top3_langs = [lang for lang, _ in ranked[:3]]
assert "bash" in top3_langs, (
    f"expected bash among top-3 symbol producers, got ranking {ranked}"
)

print("OK ast-crawler bash regression check")
PY

echo "[ast-crawler-bash] PASS"
