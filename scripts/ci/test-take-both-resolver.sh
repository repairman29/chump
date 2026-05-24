#!/usr/bin/env bash
# scripts/ci/test-take-both-resolver.sh — INFRA-1920
#
# Smoke test for the take-both conflict resolver.
# Verifies:
#   1. Script exists, executable, has shebang
#   2. Strips markers from a synthesized additive Rust conflict
#   3. Strips markers from a synthesized additive yaml conflict
#   4. Both sides' content survives in both cases
#   5. Idempotent (re-running on clean file = no-op)
#   6. No-args invocation exits 1 with usage message

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/scripts/dev/take-both-resolve.py"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$TARGET" ]] || fail "$TARGET missing"
[[ -x "$TARGET" ]] || fail "$TARGET not executable"
head -1 "$TARGET" | grep -q '^#!/usr/bin/env python3' || fail "missing shebang"
grep -q 'INFRA-1920' "$TARGET" || fail "no INFRA-1920 attribution"
ok "script exists, executable, has shebang + INFRA-1920 attribution"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── (2) Rust additive conflict ─────────────────────────────────────────────
RUST="$TMP/conflict.rs"
cat > "$RUST" <<'EOF'
pub fn shared() {
    println!("on both sides");
}

<<<<<<< HEAD
pub fn from_head() {
    println!("added by HEAD");
}
=======
pub fn from_incoming() {
    println!("added by incoming branch");
}
>>>>>>> some-branch (feat: incoming add)
EOF

python3 "$TARGET" "$RUST" >/dev/null 2>&1
if grep -q '<<<<<<< \|^=======\|>>>>>>> ' "$RUST"; then
    fail "Rust conflict still has markers after resolve"
fi
ok "Rust additive: markers stripped"

grep -q "pub fn from_head" "$RUST" || fail "Rust: HEAD-side content missing"
grep -q "pub fn from_incoming" "$RUST" || fail "Rust: incoming-side content missing"
ok "Rust additive: BOTH sides' content preserved"

# ── (3) yaml additive conflict ─────────────────────────────────────────────
YAML="$TMP/conflict.yaml"
cat > "$YAML" <<'EOF'
- id: TEST-001
  acceptance_criteria:
    - "shared item"
<<<<<<< HEAD
    - "head-added item alpha"
    - "head-added item beta"
=======
    - "incoming-added item gamma"
>>>>>>> their/branch
    - "shared tail"
EOF

python3 "$TARGET" "$YAML" >/dev/null 2>&1
if grep -q '<<<<<<< \|^=======\|>>>>>>> ' "$YAML"; then
    fail "yaml conflict still has markers after resolve"
fi
ok "yaml additive: markers stripped"

grep -q "head-added item alpha" "$YAML" || fail "yaml: HEAD alpha missing"
grep -q "head-added item beta" "$YAML" || fail "yaml: HEAD beta missing"
grep -q "incoming-added item gamma" "$YAML" || fail "yaml: incoming gamma missing"
ok "yaml additive: all items from BOTH sides preserved"

# ── (4) Idempotent on clean file ───────────────────────────────────────────
CLEAN="$TMP/clean.txt"
echo "no conflicts here" > "$CLEAN"
BEFORE_HASH="$(shasum "$CLEAN" | cut -d' ' -f1)"
python3 "$TARGET" "$CLEAN" >/dev/null 2>&1
AFTER_HASH="$(shasum "$CLEAN" | cut -d' ' -f1)"
[[ "$BEFORE_HASH" == "$AFTER_HASH" ]] || fail "non-idempotent on clean file"
ok "idempotent on clean file (no-op)"

# ── (5) Re-run on already-resolved file → no-op ────────────────────────────
BEFORE_HASH="$(shasum "$RUST" | cut -d' ' -f1)"
python3 "$TARGET" "$RUST" >/dev/null 2>&1
AFTER_HASH="$(shasum "$RUST" | cut -d' ' -f1)"
[[ "$BEFORE_HASH" == "$AFTER_HASH" ]] || fail "non-idempotent on resolved file"
ok "idempotent on already-resolved file"

# ── (6) No-args → exit 1 with usage ────────────────────────────────────────
set +e
out="$(python3 "$TARGET" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "no-args expected exit 1, got $rc"
echo "$out" | grep -q "usage:" || fail "no-args missing usage message"
ok "no-args exits 1 with usage message"

# ── (7) Missing file → continues with skip message ─────────────────────────
set +e
out="$(python3 "$TARGET" "$TMP/does-not-exist" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "missing file should exit 0 (continue), got $rc"
echo "$out" | grep -q "skip:" || fail "missing-file skip message absent"
ok "missing file → skip + continue"

echo ""
echo "ALL INFRA-1920 take-both-resolver assertions passed."
