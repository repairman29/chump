#!/usr/bin/env bash
# test-rot-reaper-systemic-red-hold.sh — RESILIENT-1188 (systemic-red guard)
#
# #4637 taught the rot-reaper's CLASS 2 to SPARE an INDIVIDUAL PR whose real
# gates are green underneath a red `verified` aggregate. But when a SHARED /
# trunk gate breaks, the required aggregate goes RED across MANY open PRs at
# once — each with a genuine COMPLETED failure on that gate — so #4637's per-PR
# classifier reads every one as hard_fail and the reaper closes them ALL. That
# is the fleet-wide self-strangle (INFRA-3542 / auto-rescue-reaps-systemic-red):
# none of those PRs did anything wrong individually; the redness is not theirs.
#
# RESILIENT-1188 adds the BROADER guard: BEFORE closing a required-red PR, detect
# whether the redness is SYSTEMIC — the SAME required gate is failing across
# >= CHUMP_ROT_REAPER_SYSTEMIC_THRESHOLD distinct open PRs (the W-015 grouping
# reused from scripts/coord/systemic-red-detector.sh), OR the trunk-sentinel
# (scripts/coord/trunk-sentinel-daemon.sh) reports main RED in ambient.jsonl —
# and if so HOLD every affected PR (re-arm, never close) + page the operator,
# so a real trunk-red gets a human instead of mass-closure. Only a genuinely
# INDIVIDUAL hard-fail (its red gate not shared, main not red) is still reaped.
#
# This test drives the REAL reaper against its own selection logic
# (CHUMP_ROT_REAPER_PR_JSON fixture, gh/chump stubbed, hermetic ambient) and
# proves all four directions:
#   • a required gate red across >= threshold PRs → those PRs are HELD (closed=0
#     for them), and a pr_reap_held_systemic event is emitted;
#   • a genuinely INDIVIDUAL hard-fail (gate red on ONE PR, main green) is still
#     CLOSED — the guard does not over-hold;
#   • when the trunk-sentinel reports main RED, EVEN an individual hard-fail is
#     HELD (main-red is systemic);
#   • raising the threshold above the shared count makes the same PRs close
#     again — the guard is threshold-driven, not a blanket hold.
# plus source-wiring + event-registration asserts.
#
# Depth tier: EDGE — decision-path fixtures across the systemic matrix (shared-
# gate / individual / main-red / threshold-gated) driven through the REAL reaper
# with stubbed gh/chump and a hermetic ambient log, plus source-wiring and
# EVENT_REGISTRY asserts. Gaps: does not spin up a live GitHub, a real `verified`
# aggregate run, the live trunk-sentinel daemon, or the auto-merge-armer /
# operator-page side effects (the re-arm + page glue is covered by source-wiring
# + the HOLD/close counts and the emitted event, not live delivery).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/rot-reaper.sh"
REGISTRY_YAML="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
DETECTOR="$REPO_ROOT/scripts/coord/systemic-red-detector.sh"
for f in "$REAPER" "$REGISTRY_YAML" "$DETECTOR"; do
    [[ -f "$f" ]] || { echo "FAIL: required file missing: $f"; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# ── stub gh + chump; unconfigure the operator notifier so it stays a no-op ─────
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "api" && "$2" == "user" ]] && { echo "repairman29"; exit 0; }
exit 0
EOF
cat > "$STUB/chump" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID 2>/dev/null || true

