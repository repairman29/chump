#!/usr/bin/env bash
# scripts/ci/test-merge-sla-scorecard.sh — RESILIENT-302

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/merge-sla-scorecard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing or not executable"

# Fake gh: scripted open-PR list keyed off created_at.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view") echo "fake/repo"; exit 0 ;;
    "api repos/fake/repo/pulls?state=open"*)
        cat "${FAKE_LIST_FILE:-/dev/null}" 2>/dev/null
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

mkdir -p "$TMP/repo/scripts/coord" "$TMP/repo/.chump-locks"
cp "$SCRIPT" "$TMP/repo/scripts/coord/merge-sla-scorecard.sh"
cp -r "$REPO_ROOT/scripts/coord/lib" "$TMP/repo/scripts/coord/lib"
chmod +x "$TMP/repo/scripts/coord/merge-sla-scorecard.sh"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.email=t@t -c user.name=t add -A
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q -m s

# old unowned PR (created 2h ago) → BREACH (clear of the 60m default threshold)
old_ts="$(date -u -v -2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
echo "100|$old_ts|feat(INFRA-3001): old unowned PR|chump/foo" > "$TMP/list.json"
# fresh PR (5m ago) → SKIPPED (under threshold)
fresh_ts="$(date -u -v -5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
echo "200|$fresh_ts|feat(INFRA-3002): fresh PR|chump/bar" >> "$TMP/list.json"
# old owned PR (has an active claim lease) → SKIPPED (owned)
echo "300|$old_ts|feat(INFRA-3003): old owned PR|chump/baz" >> "$TMP/list.json"
mkdir -p "$TMP/repo/.chump-locks"
echo '{"session_id":"worker-9"}' > "$TMP/repo/.chump-locks/claim-infra-3003-abc.json"

export FAKE_LIST_FILE="$TMP/list.json"

# ── Test 1: dry-run identifies only the unowned breach ─────────────────────
out=$(cd "$TMP/repo" && bash scripts/coord/merge-sla-scorecard.sh 2>&1)
echo "$out" | grep -q "WOULD BREACH #100" \
    || fail "expected to flag #100 as breach: $out"
if echo "$out" | grep -q "WOULD BREACH #200"; then
    fail "fresh PR (#200) must be skipped (under threshold)"
fi
if echo "$out" | grep -q "WOULD BREACH #300"; then
    fail "owned PR (#300) must be skipped (has claim lease owner)"
fi
echo "$out" | grep -q "OWNED #300" || fail "expected #300 reported as OWNED: $out"
ok "identifies only the unowned breach; skips fresh + owned"

# ── Test 2: --apply emits sla_breach ambient + writes dedup stamp ──────────
out2=$(cd "$TMP/repo" && bash scripts/coord/merge-sla-scorecard.sh --apply 2>&1)
echo "$out2" | grep -q "BREACH #100" \
    || fail "apply mode should breach #100: $out2"
[ -f "$TMP/repo/.chump-locks/.sla-breach-sent/100.ts" ] \
    || fail "dedup stamp missing after apply"
grep -q '"kind":"sla_breach"' "$TMP/repo/.chump-locks/ambient.jsonl" \
    || fail "sla_breach event not written to ambient.jsonl"
grep -q '"pr":100' "$TMP/repo/.chump-locks/ambient.jsonl" \
    || fail "sla_breach event missing pr field"
ok "--apply emits sla_breach ambient event + writes dedup stamp"

# ── Test 3: re-run within cooldown skips re-paging but still counts ────────
out3=$(cd "$TMP/repo" && bash scripts/coord/merge-sla-scorecard.sh --apply 2>&1)
echo "$out3" | grep -q "skipped-dedup=1" \
    || fail "second run should report 1 skipped via dedup: $out3"
ok "dedup cooldown prevents re-paging"

# ── Test 4: cooldown=0 → resend allowed ─────────────────────────────────────
out4=$(cd "$TMP/repo" && bash scripts/coord/merge-sla-scorecard.sh --apply --cooldown 0 2>&1)
echo "$out4" | grep -q "escalated=1" \
    || fail "--cooldown 0 must let resend through: $out4"
ok "--cooldown 0 disables dedup"

# ── Test 5: scorecard reports p50/p90, threshold defaults to 60m ───────────
echo "$out4" | grep -q "threshold_s=3600" \
    || fail "expected default threshold_s=3600 (60m, CHUMP_SLA_BREACH_MINUTES default): $out4"
echo "$out4" | grep -Eq "p50_s=[0-9]+ p90_s=[0-9]+" \
    || fail "expected p50_s/p90_s in scorecard output: $out4"
ok "scorecard reports p50/p90 and defaults threshold to 60m"

# ── Test 6: CHUMP_SLA_BREACH_MINUTES overrides the threshold ───────────────
out5=$(cd "$TMP/repo" && CHUMP_SLA_BREACH_MINUTES=15 bash scripts/coord/merge-sla-scorecard.sh 2>&1)
echo "$out5" | grep -q "threshold_s=900" \
    || fail "CHUMP_SLA_BREACH_MINUTES=15 should set threshold_s=900: $out5"
ok "CHUMP_SLA_BREACH_MINUTES overrides threshold_s"

echo
echo "All RESILIENT-302 merge-sla-scorecard tests passed."
