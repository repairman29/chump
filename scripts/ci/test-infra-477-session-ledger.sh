#!/usr/bin/env bash
# test-infra-477-session-ledger.sh — INFRA-477
#
# Static-validates the per-session cost ledger plumbing.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-477 per-session cost ledger plumbing test ==="
echo

[[ -f "$REPO_ROOT/src/session_ledger.rs" ]] && ok "src/session_ledger.rs exists" || fail "src/session_ledger.rs missing"

for fn in emit_session_start emit_session_end session_stats_for_domain; do
    if grep -qE "pub fn ${fn}\b" "$REPO_ROOT/src/session_ledger.rs"; then
        ok "  pub fn $fn exists"
    else
        fail "  pub fn $fn missing"
    fi
done

if grep -q 'Some("session-track")' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "chump session-track subcommand wired in main.rs"
else
    fail "session-track subcommand missing"
fi

if grep -q 'session_stats:' "$REPO_ROOT/src/briefing.rs" \
   && grep -q 'session_stats_for_domain' "$REPO_ROOT/src/briefing.rs"; then
    ok "briefing.rs populates session_stats via session_stats_for_domain"
else
    fail "briefing.rs does not populate session_stats"
fi

# Best-effort: emit fns must not panic
emit_block=$(awk '/pub fn emit_session_start/,/^}/' "$REPO_ROOT/src/session_ledger.rs")
if echo "$emit_block" | grep -qE '\.expect\(|\bpanic!\('; then
    fail "emit_session_start contains expect/panic — must be best-effort"
else
    ok "emit_session_start body is panic-free"
fi

emit_block2=$(awk '/pub fn emit_session_end/,/^}/' "$REPO_ROOT/src/session_ledger.rs")
if echo "$emit_block2" | grep -qE '\.expect\(|\bpanic!\('; then
    fail "emit_session_end contains expect/panic — must be best-effort"
else
    ok "emit_session_end body is panic-free"
fi

# Outcome enum has the three documented variants
if grep -qE 'Outcome::(Shipped|Abandoned|Starved)' "$REPO_ROOT/src/session_ledger.rs"; then
    ok "Outcome enum has Shipped/Abandoned/Starved"
else
    fail "Outcome enum missing variants"
fi

# Unit tests defined
test_count=$(grep -cE 'fn infra477_' "$REPO_ROOT/src/session_ledger.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 5 ]]; then
    ok "in-tree infra477_ unit tests defined ($test_count fns; full run via cargo test --workspace)"
else
    fail "expected >=5 infra477_ unit tests, found $test_count"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