iso() { python3 -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)-timedelta(hours=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
iso_min() { python3 -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)-timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
OLD="$(iso 12)"   # past every age gate (realfail 8h)

# Required set covering the real gates. The SHARED break is on a real blocking
# gate (`cargo-test-required`, failing on two PRs — the fleet-wide-regression
# shape); the INDIVIDUAL failure is a different real gate (`clippy-required`,
# failing on one PR). Systemic-ness keys on the REAL gate, never the `verified`
# umbrella (which is red per-PR for mixed reasons).
REQ='verified,cargo-test-required,clippy-required,audit-required'

# Hermetic ambient + spare/flake state entirely inside TMP.
export NODE_AMBIENT="$TMP/ambient.jsonl"
export CHUMP_ROT_REAPER_SPARE_STATE_DIR="$TMP/spare-state"
export CHUMP_ROT_REAPER_FLAKE_COOLDOWN_DIR="$TMP/flake-cooldown"
: > "$NODE_AMBIENT"   # no trunk events → main NOT red for the first runs

# Rollups. A COMPLETED hard failure on a real blocking gate reads as hard_fail —
# exactly the case #4637 would close individually. #401/#402 SHARE the same
# broken blocking gate (cargo-test-required — a fleet-wide regression); #403
# fails a DIFFERENT real gate alone (clippy-required). `verified` (the aggregate)
# is red on all three but must NOT drive the systemic count.
SHARED='[{"name":"cargo-test-required","status":"COMPLETED","conclusion":"FAILURE"},{"name":"verified","status":"COMPLETED","conclusion":"FAILURE"}]'
SOLO='[{"name":"clippy-required","status":"COMPLETED","conclusion":"FAILURE"},{"name":"cargo-test-required","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"verified","status":"COMPLETED","conclusion":"FAILURE"}]'

FIX="$TMP/prs.json"
cat > "$FIX" <<EOF
[
  {"number":401,"title":"RESILIENT-1401: inherits the shared broken cargo-test-required gate","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-1401","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":$SHARED},
  {"number":402,"title":"RESILIENT-1402: inherits the same shared broken cargo-test-required gate","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-1402","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":$SHARED},
  {"number":403,"title":"RESILIENT-1403: its OWN clippy-required really failed (solo)","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-1403","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":$SOLO}
]
EOF

# ── RUN 1: shared gate on 2 PRs (threshold 2), main green ─────────────────────
# Expect: #401/#402 HELD (systemic), #403 CLOSED (individual). LIVE so the
# pr_reap_held_systemic event actually lands in ambient.
out="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" \
       CHUMP_ROT_REAPER_SYSTEMIC_THRESHOLD=2 bash "$REAPER" 2>&1)"
echo "$out"; echo "---"

for n in 401 402; do
    echo "$out" | grep -qE "HOLD PR #$n" && ok "#$n HELD (systemic shared gate, not closed)" || bad "#$n not held"
    echo "$out" | grep -qE "PR #$n .*→ REAP" && bad "#$n wrongly reaped (systemic redness)" || ok "#$n not reaped"
done
echo "$out" | grep -qE 'PR #403 .*hard-fail.*→ REAP' && ok "#403 individual hard-fail still REAPED" || bad "#403 individual hard-fail not reaped (would let a real solo failure rot)"
echo "$out" | grep -q 'closed=1' && ok "exactly one PR reaped (closed=1: only the individual hard-fail)" || bad "close count wrong (expected closed=1)"
echo "$out" | grep -q 'held=2'   && ok "exactly two PRs held (held=2: the shared-gate pair)"           || bad "held count wrong (expected held=2)"
# the HOLD event actually landed in ambient
grep -q '"kind":"pr_reap_held_systemic"' "$NODE_AMBIENT" && ok "pr_reap_held_systemic emitted to ambient" || bad "no pr_reap_held_systemic event emitted"
grep -q '"kind":"pr_reap_held_systemic".*"pr":401' "$NODE_AMBIENT" && ok "held event carries the PR number (401)" || bad "held event missing pr 401"

# ── RUN 2: trunk-sentinel reports main RED → even the individual hard-fail held ─
: > "$NODE_AMBIENT"
FRESH="$(iso_min 3)"
printf '{"ts":"%s","kind":"trunk_red_persistent","source":"trunk_sentinel_daemon","red_minutes":3,"failing_jobs":"cargo-test-required","run_id":9,"head_sha":"deadbeef"}\n' "$FRESH" >> "$NODE_AMBIENT"
out2="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" \
        CHUMP_ROT_REAPER_SYSTEMIC_THRESHOLD=2 bash "$REAPER" 2>&1)"
echo "$out2"; echo "---"
echo "$out2" | grep -q 'closed=0' && ok "main-red: NOTHING closed (closed=0) — trunk-red holds the whole required-red class" || bad "main-red run closed a PR (expected closed=0)"
echo "$out2" | grep -qE 'HOLD PR #403' && ok "main-red: even the individual hard-fail #403 is HELD" || bad "main-red did not hold the individual hard-fail #403"
echo "$out2" | grep -qiE 'main RED' && ok "main-red signal from trunk-sentinel consumed + surfaced" || bad "main-red signal not surfaced"

