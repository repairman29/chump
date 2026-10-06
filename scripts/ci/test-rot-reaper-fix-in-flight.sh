#!/usr/bin/env bash
# test-rot-reaper-fix-in-flight.sh — RESILIENT-1526
#
# The rot-reaper must not close a required-red PR whose fix is in flight:
#   • head commit pushed inside the grace window  → NOT reaped
#   • a check still queued/in_progress/pending     → NOT reaped
#   • settled red, last push older than the window → reaped (unchanged)
#   • grace disabled (FIX_GRACE_MIN=0), fresh push → reaped (push half off)
# Dry-run against a synthetic fixture with gh/chump stubbed; no live GitHub.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/rot-reaper.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/bin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\n[[ "$1" == "api" && "$2" == "user" ]] && { echo repairman29; exit 0; }\nexit 0\n' > "$STUB/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/chump"
chmod +x "$STUB"/*; export PATH="$STUB:$PATH"
export CHUMP_ROT_REAPER_CONFLICT_STATE_DIR="$TMP/cs"; mkdir -p "$TMP/cs"

iso_min() { python3 -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)-timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
OLD="$(iso_min 720)"; PUSHED_5M="$(iso_min 5)"; PUSHED_3H="$(iso_min 180)"
RED='{"name":"audit-required","conclusion":"FAILURE","status":"COMPLETED"}'
PEND='{"name":"audit-required","conclusion":null,"status":"IN_PROGRESS"}'
pr() { # num title rollup lastCommitDate
  printf '{"number":%s,"title":"RESILIENT-%s: x","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"%s","headRefName":"b-%s","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":[%s],"commits":[{"committedDate":"%s"}]}' \
    "$1" "$1" "$OLD" "$1" "$3" "$4"
}
cat > "$TMP/prs.json" <<J
[ $(pr 301 301 "$RED" "$PUSHED_5M"),
  $(pr 302 302 "$RED,$PEND" "$PUSHED_3H"),
  $(pr 303 303 "$RED" "$PUSHED_3H") ]
J
run() { CHUMP_ROT_REAPER_PR_JSON="$TMP/prs.json" CHUMP_ROT_REAPER_REQUIRED_CHECKS=audit-required "$@" bash "$REAPER" --dry-run 2>&1; }
out="$(run env)"
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; echo "$out"|grep -E "#30[123]"; fail=$((fail+1)); }
grep -q 'PR #301 .*fix is IN FLIGHT' <<<"$out" && ! grep -qE 'PR #301 .*→ REAP' <<<"$out" && ok "#301 pushed 5m ago: not reaped" || bad "#301 reaped/not held"
grep -q 'PR #302 .*fix is IN FLIGHT' <<<"$out" && ! grep -qE 'PR #302 .*→ REAP' <<<"$out" && ok "#302 check still in_progress: not reaped" || bad "#302 reaped/not held"
grep -qE 'PR #303 — MERGEABLE but REQUIRED check RED .*→ REAP' <<<"$out" && ok "#303 settled red, old push: reaped" || bad "#303 not reaped"

out="$(run env CHUMP_ROT_REAPER_FIX_GRACE_MIN=0)"
grep -qE 'PR #301 — MERGEABLE but REQUIRED check RED .*→ REAP' <<<"$out" && ok "grace=0: fresh push no longer protects (knob works)" || bad "grace=0 not honored"
grep -q 'PR #302 .*fix is IN FLIGHT' <<<"$out" && ok "grace=0: unsettled check still protects" || bad "pending protection lost"

echo "=== rot-reaper fix-in-flight: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
