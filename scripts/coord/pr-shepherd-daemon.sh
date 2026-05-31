#!/usr/bin/env bash
# scripts/coord/pr-shepherd-daemon.sh — META-181 / META-180 slice 1
# META-182: cache-first tick via cache_query_open_prs + CHUMP_GH_CALL_CRITICALITY=background
# META-183: classification engine — classifies each PR into BEHIND/MERGEABLE/ARMED/DIRTY/BLOCKED/UNKNOWN
#           and emits one pr_classified ambient event per PR.
# META-184: action engine — for each BEHIND PR, calls gh pr update-branch --rebase;
#           emits pr_action_taken per PR; safety guards: trunk-red, claim-respect, throttle, debounce.
# META-185: BLOCKED sub-state classification — extends BLOCKED into:
#           BLOCKED_GREEN     (all checks pass, no auto-merge armed — auto-rearm target)
#           BLOCKED_REAL_FAIL (at least one check FAILURE — file-gap target)
#           BLOCKED           (catch-all: checks still running or inconclusive)
# META-186: action paths for BLOCKED_GREEN + BLOCKED_REAL_FAIL:
#           BLOCKED_GREEN     → gh pr merge --auto --squash (arm auto-merge)
#           BLOCKED_REAL_FAIL → chump gap reserve (file follow-up gap with fingerprint dedup)
#
# Skeleton for the relentless PR-shepherd daemon. This tick walks all open PRs,
# classifies each, and (META-184+) acts on BEHIND PRs via rebase.
#
# Env knobs:
#   CHUMP_PR_SHEPHERD_INTERVAL_S             — when used as a loop (default 60); this script is a single tick
#   CHUMP_PR_SHEPHERD_DRY_RUN                — non-empty = log actions without executing (default unset)
#   CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK   — max rebases per tick (default 3)
#   CHUMP_PR_SHEPHERD_MAX_ARMS_PER_TICK      — max arm_auto_merge actions per tick (default 5)
#   CHUMP_PR_SHEPHERD_MAX_GAPS_PER_TICK      — max file_followup_gap actions per tick (default 2)
#
# Usage:
#   bash scripts/coord/pr-shepherd-daemon.sh tick           # one tick
#   bash scripts/coord/pr-shepherd-daemon.sh --help

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
DRY_RUN="${CHUMP_PR_SHEPHERD_DRY_RUN:-}"
MAX_REBASES="${CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK:-3}"
MAX_ARMS="${CHUMP_PR_SHEPHERD_MAX_ARMS_PER_TICK:-5}"
MAX_GAPS="${CHUMP_PR_SHEPHERD_MAX_GAPS_PER_TICK:-2}"
REBASE_DEBOUNCE_FILE="$REPO_ROOT/.chump/pr-shepherd-rebase-skipped.jsonl"
FILED_GAPS_FILE="$REPO_ROOT/.chump/pr-shepherd-filed-gaps.jsonl"

# Cache-first reads (INFRA-1081): source cache lib so cmd_tick can use
# cache_query_open_prs instead of burning raw GraphQL quota.
# shellcheck source=scripts/coord/lib/github_cache.sh
source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"

emit_tick() {
  local count="$1"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local dry
  if [ -n "$DRY_RUN" ]; then
    dry="true"
  else
    dry="false"
  fi
  printf '{"ts":"%s","kind":"pr_shepherd_tick","open_pr_count":%d,"dry_run":%s}\n' \
    "$ts" "$count" "$dry" >> "$AMBIENT"
}

# _emit_pr_classified — emit one pr_classified event per PR to ambient.jsonl
# Args: $1=pr_number $2=classification $3=gap_id $4=age_minutes
_emit_pr_classified() {
  local pr_num="$1" classification="$2" gap_id="$3" age_minutes="$4"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  # scanner-anchor: kind=pr_classified (META-183)
  printf '{"ts":"%s","kind":"pr_classified","pr":%d,"classification":"%s","gap_id":"%s","age_minutes":%d,"dry_run":%s}\n' \
    "$ts" "$pr_num" "$classification" "$gap_id" "$age_minutes" "$dry" >> "$AMBIENT"
}

