#!/usr/bin/env bash
# test-preflight-claudeleak-gate.sh — INFRA-1793 AC5
#
# Smoke test for the no-claude-leak gate that `chump preflight` wires in
# (INFRA-1051 / INFRA-1793). Builds a synthetic scratch git repo containing a
# copy of scripts/ci/test-no-claude-leak.sh, adds a NEW src/foo.rs file whose
# diff introduces a `claude -p` invocation, and asserts the gate catches it
# (reports >=1 violation for the changed file). Also asserts the per-line
# opt-out marker (`# chump-harness-ok: claude-mention`, AC4) suppresses the
# same line, and that an out-of-scope file (docs/foo.md) is NOT scanned.
#
# Exit: 0 = all assertions pass; 1 = any assertion fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT_SRC="$REPO_ROOT/scripts/ci/test-no-claude-leak.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_TEST="$(mktemp -d -t test-pf-claudeleak-gate.XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

git init -q "$TMPDIR_TEST"
cd "$TMPDIR_TEST"
git config user.email "test@example.com"
git config user.name "Test"

mkdir -p scripts/ci src docs
cp "$GATE_SCRIPT_SRC" scripts/ci/test-no-claude-leak.sh

echo "fn main() {}" > src/foo.rs
echo "# doc" > docs/foo.md
git add -A
git commit -q -m "base"
git branch -q -m main

# ── 1. New 'claude -p' line in a product-layer file (src/) — must be caught ──
git checkout -q -b feature-1
cat >> src/foo.rs <<'EOF'
fn spawn_claude() { std::process::Command::new("claude").arg("-p").spawn().unwrap(); }
EOF
git add -A
git commit -q -m "add claude -p invocation"

out_1="$(bash scripts/ci/test-no-claude-leak.sh --base main 2>&1)"
if echo "$out_1" | grep -qE "Violations \(new 'claude' mentions outside allowlist\): [1-9]"; then
    ok "new 'claude -p' line in src/foo.rs is flagged as a violation"
else
    bad "expected a violation for the new 'claude -p' line, got:"
    echo "$out_1"
fi
if echo "$out_1" | grep -q "src/foo.rs:"; then
    ok "violation detail names the offending file (src/foo.rs)"
else
    bad "violation detail did not name src/foo.rs:"
    echo "$out_1"
fi

# ── 2. Same line, but WARN-ONLY by default → exit 0 (AC6) ────────────────────
bash scripts/ci/test-no-claude-leak.sh --base main >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    ok "default (warn-only) mode exits 0 despite the violation (AC6)"
else
    bad "default mode should exit 0 (warn-only) until INFRA-1053 backfill closes"
fi

# ── 3. --strict flips the same violation to a nonzero exit (AC3) ─────────────
bash scripts/ci/test-no-claude-leak.sh --base main --strict >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
    ok "--strict mode exits non-zero on the same violation (AC3)"
else
    bad "--strict mode should exit non-zero when a violation is present"
fi

# ── 4. Per-line opt-out marker suppresses the violation (AC4) ────────────────
git checkout -q main
git checkout -q -b feature-2
cat >> src/foo.rs <<'EOF'
fn spawn_claude() { std::process::Command::new("claude").arg("-p").spawn().unwrap(); } // chump-harness-ok: claude-mention
EOF
git add -A
git commit -q -m "add claude -p invocation with opt-out marker"

out_4="$(bash scripts/ci/test-no-claude-leak.sh --base main 2>&1)"
if echo "$out_4" | grep -qE "Violations \(new 'claude' mentions outside allowlist\): 0"; then
    ok "per-line '# chump-harness-ok: claude-mention' opt-out suppresses the violation (AC4)"
else
    bad "expected 0 violations with the opt-out marker present, got:"
    echo "$out_4"
fi

# ── 5. Out-of-scope file (docs/) is not scanned ───────────────────────────────
git checkout -q main
git checkout -q -b feature-3
echo "claude mention in docs" >> docs/foo.md
git add -A
git commit -q -m "docs-only claude mention"

out_5="$(bash scripts/ci/test-no-claude-leak.sh --base main 2>&1)"
if echo "$out_5" | grep -qE "Violations \(new 'claude' mentions outside allowlist\): 0"; then
    ok "docs/-only diff is out of product-layer scope — no violation"
else
    bad "expected 0 violations for a docs/-only diff, got:"
    echo "$out_5"
fi

echo
echo "test-preflight-claudeleak-gate: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
