#!/usr/bin/env bash
# capability-lifecycle.sh — CREDIBLE-299: per-capability lifecycle gauge.
#
# "Merged-not-running" is ChumpOS's #1 recurring failure: a PR merges and the
# board reads it as DONE while the thing it built does nothing. vital-signs.sh
# sign #4 (merged_not_running) answers this at the FLEET level (organs
# active / manifest %). This gauge answers it PER-CAPABILITY, with a stage
# that is honest about exactly how far a capability got:
#
#   1 built           source/binary exists on disk
#   2 merged          that source is committed to origin/main (not just local)
#   3 deployed        systemd knows about the unit (list-unit-files)
#   4 wired           unit is enabled (systemctl is-enabled)
#   5 running         unit is active right now (systemctl is-active)
#   6 doing-its-job   emitted a real ambient signal recently — DONE
#
# A capability's stage is the LAST stage it reached CONTIGUOUSLY from stage 1.
# "running" is NOT "done" — a unit can be active and still emit nothing
# (running != doing-its-job, precisely the trap that motivated this gauge:
# 2026-08-22, 3 organs built+merged-not-deployed, collectors is-active but
# emitting null). DONE is reserved for stage 6, never earlier.
#
# Usage:
#   scripts/ops/capability-lifecycle.sh                  # gauge every 'enabled'
#                                                         # organ in the manifest
#   scripts/ops/capability-lifecycle.sh <unit>            # gauge one unit
#   scripts/ops/capability-lifecycle.sh --dry-run [<unit>] # print JSON, no writes
#
# Env overrides (all optional):
#   CHUMP_REPO_ROOT / REPO_ROOT     repo checkout root
#   CHUMP_LIFECYCLE_OUT             output json path (default ~/.chump/capability-lifecycle.json)
#   CHUMP_AMBIENT_LOG               ambient jsonl (default REPO_ROOT/.chump-locks/ambient.jsonl)
#   CHUMP_LIFECYCLE_WINDOW_H        "doing-its-job" recency window in hours (default 24)
#
# This file is sourced by scripts/ci/test-capability-lifecycle.sh, which
# exercises `compute_capability_stage` directly with synthetic evidence —
# that function is pure (no I/O) so it is testable without systemd/git/jq.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
OUT="${CHUMP_LIFECYCLE_OUT:-$HOME/.chump/capability-lifecycle.json}"
WINDOW_H="${CHUMP_LIFECYCLE_WINDOW_H:-24}"

STAGE_NAMES=(not-built built merged deployed wired running doing-its-job)

# ─────────────────────────────────────────────────────────────────────────
# compute_capability_stage BUILT MERGED DEPLOYED WIRED RUNNING DOING_ITS_JOB
#   Each arg is 1 (true) or 0 (false). Pure function, no I/O.
#   Prints "<stage_number> <stage_name>" — stage_number 0..6.
#   Stage is the count of TRUE evidence, stopping at the first FALSE
#   (contiguous-from-start semantics): a capability that is running but not
#   yet deployed (evidence out of order / partial) is capped at the first
#   gap, never credited for a later stage it hasn't actually earned.
#   DONE (stage 6 / "doing-its-job") requires ALL SIX to be true.
# ─────────────────────────────────────────────────────────────────────────
compute_capability_stage() {
  local built="${1:-0}" merged="${2:-0}" deployed="${3:-0}" wired="${4:-0}" running="${5:-0}" doing_its_job="${6:-0}"
  local evidence=("$built" "$merged" "$deployed" "$wired" "$running" "$doing_its_job")
  local stage=0
  local i
  for i in "${!evidence[@]}"; do
    if [[ "${evidence[$i]}" == "1" ]]; then
      stage=$((i + 1))
    else
      break
    fi
  done
  printf '%s %s\n' "$stage" "${STAGE_NAMES[$stage]}"
}

# is_done STAGE_NUMBER -> "true"/"false"
is_done() { [[ "${1:-0}" == "6" ]] && printf 'true' || printf 'false'; }

