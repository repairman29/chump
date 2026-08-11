#!/usr/bin/env bash
# scripts/ci/test-definition-of-ready-gate.sh — CREDIBLE-270
#
# Verifies scripts/coord/definition-of-ready-gate.sh:
#   1. `chump preflight` green → gate passes (exit 0), emits *_passed
#   2. `chump preflight` red   → gate refuses (exit 21), emits *_blocked
#   3. CHUMP_DOR_DISABLE=1     → gate no-ops regardless of preflight result
#   4. CHUMP_DOR_SKIP=1 without --skip-reason → refused (exit 22)
#   5. CHUMP_DOR_SKIP=1 with --skip-reason    → bypassed (exit 0), audit-logged
#   6. no `chump` on PATH, `cargo` gates fail → gate refuses (exit 21)
#   7. no `chump` and no `cargo` on PATH      → gate no-ops (exit 0)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
GATE="$REPO_ROOT/scripts/coord/definition-of-ready-gate.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
FAILED=0

[[ -x "$GATE" ]] || { echo "FAIL: gate script missing or not executable: $GATE"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/locks"
export CHUMP_AMBIENT_LOG=""  # gate resolves its own path via git-common-dir; unused here

run_in_tmp_repo() {
    # Run the gate from inside a throwaway git repo so MAIN_REPO/AMBIENT
    # resolution doesn't touch the real .chump-locks/ambient.jsonl.
    ( cd "$TMP/repo" && "$GATE" "$@" )
}

git init -q "$TMP/repo"

# ── Test 1: green preflight → pass ──────────────────────────────────────────
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "preflight" ]] && exit 0
exit 0
EOF
chmod +x "$TMP/bin/chump"
PATH="$TMP/bin:$PATH" run_in_tmp_repo "CREDIBLE-270"
rc=$?
[[ $rc -eq 0 ]] && ok "green chump preflight → exit 0" || fail "expected exit 0, got $rc"
grep -q '"kind":"definition_of_ready_gate_passed"' "$TMP/repo/.chump-locks/ambient.jsonl" 2>/dev/null \
    && ok "emits definition_of_ready_gate_passed" \
    || fail "missing definition_of_ready_gate_passed ambient event"
rm -f "$TMP/repo/.chump-locks/ambient.jsonl"

# ── Test 2: red preflight → refuse (this is the behavior the gap adds; ─────
#    without definition-of-ready-gate.sh existing at all, this test can't
#    even source/exec the script — proving it fails without the change) ────
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "preflight" ]] && exit 1
exit 0
EOF
chmod +x "$TMP/bin/chump"
PATH="$TMP/bin:$PATH" run_in_tmp_repo "CREDIBLE-270"
rc=$?
[[ $rc -eq 21 ]] && ok "red chump preflight → exit 21 (PR refused)" || fail "expected exit 21, got $rc"
grep -q '"kind":"definition_of_ready_gate_blocked"' "$TMP/repo/.chump-locks/ambient.jsonl" 2>/dev/null \
    && ok "emits definition_of_ready_gate_blocked" \
    || fail "missing definition_of_ready_gate_blocked ambient event"
rm -f "$TMP/repo/.chump-locks/ambient.jsonl"

# ── Test 3: CHUMP_DOR_DISABLE=1 → no-op even with red preflight ────────────
CHUMP_DOR_DISABLE=1 PATH="$TMP/bin:$PATH" run_in_tmp_repo "CREDIBLE-270"
rc=$?
[[ $rc -eq 0 ]] && ok "CHUMP_DOR_DISABLE=1 → exit 0 (gate disabled)" || fail "expected exit 0, got $rc"

# ── Test 4: bypass requested without --skip-reason → refused ───────────────
CHUMP_DOR_SKIP=1 PATH="$TMP/bin:$PATH" run_in_tmp_repo "CREDIBLE-270"
rc=$?
[[ $rc -eq 22 ]] && ok "CHUMP_DOR_SKIP=1 without --skip-reason → exit 22" || fail "expected exit 22, got $rc"

# ── Test 5: bypass with --skip-reason → allowed, audit-logged ──────────────
CHUMP_DOR_SKIP=1 PATH="$TMP/bin:$PATH" run_in_tmp_repo "CREDIBLE-270" --skip-reason "testing bypass"
rc=$?
[[ $rc -eq 0 ]] && ok "CHUMP_DOR_SKIP=1 with --skip-reason → exit 0" || fail "expected exit 0, got $rc"
grep -q '"kind":"definition_of_ready_bypassed"' "$TMP/repo/.chump-locks/ambient.jsonl" 2>/dev/null \
    && ok "emits definition_of_ready_bypassed with reason" \
    || fail "missing definition_of_ready_bypassed ambient event"
rm -f "$TMP/repo/.chump-locks/ambient.jsonl"

# ── Test 6: no `chump` on PATH; `cargo fmt` fails → refuse via fallback ────
mkdir -p "$TMP/bin-no-chump"
cat > "$TMP/bin-no-chump/cargo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin-no-chump/cargo"
# Minimal PATH so neither the real `chump` nor real `cargo` leak in.
PATH="$TMP/bin-no-chump:/usr/bin:/bin" run_in_tmp_repo "CREDIBLE-270"
rc=$?
[[ $rc -eq 21 ]] && ok "no chump binary, cargo fmt fails → exit 21 (fallback path)" || fail "expected exit 21, got $rc"
rm -f "$TMP/repo/.chump-locks/ambient.jsonl"

# ── Test 7: neither `chump` nor `cargo` on PATH → no-op (nothing to verify) ─
PATH="/usr/bin:/bin" run_in_tmp_repo "CREDIBLE-270"
rc=$?
[[ $rc -eq 0 ]] && ok "no chump, no cargo → exit 0 (nothing local to verify)" || fail "expected exit 0, got $rc"

echo
if [[ $FAILED -eq 0 ]]; then
    echo "=== CREDIBLE-270 definition-of-ready-gate: ALL PASS ==="
    exit 0
else
    echo "=== CREDIBLE-270 definition-of-ready-gate: FAILURES ==="
    exit 1
fi
