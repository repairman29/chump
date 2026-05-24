#!/usr/bin/env bash
# scripts/ci/test-pr-pulse-consumer.sh — INFRA-1898
#
# Smoke test for the pulse consumer daemon.
# (1) HEALTHY snapshot → no broadcast emitted
# (2) WEDGED snapshot → broadcast paged to 6 curators
# (3) SATURATED snapshot → operator-recall path invoked
# (4) Throttle blocks re-action within window
# (5) Bypass env short-circuits silently
# (6) Missing/empty ambient log → graceful no-op

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/scripts/coord/pr-pulse-consumer.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$TARGET" ]] || fail "$TARGET missing"
[[ -x "$TARGET" ]] || fail "$TARGET not executable"
bash -n "$TARGET" || fail "syntax error"
ok "script exists, executable, parses"

# ── Structural ─────────────────────────────────────────────────────────────
grep -q 'CHUMP_PULSE_CONSUMER_DISABLED' "$TARGET" || fail "no bypass env"
ok "bypass env present"

grep -q 'pr_oversight_snapshot' "$TARGET" || fail "no pr_oversight_snapshot consumer"
ok "consumes pr_oversight_snapshot"

grep -q 'CHUMP_PULSE_CONSUMER_THROTTLE_MIN' "$TARGET" || fail "no throttle env"
ok "throttle env present"

grep -q 'INFRA-1898' "$TARGET" || fail "no INFRA-1898 attribution"
ok "INFRA-1898 attribution present"

# ── Synthetic harness ──────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SYN="$TMP/syn-repo"
mkdir -p "$SYN/scripts/coord" "$SYN/scripts/dispatch" "$SYN/.chump-locks"
(cd "$SYN" && git init -q)
cp "$TARGET" "$SYN/scripts/coord/pr-pulse-consumer.sh"

# Mock broadcast.sh (records pages to a log)
BCAST_LOG="$TMP/broadcasts.log"
touch "$BCAST_LOG"
cat > "$SYN/scripts/coord/broadcast.sh" <<MOCK
#!/usr/bin/env bash
echo "BROADCAST \$*" >> "$BCAST_LOG"
exit 0
MOCK
chmod +x "$SYN/scripts/coord/broadcast.sh"

# Mock operator-recall.sh (records calls)
RECALL_LOG="$TMP/recalls.log"
touch "$RECALL_LOG"
cat > "$SYN/scripts/dispatch/operator-recall.sh" <<MOCK
#!/usr/bin/env bash
echo "RECALL \$*" >> "$RECALL_LOG"
exit 0
MOCK
chmod +x "$SYN/scripts/dispatch/operator-recall.sh"

AMBIENT="$SYN/.chump-locks/ambient.jsonl"
STATE="$SYN/.chump-locks/pr-pulse-consumer-state.jsonl"

# ── (1) HEALTHY → no action ────────────────────────────────────────────────
printf '{"ts":"%s","kind":"pr_oversight_snapshot","verdict":"HEALTHY"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AMBIENT"
> "$BCAST_LOG"; > "$RECALL_LOG"
(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_CONSUMER_DATE_OVERRIDE=2026-05-24 bash scripts/coord/pr-pulse-consumer.sh) >/dev/null 2>&1
if [[ -s "$BCAST_LOG" || -s "$RECALL_LOG" ]]; then
    fail "HEALTHY emitted unexpected actions; broadcasts=$(cat $BCAST_LOG) recalls=$(cat $RECALL_LOG)"
fi
ok "HEALTHY → no broadcasts, no recalls"

# ── (2) WEDGED → 6 broadcasts ──────────────────────────────────────────────
printf '{"ts":"%s","kind":"pr_oversight_snapshot","verdict":"WEDGED","dirty":5}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AMBIENT"
> "$BCAST_LOG"; > "$RECALL_LOG"; > "$STATE"
(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_CONSUMER_DATE_OVERRIDE=2026-05-24 bash scripts/coord/pr-pulse-consumer.sh) >/dev/null 2>&1
broadcast_count=$(wc -l < "$BCAST_LOG" | tr -d ' ')
if [[ "$broadcast_count" -eq 6 ]]; then
    ok "WEDGED → 6 curators paged"
else
    fail "WEDGED expected 6 broadcasts, got $broadcast_count"
fi
# Confirm all 6 roles
for role in target handoff ci-audit shepherd decompose md-links; do
    grep -q "curator-opus-$role-2026-05-24" "$BCAST_LOG" \
        || fail "WEDGED missing page for $role"
done
ok "WEDGED → all 6 roles paged (target/handoff/ci-audit/shepherd/decompose/md-links)"

# ── (3) Throttle blocks re-WEDGED within window ────────────────────────────
> "$BCAST_LOG"
(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_CONSUMER_DATE_OVERRIDE=2026-05-24 bash scripts/coord/pr-pulse-consumer.sh) >/dev/null 2>&1
broadcast_count2=$(wc -l < "$BCAST_LOG" | tr -d ' ')
if [[ "$broadcast_count2" -eq 0 ]]; then
    ok "throttle → second WEDGED suppressed"
else
    fail "throttle did not fire; got $broadcast_count2 broadcasts on second run"
fi

# ── (4) SATURATED → operator-recall fires ──────────────────────────────────
printf '{"ts":"%s","kind":"pr_oversight_snapshot","verdict":"SATURATED","open":15}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AMBIENT"
> "$BCAST_LOG"; > "$RECALL_LOG"; > "$STATE"
(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_CONSUMER_DATE_OVERRIDE=2026-05-24 bash scripts/coord/pr-pulse-consumer.sh) >/dev/null 2>&1
if grep -q "QUEUE_SATURATED" "$RECALL_LOG"; then
    ok "SATURATED → operator-recall called with QUEUE_SATURATED condition"
else
    fail "SATURATED did not invoke operator-recall; got: $(cat $RECALL_LOG)"
fi

# ── (5) Bypass env short-circuits ──────────────────────────────────────────
> "$BCAST_LOG"; > "$RECALL_LOG"; > "$STATE"
out_bypass=$(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_PULSE_CONSUMER_DISABLED=1 bash scripts/coord/pr-pulse-consumer.sh 2>&1)
if [[ -z "$out_bypass" && ! -s "$BCAST_LOG" && ! -s "$RECALL_LOG" ]]; then
    ok "CHUMP_PULSE_CONSUMER_DISABLED=1 short-circuits silently"
else
    fail "bypass did not short-circuit; got: $out_bypass"
fi

# ── (6) Missing ambient → graceful no-op ───────────────────────────────────
out_missing=$(cd "$SYN" && CHUMP_AMBIENT_LOG="$TMP/does-not-exist.jsonl" bash scripts/coord/pr-pulse-consumer.sh 2>&1)
if echo "$out_missing" | grep -q "ambient log missing"; then
    ok "missing ambient log → graceful no-op"
else
    fail "missing ambient handling broken; got: $out_missing"
fi

echo ""
echo "ALL INFRA-1898 pr-pulse-consumer assertions passed."
