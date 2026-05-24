#!/usr/bin/env bash
# scripts/ci/test-daily-self-productize.sh — META-098
#
# Smoke test for the daily self-productize wave daemon.
# Mocks broadcast.sh; verifies:
#   1. Script exists, executable, parses, META attribution
#   2. Bypass env short-circuits silently
#   3. 6 curator roles all paged on first run
#   4. ambient.jsonl receives kind=daily_self_productize_wave
#   5. Idempotent on same-day rerun (no double-page)
#   6. New date → fires again

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/scripts/coord/daily-self-productize.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$TARGET" ]] || fail "$TARGET missing"
[[ -x "$TARGET" ]] || fail "$TARGET not executable"
bash -n "$TARGET" || fail "syntax error"
ok "script exists, executable, parses"

grep -q 'META-098' "$TARGET" || fail "no META-098 attribution"
ok "META-098 attribution present"

grep -q 'CHUMP_DAILY_PRODUCTIZE_DISABLED' "$TARGET" || fail "no bypass env"
ok "bypass env present"

grep -q 'daily_self_productize_wave' "$TARGET" || fail "no daily_self_productize_wave kind"
ok "emits kind=daily_self_productize_wave"

# ── Synthetic harness ──────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SYN="$TMP/syn-repo"
mkdir -p "$SYN/scripts/coord" "$SYN/.chump-locks"
(cd "$SYN" && git init -q)
cp "$TARGET" "$SYN/scripts/coord/daily-self-productize.sh"

# Mock broadcast.sh — records ONE line per call (just the --to arg) so
# wc -l on the log = page count. Multi-line message bodies otherwise
# inflate the line count.
BCAST_LOG="$TMP/broadcasts.log"
touch "$BCAST_LOG"
cat > "$SYN/scripts/coord/broadcast.sh" <<'MOCK'
#!/usr/bin/env bash
# Parse out --to <recipient> to record one line per call.
to=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --to) to="$2"; shift 2 ;;
        *) shift ;;
    esac
done
echo "BROADCAST to=$to" >> "BCAST_LOG_PLACEHOLDER"
exit 0
MOCK
# Inject the actual log path now (couldn't expand inside the unquoted heredoc)
sed -i.bak "s|BCAST_LOG_PLACEHOLDER|${BCAST_LOG}|" "$SYN/scripts/coord/broadcast.sh"
rm -f "$SYN/scripts/coord/broadcast.sh.bak"
chmod +x "$SYN/scripts/coord/broadcast.sh"

AMBIENT="$SYN/.chump-locks/ambient.jsonl"
touch "$AMBIENT"

# ── (2) Bypass env short-circuits ──────────────────────────────────────────
out_bypass=$(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_DAILY_PRODUCTIZE_DISABLED=1 \
    bash scripts/coord/daily-self-productize.sh 2>&1)
if [[ -z "$out_bypass" && ! -s "$BCAST_LOG" ]]; then
    ok "CHUMP_DAILY_PRODUCTIZE_DISABLED=1 short-circuits silently"
else
    fail "bypass did not short-circuit; got: $out_bypass / broadcasts=$(cat $BCAST_LOG)"
fi

# ── (3) First run pages all 6 roles ────────────────────────────────────────
> "$BCAST_LOG"
(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_SELF_PRODUCTIZE_DATE_OVERRIDE=2026-05-24 \
    bash scripts/coord/daily-self-productize.sh >/dev/null 2>&1)
broadcast_count=$(wc -l < "$BCAST_LOG" | tr -d ' ')
if [[ "$broadcast_count" -eq 6 ]]; then
    ok "first run pages 6 curators"
else
    fail "first run expected 6 broadcasts, got $broadcast_count; log: $(cat $BCAST_LOG)"
fi

# Confirm all 6 roles paged
for role in target handoff ci-audit shepherd decompose md-links; do
    grep -q "curator-opus-$role-2026-05-24" "$BCAST_LOG" \
        || fail "first run missing page for $role"
done
ok "all 6 roles paged (target/handoff/ci-audit/shepherd/decompose/md-links)"

# ── (4) Ambient kind emitted ───────────────────────────────────────────────
if grep -q '"kind":"daily_self_productize_wave"' "$AMBIENT"; then
    ok "ambient receives kind=daily_self_productize_wave"
else
    fail "no daily_self_productize_wave event in ambient.jsonl; got: $(cat $AMBIENT)"
fi

# ── (5) Idempotent on same-day rerun ───────────────────────────────────────
> "$BCAST_LOG"
out_idem=$(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_SELF_PRODUCTIZE_DATE_OVERRIDE=2026-05-24 \
    bash scripts/coord/daily-self-productize.sh 2>&1)
broadcast_count2=$(wc -l < "$BCAST_LOG" | tr -d ' ')
if [[ "$broadcast_count2" -eq 0 ]] && echo "$out_idem" | grep -q "already fired"; then
    ok "idempotent: same-day rerun is no-op"
else
    fail "idempotent test failed; got $broadcast_count2 broadcasts; output: $out_idem"
fi

# ── (6) New date → fires again ─────────────────────────────────────────────
> "$BCAST_LOG"
(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_SELF_PRODUCTIZE_DATE_OVERRIDE=2026-05-25 \
    bash scripts/coord/daily-self-productize.sh >/dev/null 2>&1)
broadcast_count3=$(wc -l < "$BCAST_LOG" | tr -d ' ')
if [[ "$broadcast_count3" -eq 6 ]]; then
    ok "new date → fires again (6 broadcasts on 2026-05-25)"
else
    fail "new date expected 6 broadcasts, got $broadcast_count3"
fi

echo ""
echo "ALL META-098 daily-self-productize assertions passed."