# ── RUN 3: stale trunk-red (older than the freshness window) is IGNORED ────────
: > "$NODE_AMBIENT"
STALE="$(iso_min 600)"   # 10h old, well past the 90m default window
printf '{"ts":"%s","kind":"trunk_red_persistent","source":"trunk_sentinel_daemon","red_minutes":600,"failing_jobs":"cargo-test-required","run_id":1,"head_sha":"old"}\n' "$STALE" >> "$NODE_AMBIENT"
out3="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" \
        CHUMP_ROT_REAPER_SYSTEMIC_THRESHOLD=2 bash "$REAPER" 2>&1)"
# stale main-red ignored → behaves like RUN 1 (shared pair held, individual closed)
echo "$out3" | grep -q 'closed=1' && ok "stale trunk-red ignored (closed=1, same as no-main-red)" || bad "stale trunk-red not ignored (closed != 1)"
echo "$out3" | grep -q 'held=2'   && ok "stale trunk-red ignored (held=2, only the shared pair)"   || bad "stale trunk-red changed hold count"

# ── RUN 4: threshold raised above the shared count → the guard does NOT hold ───
# Proves the HOLD is threshold-driven, not a blanket "never close required-red".
: > "$NODE_AMBIENT"
out4="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" \
        CHUMP_ROT_REAPER_SYSTEMIC_THRESHOLD=5 bash "$REAPER" 2>&1)"
echo "$out4" | grep -q 'held=0'   && ok "threshold 5 > shared count 2 → nothing held (held=0)"       || bad "guard held despite threshold above shared count"
echo "$out4" | grep -q 'closed=3' && ok "threshold 5: all three required-red PRs close individually (closed=3)" || bad "threshold-gated close count wrong (expected closed=3)"

echo ""
echo "=== reaper end-to-end: $pass passed so far ==="

# ── source-wiring asserts ─────────────────────────────────────────────────────
grep -q 'is_systemic_red'   "$REAPER" && ok "reaper: has is_systemic_red guard"                 || bad "reaper: no is_systemic_red guard"
grep -q 'hold_systemic_red' "$REAPER" && ok "reaper: has hold_systemic_red action"              || bad "reaper: no hold_systemic_red action"
grep -q 'SYSTEMIC_THRESHOLD' "$REAPER" && ok "reaper: threshold is tunable (SYSTEMIC_THRESHOLD)" || bad "reaper: no systemic threshold"
grep -q 'systemic-red-detector.sh' "$REAPER" && ok "reaper: reuses the W-015 definition (systemic-red-detector.sh cited)" || bad "reaper: does not reference the existing W-015 detector"
grep -q 'trunk_red_persistent' "$REAPER" && ok "reaper: consumes the trunk-sentinel main-red signal" || bad "reaper: does not consume the trunk-sentinel signal"
# There must be NO env toggle to DISABLE the systemic hold (safety must be unconditional).
grep -qE 'CHUMP_ROT_REAPER_SYSTEMIC_(DISABLED|OFF)' "$REAPER" && bad "reaper: a disable toggle for the systemic hold exists (forbidden — safety must be unconditional)" || ok "reaper: no disable toggle for the systemic hold (unconditional safety)"

# The systemic guard must precede the CLASS-2 close in source order.
_guard_line=$(grep -n 'is_systemic_red "\$PR_NUM"' "$REAPER" | head -1 | cut -d: -f1)
_close_line=$(grep -n 'label_and_close "\$PR_NUM" "\$MSG"' "$REAPER" | tail -1 | cut -d: -f1)
if [[ -n "$_guard_line" && -n "$_close_line" && "$_guard_line" -lt "$_close_line" ]]; then
    ok "systemic guard (L$_guard_line) precedes the CLASS-2 close (L$_close_line)"
else
    bad "systemic guard does not precede the close (guard=$_guard_line close=$_close_line)"
fi

# ── new event kind registered in EVENT_REGISTRY.yaml ──────────────────────────
grep -qE '^\s*-\s+kind:\s*pr_reap_held_systemic\b' "$REGISTRY_YAML" \
    && ok "event registered: pr_reap_held_systemic" \
    || bad "event NOT registered in EVENT_REGISTRY.yaml: pr_reap_held_systemic"

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "test-rot-reaper-systemic-red-hold: ALL $pass passed"
    exit 0
else
    echo "test-rot-reaper-systemic-red-hold: $pass passed, $fail failed"
    exit 1
fi