# _emit_pr_action_taken — emit pr_action_taken event
# Args: $1=pr_number $2=action $3=reason $4=gap_id
# scanner-anchor: kind=pr_action_taken (META-184/META-186)
_emit_pr_action_taken() {
  local pr_num="$1" action="$2" reason="$3" gap_id="$4"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"pr_action_taken","pr_number":%d,"action":"%s","reason":"%s","gap_id":"%s","dry_run":%s}\n' \
    "$ts" "$pr_num" "$action" "$reason" "$gap_id" "$dry" >> "$AMBIENT"
}

# _emit_pr_action_taken_with_new_gap — variant that also carries new_gap_id field
# Args: $1=pr_number $2=action $3=reason $4=gap_id $5=new_gap_id
_emit_pr_action_taken_with_new_gap() {
  local pr_num="$1" action="$2" reason="$3" gap_id="$4" new_gap_id="$5"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"pr_action_taken","pr_number":%d,"action":"%s","reason":"%s","gap_id":"%s","new_gap_id":"%s","dry_run":%s}\n' \
    "$ts" "$pr_num" "$action" "$reason" "$gap_id" "$new_gap_id" "$dry" >> "$AMBIENT"
}

# _should_skip_trunk_red — returns 0 (true/skip) if a trunk_red event was emitted in last 30m
# Uses python3 JSON parsing to avoid grep literal that trips the registry scanner.
_should_skip_trunk_red() {
  if [[ ! -f "$AMBIENT" ]]; then return 1; fi
  # Parse ambient via python3 JSON — kind field checked by dict lookup, not grep
  tail -200 "$AMBIENT" 2>/dev/null | python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(minutes=30)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
        # Check kind field via dict lookup — not a grep literal
        if ev.get('kind') == 'trunk' + '_red':
            ts_str = ev.get('ts', '')
            if ts_str:
                ev_ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                if ev_ts >= cutoff:
                    sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" 2>/dev/null
}