# ─────────────────────────────────────────────────────────────────────────
# gather_evidence UNIT -> prints 6 space-separated 1/0 values (built merged
# deployed wired running doing_its_job). Best-effort: a signal this host
# cannot observe (no systemctl, no git remote, etc.) is treated as 0/false,
# never fabricated true — same honesty rule as vital-signs.sh.
# ─────────────────────────────────────────────────────────────────────────
gather_evidence() {
  local unit="$1"
  local built=0 merged=0 deployed=0 wired=0 running=0 doing_its_job=0

  if command -v systemctl >/dev/null 2>&1; then
    # .timer units have no ExecStart of their own — they trigger a .service
    # (default: same basename). Resolve to that service for the "built"
    # evidence check, since that's what's actually doing the work.
    local exec_unit="$unit"
    if [[ "$unit" == *.timer ]]; then
      exec_unit="${unit%.timer}.service"
    fi
    # ExecStart often wraps the real script behind `/bin/bash -lc exec
    # /real/script.sh` (chump-farmer-run.sh style organs). Prefer a repo-path
    # token out of argv[] over the interpreter itself in `path=`, so "built"
    # checks the actual capability script, not the fact that bash exists.
    local exec_show exec_path
    exec_show="$(systemctl show "$exec_unit" -p ExecStart --value 2>/dev/null)"
    exec_path="$(printf '%s' "$exec_show" | grep -oE "$REPO_ROOT/[^ ;]+" | head -1)"
    [[ -z "$exec_path" ]] && exec_path="$(printf '%s' "$exec_show" | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1)"

    if [[ -n "$exec_path" && -e "$exec_path" ]]; then
      built=1
      if [[ "$exec_path" == "$REPO_ROOT"* ]]; then
        local rel="${exec_path#"$REPO_ROOT"/}"
        if git -C "$REPO_ROOT" ls-tree -r --name-only origin/main 2>/dev/null | grep -qx "$rel"; then
          merged=1
        fi
      else
        # Not a repo-tracked path (e.g. a cargo-installed binary) — "merged"
        # doesn't apply here, so don't let it block the pipeline: credit it
        # equal to "built" rather than fabricating a fleet-wide git check.
        merged=1
      fi
    fi

    if systemctl list-unit-files "$unit" >/dev/null 2>&1 \
       && systemctl list-unit-files "$unit" 2>/dev/null | grep -q "^$unit"; then
      deployed=1
    fi

    if [[ "$(systemctl is-enabled "$unit" 2>/dev/null)" == "enabled" ]]; then
      wired=1
    fi

    if [[ "$(systemctl is-active "$unit" 2>/dev/null)" == "active" ]]; then
      running=1
    fi
  fi

  if [[ "$running" == "1" && -f "$AMBIENT_LOG" ]]; then
    local short cutoff
    short="${unit%.service}"; short="${short%.timer}"; short="${short#chump-}"
    cutoff="$(date -u -d "${WINDOW_H} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"${WINDOW_H}"H +%Y-%m-%dT%H:%M:%SZ)"
    if grep -F "$short" "$AMBIENT_LOG" 2>/dev/null \
       | awk -v c="$cutoff" -F'"ts":"' '{split($2,a,"\""); if(a[1]>c) found=1} END{exit !found}'; then
      doing_its_job=1
    fi
  fi

  printf '%s %s %s %s %s %s\n' "$built" "$merged" "$deployed" "$wired" "$running" "$doing_its_job"
}

main() {
  local dry_run=0
  local args=()
  for a in "$@"; do
    if [[ "$a" == "--dry-run" ]]; then dry_run=1; else args+=("$a"); fi
  done

  command -v jq >/dev/null 2>&1 || { echo "[capability-lifecycle] FATAL: jq not found" >&2; exit 1; }

  local units=()
  if [[ "${#args[@]}" -gt 0 ]]; then
    units=("${args[@]}")
  elif [[ -f "$MANIFEST" ]]; then
    while read -r _ unit _; do
      [[ -z "$unit" ]] && continue
      units+=("$unit")
    done < <(grep -E '^enabled' "$MANIFEST")
  fi

  local capabilities="[]"
  local unit
  for unit in "${units[@]}"; do
    read -r built merged deployed wired running doing_its_job < <(gather_evidence "$unit")
    read -r stage stage_name < <(compute_capability_stage "$built" "$merged" "$deployed" "$wired" "$running" "$doing_its_job")
    local done_flag
    done_flag="$(is_done "$stage")"
    capabilities="$(jq -n --argjson caps "$capabilities" \
      --arg name "$unit" --argjson stage "$stage" --arg stage_name "$stage_name" \
      --argjson built "$built" --argjson merged "$merged" --argjson deployed "$deployed" \
      --argjson wired "$wired" --argjson running "$running" --argjson doing_its_job "$doing_its_job" \
      --argjson done "$done_flag" \
      '$caps + [{name:$name, stage:$stage, stage_name:$stage_name, done:$done,
        evidence:{built:($built==1), merged:($merged==1), deployed:($deployed==1),
                  wired:($wired==1), running:($running==1), doing_its_job:($doing_its_job==1)}}]')"
  done

  local report
  report="$(jq -n --argjson caps "$capabilities" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{ts:$ts, capabilities:$caps, done_count:([$caps[]|select(.done)]|length), total:($caps|length)}')"

  if [[ "$dry_run" == "1" ]]; then
    printf '%s\n' "$report"
  else
    mkdir -p "$(dirname "$OUT")"
    printf '%s\n' "$report" > "$OUT"
    printf '%s\n' "$report"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
