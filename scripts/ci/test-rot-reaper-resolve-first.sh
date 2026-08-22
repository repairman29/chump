#!/usr/bin/env bash
# test-rot-reaper-resolve-first.sh — RESILIENT-339 (resolve-first guard)
#
# Proves the rot-reaper NEVER discards a savable CONFLICTING PR: it reaps a
# CONFLICTING branch ONLY after the standing conflict-resolution-consumer
# (RESILIENT-301) has ALREADY tried and given up on it — attempts exhausted
# (>= CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS) or an operator escalation recorded
# in the per-PR state file. Until then the PR is handed off (the reaper emits
# armed_pr_needs_conflict_resolution, which the consumer drains) and the reap
# is DEFERRED — so a resolvable PR is only ever MERGED or sent-to-rework,
# never closed while resolution is still possible.
#
# Runs scripts/ops/rot-reaper.sh in --dry-run against synthetic PR fixtures
# with the conflict-attempt state dir pinned to a temp dir (no live GitHub).
# This test FAILS on pre-RESILIENT-339 reaper code (which reaps every old
# CONFLICTING PR unconditionally, with no hand-off/defer path).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/rot-reaper.sh"
[[ -f "$REAPER" ]] || { echo "FAIL: $REAPER not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

iso() { python3 -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)-timedelta(hours=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
OLD="$(iso 12)"     # past the 4h conflict age gate
REQ='audit-required'

# Conflict-attempt state dir the reaper consults (mirrors what the
# conflict-resolution-consumer writes). Seed genuinely-unresolvable PRs.
CSTATE="$TMP/conflict-state"; mkdir -p "$CSTATE"
export CHUMP_ROT_REAPER_CONFLICT_STATE_DIR="$CSTATE"
# #302: consumer tried MAX times and could not resolve → genuinely unresolvable
printf '{"pr":302,"attempts":3,"first_seen":"2026-08-20T00:00:00Z"}\n' > "$CSTATE/302.json"
# #303: consumer escalated to the operator → genuinely unresolvable
printf '{"pr":303,"attempts":3,"first_seen":"2026-08-20T00:00:00Z","escalated_at":"2026-08-20T04:00:00Z"}\n' > "$CSTATE/303.json"
# #304: consumer has one attempt logged, not yet exhausted → still savable
printf '{"pr":304,"attempts":1,"first_seen":"2026-08-21T00:00:00Z"}\n' > "$CSTATE/304.json"

FIX="$TMP/prs.json"
cat > "$FIX" <<EOF
[
  {"number":301,"title":"RESILIENT-800: conflicting, old, NO resolution attempt yet","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$OLD","headRefName":"rs-800","isDraft":false,"autoMergeRequest":null,"statusCheckRollup":[]},
  {"number":302,"title":"RESILIENT-801: conflicting, old, resolution EXHAUSTED (attempts>=max)","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$OLD","headRefName":"rs-801","isDraft":false,"autoMergeRequest":null,"statusCheckRollup":[]},
  {"number":303,"title":"RESILIENT-802: conflicting, old, resolution ESCALATED","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$OLD","headRefName":"rs-802","isDraft":false,"autoMergeRequest":null,"statusCheckRollup":[]},
  {"number":304,"title":"RESILIENT-803: conflicting, old, ONE attempt (not exhausted)","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$OLD","headRefName":"rs-803","isDraft":false,"autoMergeRequest":null,"statusCheckRollup":[]}
]
EOF

out="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" bash "$REAPER" --dry-run 2>&1)"
echo "$out"
echo "---"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# #301: no resolution attempt yet → HANDED OFF + DEFERRED, NOT reaped
echo "$out" | grep -q 'PR #301 — CONFLICTING, .*conflict-resolution NOT yet exhausted' && ok "#301 savable → handed off + deferred" || bad "#301 not deferred"
echo "$out" | grep -q 'would hand PR #301 (rs-800) to conflict-resolution-consumer' && ok "#301 hand-off to consumer logged" || bad "#301 hand-off not logged"
echo "$out" | grep -qE 'PR #301 .*→ REAP' && bad "#301 wrongly reaped while savable" || ok "#301 not reaped"

# #302: attempts>=max → genuinely unresolvable → REAPED
echo "$out" | grep -qE 'PR #302 — CONFLICTING, .*EXHAUSTED.*→ REAP' && ok "#302 exhausted → reaped" || bad "#302 not reaped after exhaustion"

# #303: escalated → genuinely unresolvable → REAPED
echo "$out" | grep -qE 'PR #303 — CONFLICTING, .*EXHAUSTED.*→ REAP' && ok "#303 escalated → reaped" || bad "#303 not reaped after escalation"

# #304: one attempt, not exhausted → still savable → DEFERRED, NOT reaped
echo "$out" | grep -q 'PR #304 — CONFLICTING, .*conflict-resolution NOT yet exhausted' && ok "#304 not-yet-exhausted → deferred" || bad "#304 not deferred"
echo "$out" | grep -qE 'PR #304 .*→ REAP' && bad "#304 wrongly reaped (attempts < max)" || ok "#304 not reaped"

# Net: exactly the two genuinely-unresolvable PRs closed; the two savable ones deferred.
echo "$out" | grep -q 'closed=2' && ok "exactly two closed (only the genuinely-unresolvable pair)" || bad "close count wrong (expected 2)"

echo ""
echo "=== rot-reaper resolve-first: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]]
