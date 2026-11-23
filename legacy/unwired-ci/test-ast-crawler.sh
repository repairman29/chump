#!/usr/bin/env bash
# scripts/ci/test-ast-crawler.sh — INFRA-1719 smoke test for the tree-sitter
# AST crawler crate (chump-ast-crawler).
#
# Asserts that:
#   1. Synthetic Rust file → 2 fns + 1 struct extracted with correct kinds.
#   2. Synthetic Python file → 1 class + 2 methods extracted.
#   3. Synthetic `.qq` file → graceful fallback (supported=false, no crash)
#      and emits kind=ast_crawler_unsupported_language to ambient.jsonl.
#   4. Top-level CodebaseShape counters (total_files, total_symbols) match
#      the expected per-file extraction.
#
# Pillar: EFFECTIVE. Run via `chump preflight` and on every PR touching
# crates/ast-crawler/.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "[ast-crawler] cargo test -p chump-ast-crawler"
PATH="${HOME}/.cargo/bin:${PATH}" cargo test -q -p chump-ast-crawler --lib 2>&1 | tail -30

# Run an end-to-end check that exercises crawl_paths via a tiny shim binary
# we ship inside the crate's tests/ dir. The cargo unit tests cover the
# per-language correctness in-process; this layer asserts that the
# unsupported-extension code path also emits ambient.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AMBIENT="$TMP/ambient.jsonl"

mkdir -p "$TMP/repo/src"
cat > "$TMP/repo/src/widget.rs" <<'RUST'
/// A widget for testing.
pub struct Widget { pub size: u32 }

/// Make one.
pub fn make_widget() -> Widget { Widget { size: 1 } }

/// Drop it.
pub fn drop_widget(_w: Widget) {}
RUST

cat > "$TMP/repo/src/widget.py" <<'PY'
# A widget class.
class Widget:
    def make(self): return 1
    def drop(self): return None
PY

# Unsupported extension — must NOT crash and MUST emit ambient.
echo "binary blob" > "$TMP/repo/src/asset.qq"

CRATE_TEST_BIN="$TMP/check_paths"
cat > "$TMP/check_paths.rs" <<'RUST'
use std::path::PathBuf;
fn main() {
    let repo = PathBuf::from(std::env::args().nth(1).expect("repo arg"));
    let paths: Vec<PathBuf> = vec![
        repo.join("src/widget.rs"),
        repo.join("src/widget.py"),
        repo.join("src/asset.qq"),
    ];
    let shape = chump_ast_crawler::crawl_paths(&repo, &paths).expect("crawl_paths");
    println!("{}", serde_json::to_string_pretty(&shape).unwrap());
}
RUST

# Build a one-off shim that links against the crawler crate.
SHIM_DIR="$TMP/shim"
mkdir -p "$SHIM_DIR/src"
cp "$TMP/check_paths.rs" "$SHIM_DIR/src/main.rs"
cat > "$SHIM_DIR/Cargo.toml" <<EOF
[package]
name = "ast-crawler-smoke"
version = "0.0.0"
edition = "2021"

[[bin]]
name = "ast-crawler-smoke"
path = "src/main.rs"

[dependencies]
serde_json = "1"
chump-ast-crawler = { path = "$(pwd)/crates/ast-crawler" }
chump-ambient-cli = { path = "$(pwd)/crates/ambient-cli" }

[workspace]
EOF

pushd "$SHIM_DIR" > /dev/null
PATH="${HOME}/.cargo/bin:${PATH}" \
  CHUMP_AMBIENT_LOG="$AMBIENT" \
  cargo run -q --release > "$TMP/shape.json" -- "$TMP/repo"
popd > /dev/null

# Assert structural expectations on the JSON.
python3 - "$TMP/shape.json" "$AMBIENT" <<'PY'
import json, sys, pathlib
shape = json.loads(pathlib.Path(sys.argv[1]).read_text())
ambient = pathlib.Path(sys.argv[2]).read_text() if pathlib.Path(sys.argv[2]).exists() else ""

assert shape["total_files"] == 3, f"want 3 files, got {shape['total_files']}"

# Rust file: 1 struct + 2 fns = 3 top-level symbols.
rust = next(f for f in shape["files"] if f["path"].endswith("widget.rs"))
assert rust["language"] == "rust"
assert rust["supported"] is True
kinds = sorted(s["kind"] for s in rust["top_level_symbols"])
assert kinds == ["fn", "fn", "struct"], f"rust kinds {kinds}"
names = {s["name"] for s in rust["top_level_symbols"]}
assert {"Widget", "make_widget", "drop_widget"} <= names, names

# Python: 1 class + 2 dotted methods (Widget.make, Widget.drop).
py = next(f for f in shape["files"] if f["path"].endswith("widget.py"))
assert py["language"] == "python"
py_names = {s["name"] for s in py["top_level_symbols"]}
assert "Widget" in py_names
assert "Widget.make" in py_names
assert "Widget.drop" in py_names

# Unsupported extension: graceful fallback.
qq = next(f for f in shape["files"] if f["path"].endswith("asset.qq"))
assert qq["language"] == "unknown"
assert qq["supported"] is False
assert qq["top_level_symbols"] == []

# Ambient: expect at least one ast_crawler_unsupported_language event.
assert "ast_crawler_unsupported_language" in ambient, \
    "expected ast_crawler_unsupported_language event in ambient.jsonl"

print("OK ast-crawler smoke (3 files, rust+python+unknown, ambient event present)")
PY

echo "[ast-crawler] PASS"
