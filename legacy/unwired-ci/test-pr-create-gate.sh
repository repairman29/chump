#!/usr/bin/env bash
# scripts/ci/test-pr-create-gate.sh — INFRA-1219
#
# Tests the pr-create-gate.sh dedup gate. No live gh API calls — we stub
# `gh` via a PATH override so the gate sees synthetic open-PR data.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$REPO_ROOT/scripts/coord/pr-create-gate.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$GATE" ]] || fail "gate script missing or not executable"
ok "scripts/coord/pr-create-gate.sh exists and is executable"

# Test 1: usage errors
"$GATE" 2>/dev/null
rc=$?
[[ "$rc" == "2" ]] || fail "missing GAP-ID should exit 2 (got $rc)"
ok "missing GAP-ID → exit 2"

"$GATE" "not-a-gap-id" 2>/dev/null
rc=$?
[[ "$rc" == "2" ]] || fail "malformed GAP-ID should exit 2 (got $rc)"
ok "malformed GAP-ID → exit 2"

# Test 2: gh stub returning no duplicates → exit 0
TMP=$(mktemp -d -t pr-gate-test-XXXX)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/gh" <<'GHSTUB'
#!/bin/bash
# Stub: return empty list (no open PRs)
case "$*" in
    *"pulls?state=open"*) printf '' ;;
    *) printf '' ;;
esac
GHSTUB
chmod +x "$TMP/gh"

PATH="$TMP:$PATH" CHUMP_PR_DEDUP_DISABLE=0 "$GATE" "INFRA-9999" >/dev/null 2>&1
rc=$?
[[ "$rc" == "0" ]] || fail "no duplicates should exit 0 (got $rc)"
ok "no open duplicate → exit 0"

# Test 3: gh stub returning a matching open PR → exit 19 (refusal)
cat > "$TMP/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
    *"pulls?state=open"*)
        # Return TSV: number, title
        printf '1234\tfeat(INFRA-9999): RESILIENT — test\n'
        ;;
    *) printf '' ;;
esac
GHSTUB
chmod +x "$TMP/gh"

err_log="$TMP/err.log"
PATH="$TMP:$PATH" CHUMP_PR_DEDUP_DISABLE=0 "$GATE" "INFRA-9999" >/dev/null 2>"$err_log"
rc=$?
[[ "$rc" == "19" ]] || fail "open duplicate should exit 19 (got $rc); stderr: $(cat $err_log)"
grep -q "duplicate PR for INFRA-9999" "$err_log" || fail "error message missing duplicate-PR notice"
grep -q "#1234" "$err_log" || fail "error message missing existing PR number"
ok "open duplicate → exit 19 with clear refusal message"

# Test 4: word-boundary discipline — INFRA-99 should NOT match INFRA-9999
cat > "$TMP/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
    *"pulls?state=open"*)
        # Title contains INFRA-9999, query is for INFRA-99
        printf '1234\tfeat(INFRA-9999): RESILIENT — test\n'
        ;;
    *) printf '' ;;
esac
GHSTUB
chmod +x "$TMP/gh"

PATH="$TMP:$PATH" CHUMP_PR_DEDUP_DISABLE=0 "$GATE" "INFRA-99" >/dev/null 2>&1
rc=$?
[[ "$rc" == "0" ]] || fail "word-boundary check: INFRA-99 query should NOT match INFRA-9999 title (got $rc)"
ok "word-boundary: INFRA-99 ≠ INFRA-9999"

# Test 5: CHUMP_PR_DEDUP_BYPASS=1 without --justification → exit 20
cat > "$TMP/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
    *"pulls?state=open"*) printf '1234\tfeat(INFRA-9999): test\n' ;;
    *) printf '' ;;
esac
GHSTUB
chmod +x "$TMP/gh"

err_log="$TMP/err2.log"
PATH="$TMP:$PATH" CHUMP_PR_DEDUP_DISABLE=0 CHUMP_PR_DEDUP_BYPASS=1 "$GATE" "INFRA-9999" >/dev/null 2>"$err_log"
rc=$?
[[ "$rc" == "20" ]] || fail "bypass without justification should exit 20 (got $rc)"
grep -q "no --justification" "$err_log" || fail "missing 'no --justification' message"
ok "bypass without --justification → exit 20"

# Test 6: CHUMP_PR_DEDUP_BYPASS=1 + --justification → exit 0
PATH="$TMP:$PATH" CHUMP_PR_DEDUP_DISABLE=0 CHUMP_PR_DEDUP_BYPASS=1 \
    "$GATE" "INFRA-9999" --justification "rare operator-confirmed exception" >/dev/null 2>&1
rc=$?
[[ "$rc" == "0" ]] || fail "bypass with --justification should exit 0 (got $rc)"
ok "bypass with --justification → exit 0"

# Test 7: CHUMP_PR_DEDUP_DISABLE=1 short-circuits to exit 0 (CI/test mode)
PATH="$TMP:$PATH" CHUMP_PR_DEDUP_DISABLE=1 "$GATE" "INFRA-9999" >/dev/null 2>&1
rc=$?
[[ "$rc" == "0" ]] || fail "DISABLE=1 should short-circuit to exit 0 (got $rc)"
ok "CHUMP_PR_DEDUP_DISABLE=1 short-circuits"

# Test 8: wired into bot-merge.sh
grep -q 'INFRA-1219' "$REPO_ROOT/scripts/coord/bot-merge.sh" \
    || fail "bot-merge.sh does not reference INFRA-1219 dedup gate"
grep -q 'pr-create-gate.sh' "$REPO_ROOT/scripts/coord/bot-merge.sh" \
    || fail "bot-merge.sh does not invoke pr-create-gate.sh"
ok "bot-merge.sh invokes pr-create-gate.sh before gh pr create"

# Test 9: EVENT_REGISTRY registers all 3 kinds
ER="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
for kind in pr_dedup_blocked pr_dedup_bypassed pr_dedup_bypass_rejected; do
    grep -q "^  - kind: $kind" "$ER" || fail "EVENT_REGISTRY missing kind=$kind"
done
ok "EVENT_REGISTRY registers all 3 dedup kinds"

# Test 10: ambient event format check — emit and verify shape
TMP_AMB="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$TMP_AMB")"
cat > "$TMP/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
    *"pulls?state=open"*) printf '1234\tfeat(INFRA-9999): test\n' ;;
    *) printf '' ;;
esac
GHSTUB
chmod +x "$TMP/gh"

# Invoke from a fake repo root so AMBIENT lands at our temp location
mkdir -p "$TMP/repo"
cd "$TMP/repo" && git init -q -b main >/dev/null
ln -s "$TMP/.chump-locks" "$TMP/repo/.chump-locks"
PATH="$TMP:$PATH" CHUMP_PR_DEDUP_DISABLE=0 "$GATE" "INFRA-9999" >/dev/null 2>&1 || true
[[ -f "$TMP_AMB" ]] || fail "no ambient event written"
grep -q '"kind":"pr_dedup_blocked"' "$TMP_AMB" || fail "ambient event missing kind=pr_dedup_blocked"
grep -q '"gap":"INFRA-9999"' "$TMP_AMB" || fail "ambient event missing gap field"
grep -q '"dup_pr":1234' "$TMP_AMB" || fail "ambient event missing dup_pr field"
ok "ambient event has correct shape (kind, gap, dup_pr)"

echo
echo "All INFRA-1219 pr-create-gate tests passed."
