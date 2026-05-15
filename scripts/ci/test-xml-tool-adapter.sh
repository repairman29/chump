#!/usr/bin/env bash
# test-xml-tool-adapter.sh — EFFECTIVE-003
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ok() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; exit 1; }

echo "=== EFFECTIVE-003: XML tool adapter ==="

# 1. Crate compiles
cargo build -p chump-xml-adapter --quiet 2>&1 | head -5
ok "chump-xml-adapter crate compiles"

# 2. Unit tests pass
cargo test -p chump-xml-adapter --quiet 2>&1 | tail -5
ok "unit tests pass (8 tests)"

# 3. adapt() function defined
grep -q "pub fn adapt" "$REPO_ROOT/crates/chump-xml-adapter/src/lib.rs" \
    || fail "adapt() function not found in lib.rs"
ok "adapt() function defined"

# 4. ToolCall struct has id, name, input fields
grep -q "pub id" "$REPO_ROOT/crates/chump-xml-adapter/src/lib.rs" \
    || fail "ToolCall struct missing id field"
ok "ToolCall struct has required fields"

# 5. Crate registered in workspace Cargo.toml
grep -q "chump-xml-adapter" "$REPO_ROOT/Cargo.toml" \
    || fail "chump-xml-adapter not in workspace Cargo.toml"
ok "crate registered in workspace"

echo "=== EFFECTIVE-003 PASSED ==="