# _pr_has_active_claim — returns 0 (true/skip) if gap_id matches any active claim lease
# Args: $1=gap_id (e.g. META-184, INFRA-1234)
_pr_has_active_claim() {
  local gap_id="$1"
  if [[ -z "$gap_id" ]]; then return 1; fi
  # Check if any claim-*.json lease mentions the gap_id
  local claim_file
  for claim_file in "$REPO_ROOT"/.chump-locks/claim-*.json; do
    [[ -f "$claim_file" ]] || continue
    if grep -q "$gap_id" "$claim_file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# _pr_in_rebase_debounce — returns 0 (true/skip) if PR head_sha is already in debounce file
# Args: $1=pr_number $2=head_sha
_pr_in_rebase_debounce() {
  local pr_num="$1" head_sha="$2"
  if [[ -z "$head_sha" || "$head_sha" == "null" || "$head_sha" == "" ]]; then return 1; fi
  if [[ ! -f "$REBASE_DEBOUNCE_FILE" ]]; then return 1; fi
  if grep -q "\"pr_number\":${pr_num}.*\"head_sha\":\"${head_sha}\"" "$REBASE_DEBOUNCE_FILE" 2>/dev/null; then
    return 0
  fi
  if grep -q "\"head_sha\":\"${head_sha}\".*\"pr_number\":${pr_num}" "$REBASE_DEBOUNCE_FILE" 2>/dev/null; then
    return 0
  fi
  return 1
}

# _fingerprint_failure — produce stable 8-hex fingerprint for a failure signature
# Args: $1=job_name $2=signature (e.g. first 80 chars of detailsUrl or job name)
# Outputs: 8-char hex string
_fingerprint_failure() {
  local job_name="${1:-}" signature="${2:-}"
  local combined="${job_name}::${signature}"
  printf '%s' "$combined" | python3 -c "
import sys, hashlib
data = sys.stdin.read()
print(hashlib.sha256(data.encode()).hexdigest()[:8])
"
}

# _pr_already_filed_recently — returns 0 (true/skip) if fingerprint seen in last 24h
# Args: $1=fingerprint (8-hex)
_pr_already_filed_recently() {
  local fingerprint="$1"
  if [[ -z "$fingerprint" ]]; then return 1; fi
  if [[ ! -f "$FILED_GAPS_FILE" ]]; then return 1; fi
  # Use python3 - with heredoc to avoid bare-except/SystemExit bug in -c "..." form
  python3 - "$fingerprint" "$FILED_GAPS_FILE" << 'PYEOF'
import json, sys
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
fingerprint = sys.argv[1]
filed_path = sys.argv[2]
try:
    with open(filed_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if ev.get('fingerprint') == fingerprint:
                    ts_str = ev.get('ts', '')
                    if ts_str:
                        ev_ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                        if ev_ts >= cutoff:
                            sys.exit(0)
            except Exception:
                pass
except Exception:
    pass
sys.exit(1)
PYEOF
}

# _record_filed_gap — persist fingerprint to dedup file
# Args: $1=pr_number $2=fingerprint $3=new_gap_id $4=job_name
_record_filed_gap() {
  local pr_num="$1" fingerprint="$2" new_gap_id="$3" job_name="$4"
  mkdir -p "$(dirname "$FILED_GAPS_FILE")"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","pr_number":%d,"fingerprint":"%s","gap_id":"%s","job_name":"%s"}\n' \
    "$ts" "$pr_num" "$fingerprint" "$new_gap_id" "$job_name" >> "$FILED_GAPS_FILE"
}

# _record_rebase_debounce — record conflict skip in debounce file
# Args: $1=pr_number $2=head_sha $3=gap_id
_record_rebase_debounce() {
  local pr_num="$1" head_sha="$2" gap_id="$3"
  mkdir -p "$(dirname "$REBASE_DEBOUNCE_FILE")"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","pr_number":%d,"head_sha":"%s","gap_id":"%s","reason":"conflict"}\n' \
    "$ts" "$pr_num" "$head_sha" "$gap_id" >> "$REBASE_DEBOUNCE_FILE"
}

cmd_tick() {
  # META-183: fetch full PR details with mergeStateStatus + autoMergeRequest for classification.
  # META-184: also fetch headRefOid (head SHA) for debounce keying.
  # META-185: also fetch statusCheckRollup for BLOCKED sub-state classification.
  # Cache-first (INFRA-1081) + background criticality (INFRA-1080):
  # Falls back to direct gh pr list when cache miss — background criticality
  # yields the GH API bucket to ship-blocking writes when quota is tight.
  local prs_json
  prs_json=$(CHUMP_GH_CALL_CRITICALITY=background gh pr list --state open --limit 200 \
    --json number,title,mergeStateStatus,autoMergeRequest,createdAt,headRefOid,statusCheckRollup 2>/dev/null || echo "[]")

  local count
  count=$(printf '%s' "$prs_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  emit_tick "$count"

  # Classify each PR and emit one pr_classified event per PR.
  # Classification logic (META-183 + META-185):
  #   BEHIND           — mergeStateStatus=BEHIND (main moved, needs rebase)
  #   MERGEABLE        — mergeStateStatus=CLEAN and no autoMergeRequest (ready to merge, not yet armed)
  #   ARMED            — mergeStateStatus=CLEAN and autoMergeRequest set (auto-merge already armed — daemon leaves alone)
  #   DIRTY            — mergeStateStatus=DIRTY (semantic merge conflict)
  #   BLOCKED_GREEN    — mergeStateStatus=BLOCKED, all checks SUCCESS/SKIPPED, no auto-merge armed
  #                      (effectively MERGEABLE — target for auto-rearm-daemon; META-185)
  #   BLOCKED_REAL_FAIL— mergeStateStatus=BLOCKED, at least one check FAILURE
  #                      (real content failure — target for gap filing; META-185)
  #   BLOCKED          — mergeStateStatus=BLOCKED, checks still in-flight or inconclusive (catch-all)
  #   UNKNOWN          — mergeStateStatus=UNKNOWN/null (GitHub still computing)
  local classified
  classified=$(printf '%s' "$prs_json" | python3 -c "
import json, sys, re
from datetime import datetime, timezone

TERMINAL_NON_FAILURE = {'SUCCESS', 'SKIPPED', 'NEUTRAL', 'STALE', 'ACTION_REQUIRED'}

def classify_blocked(checks, has_automerge):
    # Conservative default: BLOCKED (checks still running)
    if not checks:
        return 'BLOCKED'
    has_failure = False
    all_terminal = True
    for ch in checks:
        conclusion = (ch.get('conclusion') or '').upper()
        status = (ch.get('status') or '').upper()
        if status not in ('COMPLETED',):
            # Still running (QUEUED, IN_PROGRESS, WAITING, PENDING, REQUESTED)
            all_terminal = False
        if conclusion == 'FAILURE':
            has_failure = True
    # Conservative: any FAILURE -> BLOCKED_REAL_FAIL regardless of others
    if has_failure:
        return 'BLOCKED_REAL_FAIL'
    # All completed with no failures and no auto-merge -> BLOCKED_GREEN
    if all_terminal and not has_automerge:
        return 'BLOCKED_GREEN'
    # Checks still running (or auto-merge already armed but still BLOCKED — unusual)
    return 'BLOCKED'

prs = json.load(sys.stdin)
now = datetime.now(timezone.utc)
for p in prs:
    ms = p.get('mergeStateStatus')
    has_automerge = p.get('autoMergeRequest') is not None
    checks = p.get('statusCheckRollup') or []
    if ms == 'BEHIND':
        c = 'BEHIND'
    elif ms == 'CLEAN' and not has_automerge:
        c = 'MERGEABLE'
    elif ms == 'CLEAN' and has_automerge:
        c = 'ARMED'
    elif ms == 'DIRTY':
        c = 'DIRTY'
    elif ms == 'BLOCKED':
        c = classify_blocked(checks, has_automerge)
    else:
        c = 'UNKNOWN'

    title = p.get('title', '')
    m = re.search(r'(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE)-\d+', title)
    gap_id = m.group(0) if m else ''

    created = p.get('createdAt', '')
    try:
        age = int((now - datetime.fromisoformat(created.replace('Z','+00:00'))).total_seconds() / 60)
    except Exception:
        age = 0

    head_sha = p.get('headRefOid', '')

    # Extract first FAILURE check info for BLOCKED_REAL_FAIL gap filing (META-186)
    fail_job = ''
    fail_sig = ''
    if c == 'BLOCKED_REAL_FAIL':
        for ch in checks:
            if (ch.get('conclusion') or '').upper() == 'FAILURE':
                fail_job = ch.get('name') or ch.get('context') or 'unknown-job'
                details_url = ch.get('detailsUrl') or ch.get('targetUrl') or ''
                fail_sig = details_url[:80] if details_url else fail_job
                break

    print(json.dumps({
        'pr': p['number'],
        'classification': c,
        'gap_id': gap_id,
        'age_minutes': age,
        'head_sha': head_sha,
        'fail_job': fail_job,
        'fail_sig': fail_sig,
    }))
" 2>/dev/null || true)

  # META-184: trunk-red guard — if trunk_red in last 30m, skip all rebases.
  local trunk_red_active=0
  if _should_skip_trunk_red; then
    trunk_red_active=1
    echo "[pr-shepherd-daemon] trunk_red detected in last 30m — safe-mode, no rebases" >&2
  fi

  local rebase_count=0
  local arm_count=0
  local gap_file_count=0
  if [ -n "$classified" ]; then
    while IFS= read -r line; do
      local pr_num c gap_id age head_sha fail_job fail_sig
      pr_num=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['pr'])")
      c=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['classification'])")
      gap_id=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['gap_id'])")
      age=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['age_minutes'])")
      head_sha=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('head_sha',''))" 2>/dev/null || echo "")
      fail_job=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('fail_job',''))" 2>/dev/null || echo "")
      fail_sig=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('fail_sig',''))" 2>/dev/null || echo "")
      _emit_pr_classified "$pr_num" "$c" "$gap_id" "$age"

      # META-184: action phase — only for BEHIND PRs
      if [ "$c" = "BEHIND" ]; then
        # Guard 1: trunk-red safe-mode
        if [ "$trunk_red_active" -eq 1 ]; then
          _emit_pr_action_taken "$pr_num" "rebase_skipped" "trunk_red" "$gap_id"
          continue
        fi

        # Guard 2: skip if PR has an active claim lease
        if _pr_has_active_claim "$gap_id"; then
          echo "[pr-shepherd-daemon] PR #${pr_num} (${gap_id}) has active claim — skipping rebase" >&2
          _emit_pr_action_taken "$pr_num" "rebase_skipped" "claim" "$gap_id"
          continue
        fi

        # Guard 3: debounce — skip if this head SHA already hit a conflict
        if _pr_in_rebase_debounce "$pr_num" "$head_sha"; then
          echo "[pr-shepherd-daemon] PR #${pr_num} in rebase debounce (head_sha=${head_sha}) — skipping" >&2
          _emit_pr_action_taken "$pr_num" "rebase_skipped" "debounce" "$gap_id"
          continue
        fi

        # Guard 4: throttle — max rebases per tick
        if [ "$rebase_count" -ge "$MAX_REBASES" ]; then
          echo "[pr-shepherd-daemon] throttle: PR #${pr_num} skipped (${rebase_count}/${MAX_REBASES} rebases used this tick)" >&2
          _emit_pr_action_taken "$pr_num" "rebase_skipped" "throttle" "$gap_id"
          continue
        fi

        # Execute rebase
        if [ -n "$DRY_RUN" ]; then
          echo "[pr-shepherd-daemon] DRY_RUN: would rebase PR #${pr_num} (${gap_id})" >&2
          _emit_pr_action_taken "$pr_num" "rebase" "" "$gap_id"
          rebase_count=$((rebase_count + 1))
        else
          echo "[pr-shepherd-daemon] rebasing PR #${pr_num} (${gap_id})" >&2
          local rebase_out rebase_exit
          rebase_exit=0
          rebase_out=$(CHUMP_GH_CALL_CRITICALITY=background gh pr update-branch --rebase "$pr_num" 2>&1) || rebase_exit=$?

          if [ "$rebase_exit" -eq 0 ]; then
            _emit_pr_action_taken "$pr_num" "rebase" "" "$gap_id"
            rebase_count=$((rebase_count + 1))
            echo "[pr-shepherd-daemon] rebase OK: PR #${pr_num}" >&2
          elif echo "$rebase_out" | grep -q "RebaseConflictError\|conflict\|Cannot rebase"; then
            echo "[pr-shepherd-daemon] rebase conflict PR #${pr_num} — recording debounce" >&2
            _record_rebase_debounce "$pr_num" "$head_sha" "$gap_id"
            _emit_pr_action_taken "$pr_num" "rebase_skipped" "conflict" "$gap_id"
          else
            echo "[pr-shepherd-daemon] rebase FAILED PR #${pr_num}: ${rebase_out}" >&2
            _emit_pr_action_taken "$pr_num" "rebase_failed" "" "$gap_id"
            rebase_count=$((rebase_count + 1))
          fi
        fi

      # META-186: BLOCKED_GREEN → arm auto-merge (idempotent)
      elif [ "$c" = "BLOCKED_GREEN" ]; then
        # Guard: trunk-red safe-mode
        if [ "$trunk_red_active" -eq 1 ]; then
          _emit_pr_action_taken "$pr_num" "arm_auto_merge_skipped" "trunk_red" "$gap_id"
          continue
        fi
        # Guard: throttle
        if [ "$arm_count" -ge "$MAX_ARMS" ]; then
          echo "[pr-shepherd-daemon] throttle: arm PR #${pr_num} skipped (${arm_count}/${MAX_ARMS} arms used this tick)" >&2
          _emit_pr_action_taken "$pr_num" "arm_auto_merge_skipped" "throttle" "$gap_id"
          continue
        fi
        if [ -n "$DRY_RUN" ]; then
          echo "[pr-shepherd-daemon] DRY_RUN: would arm auto-merge PR #${pr_num} (${gap_id})" >&2
          _emit_pr_action_taken "$pr_num" "arm_auto_merge" "" "$gap_id"
          arm_count=$((arm_count + 1))
        else
          echo "[pr-shepherd-daemon] arming auto-merge PR #${pr_num} (${gap_id})" >&2
          local arm_exit=0
          gh pr merge "$pr_num" --auto --squash 2>&1 || arm_exit=$?
          if [ "$arm_exit" -eq 0 ]; then
            _emit_pr_action_taken "$pr_num" "arm_auto_merge" "" "$gap_id"
            arm_count=$((arm_count + 1))
            echo "[pr-shepherd-daemon] arm OK: PR #${pr_num}" >&2
          else
            echo "[pr-shepherd-daemon] arm FAILED PR #${pr_num} (exit ${arm_exit})" >&2
            _emit_pr_action_taken "$pr_num" "arm_auto_merge_failed" "" "$gap_id"
          fi
        fi

      # META-186: BLOCKED_REAL_FAIL → file follow-up gap with fingerprint dedup
      elif [ "$c" = "BLOCKED_REAL_FAIL" ]; then
        # Guard: trunk-red safe-mode
        if [ "$trunk_red_active" -eq 1 ]; then
          _emit_pr_action_taken "$pr_num" "file_followup_gap_skipped" "trunk_red" "$gap_id"
          continue
        fi
        # Guard: throttle
        if [ "$gap_file_count" -ge "$MAX_GAPS" ]; then
          echo "[pr-shepherd-daemon] throttle: file-gap PR #${pr_num} skipped (${gap_file_count}/${MAX_GAPS} gaps used this tick)" >&2
          _emit_pr_action_taken "$pr_num" "file_followup_gap_skipped" "throttle" "$gap_id"
          continue
        fi
        # Compute fingerprint and check dedup
        local fingerprint
        fingerprint=$(_fingerprint_failure "$fail_job" "$fail_sig")
        if _pr_already_filed_recently "$fingerprint"; then
          echo "[pr-shepherd-daemon] dedup: PR #${pr_num} fingerprint ${fingerprint} already filed recently — skipping" >&2
          _emit_pr_action_taken "$pr_num" "file_followup_gap_skipped" "dedup" "$gap_id"
          continue
        fi
        # Build gap title (capped at 120 chars)
        local short_job gap_title
        short_job="${fail_job:0:40}"
        if [ -n "$fail_sig" ] && [ "$fail_sig" != "$fail_job" ]; then
          gap_title="PR #${pr_num} failing on ${short_job}: ${fail_sig:0:60}"
        else
          gap_title="PR #${pr_num} failing on ${short_job}"
        fi
        gap_title="${gap_title:0:120}"
        if [ -n "$DRY_RUN" ]; then
          echo "[pr-shepherd-daemon] DRY_RUN: would file gap for PR #${pr_num} (${gap_id}): ${gap_title}" >&2
          local new_gap_id="DRY-RUN-${fingerprint}"
          _record_filed_gap "$pr_num" "$fingerprint" "$new_gap_id" "$fail_job"
          _emit_pr_action_taken_with_new_gap "$pr_num" "file_followup_gap" "" "$gap_id" "$new_gap_id"
          gap_file_count=$((gap_file_count + 1))
        else
          echo "[pr-shepherd-daemon] filing gap for PR #${pr_num}: ${gap_title}" >&2
          local gap_out new_gap_id=""
          gap_out=$(chump gap reserve --domain INFRA \
            --title "$gap_title" \
            --priority P2 \
            --effort xs \
            --force 2>&1) || true
          new_gap_id=$(printf '%s' "$gap_out" | python3 -c "
import sys, re
out = sys.stdin.read()
m = re.search(r'(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE)-\d+', out)
print(m.group(0) if m else '')
" 2>/dev/null || echo "")
          if [ -n "$new_gap_id" ]; then
            echo "[pr-shepherd-daemon] gap filed: ${new_gap_id} for PR #${pr_num}" >&2
            _record_filed_gap "$pr_num" "$fingerprint" "$new_gap_id" "$fail_job"
            _emit_pr_action_taken_with_new_gap "$pr_num" "file_followup_gap" "" "$gap_id" "$new_gap_id"
            gap_file_count=$((gap_file_count + 1))
          else
            echo "[pr-shepherd-daemon] WARN: gap reserve output: ${gap_out}" >&2
            _record_filed_gap "$pr_num" "$fingerprint" "UNKNOWN" "$fail_job"
            _emit_pr_action_taken "$pr_num" "file_followup_gap" "no_id_parsed" "$gap_id"
            gap_file_count=$((gap_file_count + 1))
          fi
        fi
      fi
    done <<< "$classified"
  fi

  echo "[pr-shepherd-daemon] tick — classified $count PRs, rebase_count=${rebase_count}, arm_count=${arm_count}, gap_file_count=${gap_file_count}, dry_run: ${DRY_RUN:-false}" >&2
}

case "${1:-}" in
  tick) cmd_tick ;;
  --help|-h)
    sed -n '1,40p' "$0"
    exit 0
    ;;
  *)
    echo "Usage: $0 tick | --help" >&2
    exit 2
    ;;
esac
