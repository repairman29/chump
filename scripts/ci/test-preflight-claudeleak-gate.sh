#!/usr/bin/env bash
# test-preflight-claudeleak-gate.sh — INFRA-1793 (INFRA-1051 Tier C #7)
#
# Smoke test for the `chump preflight` no-claude-leak gate: builds a
# synthetic git fixture repo with a "main" baseline and a feature commit
# that adds a NEW `claude -p` invocation to a product-layer file
# (src/foo.rs), then runs scripts/ci/test-no-claude-leak.sh (the script
# preflight's gate wraps) against that fixture and asserts the violation is
# caught. Also asserts a clean diff (no new "claude" mentions) reports zero
# violations, and that a per-line opt-out (`# chump-harness-ok:
# claude-mention`) suppresses the hit.
#
# Does NOT invoke the `chump` binary — the gate's path-scoping condition
# (AC#1, "runs only when staged diff touches src/|scripts/coord/|
# scripts/dispatch/|scripts/ops/") is a pure Rust `.starts_with()` check
# with no external dependency worth a slow binary build; this test proves
# the underlying script (scripts/ci/test-no-claude-leak.sh) that the gate
# invokes actually catches the fixture the gate is meant to catch.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ci/test-no-claude-leak.sh"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1793 preflight no-claude-leak gate smoke test ==="
echo

[[ -f "$SCRIPT" ]] && ok "scripts/ci/test-no-claude-leak.sh exists" \
  || { fail "scripts/ci/test-no-claude-leak.sh missing at $SCRIPT"; echo; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git init -q "$TMP"
git -C "$TMP" config user.email "test@example.com"
git -C "$TMP" config user.name "test"
mkdir -p "$TMP/src" "$TMP/scripts/ci"
# The script under test resolves its own repo root via `dirname "$0"`, so it
# must be invoked from a copy that lives at the same scripts/ci/ relative
# path inside the fixture repo — otherwise it cd's back into THIS repo.
cp "$SCRIPT" "$TMP/scripts/ci/test-no-claude-leak.sh"
FIXTURE_SCRIPT="scripts/ci/test-no-claude-leak.sh"

# ── Baseline: main has a clean src/foo.rs, no claude mentions ───────────────
cat > "$TMP/src/foo.rs" <<'EOF'
fn hello() {
    println!("hello");
}
EOF
git -C "$TMP" add src/foo.rs
git -C "$TMP" commit -q -m "baseline"
# The script's per-line violation scan hardcodes an `origin/${BASE_BRANCH}`
# ref (not the CHANGED-file-list fallback's local-branch path) — so the
# fixture needs a real refs/remotes/origin/main, not just a local `main`
# branch, or new_hits silently comes back empty. This mirrors the real
# origin/main ref every actual PR diffs against.
git -C "$TMP" update-ref refs/remotes/origin/main HEAD
git -C "$TMP" branch -q -f main HEAD

# ── Case 1: feature branch adds a NEW 'claude -p' call to src/foo.rs ────────
git -C "$TMP" checkout -q -b feature-with-leak main
cat >> "$TMP/src/foo.rs" <<'EOF'

fn spawn_agent() {
    // new line: invokes claude -p directly
    let _ = std::process::Command::new("claude").arg("-p").spawn();
}
EOF
git -C "$TMP" add src/foo.rs
git -C "$TMP" commit -q -m "add claude -p spawn"

OUT="$(cd "$TMP" && GITHUB_BASE_REF=main bash "$FIXTURE_SCRIPT" 2>&1)"
if echo "$OUT" | grep -q "Violations (new 'claude' mentions outside allowlist): [1-9]"; then
    ok "new 'claude -p' invocation in src/foo.rs is caught as a violation"
else
    fail "expected >=1 violation, got: $OUT"
fi
# AC#6: warn-only today — the underlying script must still exit 0 without --strict.
(cd "$TMP" && GITHUB_BASE_REF=main bash "$FIXTURE_SCRIPT" >/dev/null 2>&1)
if [[ $? -eq 0 ]]; then
    ok "warn-only mode (no --strict) exits 0 despite the violation (AC#6)"
else
    fail "warn-only mode should exit 0 without --strict"
fi
(cd "$TMP" && GITHUB_BASE_REF=main bash "$FIXTURE_SCRIPT" --strict >/dev/null 2>&1)
if [[ $? -ne 0 ]]; then
    ok "--strict mode exits non-zero on the same violation"
else
    fail "--strict mode should exit non-zero when a violation exists"
fi

# ── Case 2: clean feature branch (no new claude mentions) → zero violations ─
git -C "$TMP" checkout -q -b feature-clean main
cat >> "$TMP/src/foo.rs" <<'EOF'

fn unrelated() {
    println!("unrelated change");
}
EOF
git -C "$TMP" add src/foo.rs
git -C "$TMP" commit -q -m "unrelated clean change"

OUT="$(cd "$TMP" && GITHUB_BASE_REF=main bash "$FIXTURE_SCRIPT" 2>&1)"
if echo "$OUT" | grep -q "Violations (new 'claude' mentions outside allowlist): 0"; then
    ok "clean diff reports zero violations"
else
    fail "expected zero violations on a clean diff, got: $OUT"
fi

# ── Case 3: per-line opt-out marker suppresses the hit ──────────────────────
git -C "$TMP" checkout -q -b feature-optout main
cat >> "$TMP/src/foo.rs" <<'EOF'

fn spawn_agent_optout() {
    let _ = std::process::Command::new("claude").arg("-p").spawn(); // chump-harness-ok: claude-mention
}
EOF
git -C "$TMP" add src/foo.rs
git -C "$TMP" commit -q -m "add claude -p spawn with opt-out marker"

OUT="$(cd "$TMP" && GITHUB_BASE_REF=main bash "$FIXTURE_SCRIPT" 2>&1)"
if echo "$OUT" | grep -q "Violations (new 'claude' mentions outside allowlist): 0"; then
    ok "per-line 'chump-harness-ok: claude-mention' opt-out suppresses the hit"
else
    fail "opt-out marker should suppress the violation, got: $OUT"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
