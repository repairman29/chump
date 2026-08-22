#!/usr/bin/env bash
# vital-signs.sh — the 8 VITAL SIGNS of ChumpOS's journey to the ribbon.
#
# Reads eight real endpoints (gh, ~/.chump ledgers, the ambient stream, the
# systemd organ roll-call, journey-odds.json) and writes ~/.chump/vital-signs.json
# in the SHARED CONTRACT shape, plus a `vital_signs` ambient heartbeat to
# .chump-locks/ambient.jsonl so a dead collector — and a frozen vitals board —
# is itself observable from the stream instead of silently going stale.
#
# THE 8 SIGNS (group / lead_or_lag):
#   1 merge_throughput    flow/lagging     merges/24h
#   2 oldest_pr_age       flow/leading     oldest open PR age (minutes)
#   3 ci_pass_rate        quality/leading  CI pass-rate % (success/decided)
#   4 merged_not_running  quality/leading  organs active / manifest %
#   5 conflict_churn      waste/leading    DIRTY open PR count
#   6 calibration_brier   trust/meta       Brier from pr-book-calibration.log (else null)
#   7 human_intervention  autonomy/lagging operator pages / 24h
#   8 outcomes_delivered  mission/lagging  things reaching a person (best real proxy)
#
# HONESTY RULE: a sign with no real source is status "unknown", basis
# "uninstrumented" — never a fabricated number. calibration_brier and
# outcomes_delivered land here today; the basis names what would light them up.
#
# It is an ORGAN, not a one-shot: a chump-vital-signs.timer should drive it and
# it must survive a roll-call. Registered as kind=vital_signs in
# docs/observability/EVENT_REGISTRY.yaml (same commit — the strict-emit gate
# blocks unregistered kinds).
#
# Usage:
#   scripts/ops/vital-signs.sh            # collect + write once
#   scripts/ops/vital-signs.sh --dry-run  # print JSON to stdout, no writes
#
# Env overrides (all optional):
#   CHUMP_REPO_ROOT / REPO_ROOT     repo checkout root
#   CHUMP_VITALS_OUT                output json path (default ~/.chump/vital-signs.json)
#   CHUMP_AMBIENT_LOG               ambient jsonl (default REPO_ROOT/.chump-locks/ambient.jsonl)
#   CHUMP_GH_REPO                   owner/repo for gh (default repairman29/chump)
#   CHUMP_JOURNEY_ODDS              journey-odds.json path (default ~/.chump/journey-odds.json)
#   CHUMP_PR_BOOK_CALIB             pr-book calibration log (default ~/.chump/pr-book-calibration.log)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

# ── HOST-ASSUMPTION HARDENING (mirrors faculty-collector.sh, 2026-08-22) ─────
# The fleet's service convention hardcodes Environment=HOME=/root even when
# User=jeff on an owned node. Under that env every tool that reads a per-user
# config from $HOME breaks silently and the board LIES (gh -> /root/.config/gh
# permission denied -> 0 merges). Resolve the RUN-USER's REAL home from the
# passwd db and RESET HOME. Host-agnostic (root->/root, jeff->/home/jeff).
REAL_HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]] && REAL_HOME="$HOME"
export HOME="$REAL_HOME"
# Under systemd PATH is minimal (/usr/bin:/bin) so gh resolves but chump lives
# in ~/.cargo/bin. Prepend the run-user's bins so every endpoint resolves.
export PATH="$REAL_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# REPO-ROOT HARDENING (honest-instrument fix, 2026-08-22): the SCRIPT_DIR-derived
# or env-overridden REPO_ROOT can point at a torn-down worktree or a /root-mapped
# path under an organ run, leaving the manifest / gap store / ambient log
# UNREADABLE so the board reads spurious null/0 and LIES (this exact class wrote a
# p_full_trek=0 board while the fleet was shipping 53 PRs/24h). If the manifest
# isn't where we think it is, self-heal to the run-user's canonical checkout.
if [[ ! -f "$REPO_ROOT/scripts/ops/organ-manifest.txt" ]]; then
  for _cand in "$REAL_HOME/Projects/chump" "$SCRIPT_DIR/../.."; do
    if [[ -f "$_cand/scripts/ops/organ-manifest.txt" ]]; then
      REPO_ROOT="$(cd "$_cand" && pwd)"; break
    fi
  done
fi

OUT="${CHUMP_VITALS_OUT:-$REAL_HOME/.chump/vital-signs.json}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
GH_REPO="${CHUMP_GH_REPO:-repairman29/chump}"
JOURNEY_ODDS="${CHUMP_JOURNEY_ODDS:-$REAL_HOME/.chump/journey-odds.json}"
PR_BOOK_CALIB="${CHUMP_PR_BOOK_CALIB:-$REAL_HOME/.chump/pr-book-calibration.log}"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"

# AMBIENT-LOG HARDENING (honest-instrument fix): if the resolved ambient log does
# not exist (wrong root under an organ run -> human_intervention spuriously null),
# fall back to the canonical checkout's stream so the sign reads the truth.
if [[ ! -e "$AMBIENT_LOG" && -e "$REPO_ROOT/.chump-locks/ambient.jsonl" ]]; then
  AMBIENT_LOG="$REPO_ROOT/.chump-locks/ambient.jsonl"
fi

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

command -v jq >/dev/null 2>&1 || { echo "[vital-signs] FATAL: jq not found" >&2; exit 1; }

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CUT_24H="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date -u +%s)"

# ════════════════════════════════════════════════════════════════════════════
# THRESHOLD CONFIG  — tunable in ONE place. Edit here to re-calibrate the board.
# Every sign resolves its status from these numbers; nothing is hardcoded below.
# Direction "hi" = higher is better; "lo" = lower is better.
# ════════════════════════════════════════════════════════════════════════════
# merge_throughput  merges/24h            hi   green>30  amber>=10  red<10
CFG_MERGE_GREEN=30;   CFG_MERGE_AMBER=10
# oldest_pr_age     minutes               lo   green<60  amber<=240 red>240
CFG_OLDPR_GREEN=60;   CFG_OLDPR_AMBER=240
# ci_pass_rate      percent               hi   green>90  amber>=75  red<75
CFG_CI_GREEN=90;      CFG_CI_AMBER=75
# merged_not_running organs active %      hi   green>95  amber>=80  red<80
CFG_ORGAN_GREEN=95;   CFG_ORGAN_AMBER=80
# conflict_churn    DIRTY open PR count   lo   green<3   amber<=8   red>8
CFG_DIRTY_GREEN=3;    CFG_DIRTY_AMBER=8
# calibration_brier Brier score          lo   green<0.1 amber<=0.2 red>0.2
CFG_BRIER_GREEN=0.1;  CFG_BRIER_AMBER=0.2
# human_intervention pages/24h            lo   green<5   amber<=20  red>20
CFG_PAGES_GREEN=5;    CFG_PAGES_AMBER=20
# outcomes_delivered things/24h           hi   green>=3  amber>=1   red<1
CFG_OUT_GREEN=3;      CFG_OUT_AMBER=1

# ── status helpers ──────────────────────────────────────────────────────────
# status_hi VALUE GREEN AMBER  -> green|amber|red  (higher is better)
status_hi() { awk -v v="$1" -v g="$2" -v a="$3" 'BEGIN{
  v+=0; if(v>g)print"green"; else if(v>=a)print"amber"; else print"red" }'; }
# status_lo VALUE GREEN AMBER  -> green|amber|red  (lower is better)
status_lo() { awk -v v="$1" -v g="$2" -v a="$3" 'BEGIN{
  v+=0; if(v<g)print"green"; else if(v<=a)print"amber"; else print"red" }'; }

SIGNS=()   # each element = one complete sign JSON object
# mksign KEY NAME GROUP LEAD VALUE(json-literal|"null") UNIT STATUS ACTION BASIS THRESH_JSON
mksign() {
  jq -n \
    --arg key "$1" --arg name "$2" --arg group "$3" --arg lead "$4" \
    --argjson value "$5" --arg unit "$6" --arg status "$7" \
    --arg action "$8" --arg basis "$9" --argjson thr "${10}" \
    '{key:$key, name:$name, group:$group, lead_or_lag:$lead,
      value:$value, unit:$unit, status:$status,
      thresholds:$thr, treatable_action:$action, basis:$basis}'
}
# jnum N -> a JSON number literal, or "null" when empty/non-numeric
jnum() { local n="${1:-}"; [[ "$n" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && printf '%s' "$n" || printf 'null'; }

# ════════════════════════════════════════════════════════════════════════════
# 1 · merge_throughput  (flow / lagging)  — merges in the last 24h
# ════════════════════════════════════════════════════════════════════════════
merges="$(gh pr list --repo "$GH_REPO" --state merged --limit 300 --json mergedAt \
          --jq "[.[]|select(.mergedAt>\"$CUT_24H\")]|length" 2>/dev/null)"
if [[ "$merges" =~ ^[0-9]+$ ]]; then
  s="$(status_hi "$merges" "$CFG_MERGE_GREEN" "$CFG_MERGE_AMBER")"
  SIGNS+=("$(mksign merge_throughput "Merge Throughput" flow lagging \
    "$(jnum "$merges")" "merges/24h" "$s" \
    "stall — check resolver/CI/queue" \
    "$merges PR(s) merged in the 24h to $NOW (gh pr list, mergedAt>cutoff)" \
    "{\"green\":\">$CFG_MERGE_GREEN\",\"amber\":\"$CFG_MERGE_AMBER-$CFG_MERGE_GREEN\",\"red_desc\":\"<$CFG_MERGE_AMBER merges/24h\"}")")
else
  SIGNS+=("$(mksign merge_throughput "Merge Throughput" flow lagging \
    null "merges/24h" "unknown" "stall — check resolver/CI/queue" \
    "uninstrumented: gh pr list returned no parseable count" \
    "{\"green\":\">$CFG_MERGE_GREEN\",\"amber\":\"$CFG_MERGE_AMBER-$CFG_MERGE_GREEN\",\"red_desc\":\"<$CFG_MERGE_AMBER merges/24h\"}")")
fi

# ════════════════════════════════════════════════════════════════════════════
# 2 · oldest_pr_age  (flow / leading)  — THE CLOCK. Age of the oldest open PR.
# ════════════════════════════════════════════════════════════════════════════
oldest_created="$(gh pr list --repo "$GH_REPO" --state open --limit 400 --json createdAt \
                  --jq 'sort_by(.createdAt)|.[0].createdAt // empty' 2>/dev/null)"
if [[ -n "$oldest_created" ]]; then
  oldest_epoch="$(date -u -d "$oldest_created" +%s 2>/dev/null || echo "$NOW_EPOCH")"
  age_min=$(( (NOW_EPOCH - oldest_epoch) / 60 ))
  (( age_min < 0 )) && age_min=0
  s="$(status_lo "$age_min" "$CFG_OLDPR_GREEN" "$CFG_OLDPR_AMBER")"
  SIGNS+=("$(mksign oldest_pr_age "Oldest Open PR Age" flow leading \
    "$(jnum "$age_min")" "minutes" "$s" \
    "clear/diagnose the oldest PR NOW (the clock)" \
    "oldest open PR created $oldest_created ($age_min min ago) (gh pr list, min createdAt)" \
    "{\"green\":\"<$CFG_OLDPR_GREEN\",\"amber\":\"$CFG_OLDPR_GREEN-$CFG_OLDPR_AMBER\",\"red_desc\":\">$CFG_OLDPR_AMBER min\"}")")
else
  # no open PRs is a GREEN clock, not unknown
  SIGNS+=("$(mksign oldest_pr_age "Oldest Open PR Age" flow leading \
    0 "minutes" "green" \
    "clear/diagnose the oldest PR NOW (the clock)" \
    "no open PRs on $GH_REPO — the clock is empty" \
    "{\"green\":\"<$CFG_OLDPR_GREEN\",\"amber\":\"$CFG_OLDPR_GREEN-$CFG_OLDPR_AMBER\",\"red_desc\":\">$CFG_OLDPR_AMBER min\"}")")
fi

# ════════════════════════════════════════════════════════════════════════════
# 3 · ci_pass_rate  (quality / leading)  — success / decided runs (24h).
#     decided = success + failure. skipped/cancelled/queued/in-progress excluded.
# ════════════════════════════════════════════════════════════════════════════
ci_json="$(gh run list --repo "$GH_REPO" --limit 200 --json conclusion,createdAt \
           --jq "[.[]|select(.createdAt>\"$CUT_24H\")]|{s:([.[]|select(.conclusion==\"success\")]|length),f:([.[]|select(.conclusion==\"failure\")]|length)}" 2>/dev/null)"
ci_s="$(printf '%s' "$ci_json" | jq -r '.s // 0' 2>/dev/null)"
ci_f="$(printf '%s' "$ci_json" | jq -r '.f // 0' 2>/dev/null)"
ci_decided=$(( ${ci_s:-0} + ${ci_f:-0} ))
if (( ci_decided > 0 )); then
  ci_rate="$(awk -v s="$ci_s" -v d="$ci_decided" 'BEGIN{printf "%.1f", 100*s/d}')"
  s="$(status_hi "$ci_rate" "$CFG_CI_GREEN" "$CFG_CI_AMBER")"
  SIGNS+=("$(mksign ci_pass_rate "CI Pass Rate" quality leading \
    "$(jnum "$ci_rate")" "percent" "$s" \
    "find the flaky/failing gate" \
    "$ci_s success / $ci_decided decided runs in 24h (skipped/cancelled/queued excluded) (gh run list)" \
    "{\"green\":\">$CFG_CI_GREEN\",\"amber\":\"$CFG_CI_AMBER-$CFG_CI_GREEN\",\"red_desc\":\"<$CFG_CI_AMBER%\"}")")
else
  SIGNS+=("$(mksign ci_pass_rate "CI Pass Rate" quality leading \
    null "percent" "unknown" "find the flaky/failing gate" \
    "uninstrumented: 0 decided CI runs in the 24h window" \
    "{\"green\":\">$CFG_CI_GREEN\",\"amber\":\"$CFG_CI_AMBER-$CFG_CI_GREEN\",\"red_desc\":\"<$CFG_CI_AMBER%\"}")")
fi

# ════════════════════════════════════════════════════════════════════════════
# 4 · merged_not_running  (quality / leading)  — organs active / manifest %.
#     The "merged != running" disease made observable: is what we built LIVE?
# ════════════════════════════════════════════════════════════════════════════
if [[ -f "$MANIFEST" ]] && command -v systemctl >/dev/null 2>&1; then
  org_tot=0; org_act=0; org_down=""
  while read -r _ unit _; do
    [[ -z "$unit" ]] && continue
    org_tot=$((org_tot+1))
    if [[ "$(systemctl is-active "$unit" 2>/dev/null)" == active ]]; then
      org_act=$((org_act+1))
    else
      org_down="${org_down}${org_down:+,}${unit}"
    fi
  done < <(grep -E '^enabled' "$MANIFEST")
  if (( org_tot > 0 )); then
    org_pct="$(awk -v a="$org_act" -v t="$org_tot" 'BEGIN{printf "%.1f", 100*a/t}')"
    s="$(status_hi "$org_pct" "$CFG_ORGAN_GREEN" "$CFG_ORGAN_AMBER")"
    SIGNS+=("$(mksign merged_not_running "Merged-not-Running" quality leading \
      "$(jnum "$org_pct")" "percent-organs-active" "$s" \
      "roll-call + revive the dead organ" \
      "$org_act/$org_tot manifest organs systemctl is-active${org_down:+ (down: $org_down)}" \
      "{\"green\":\">$CFG_ORGAN_GREEN\",\"amber\":\"$CFG_ORGAN_AMBER-$CFG_ORGAN_GREEN\",\"red_desc\":\"<$CFG_ORGAN_AMBER% active\"}")")
  else
    SIGNS+=("$(mksign merged_not_running "Merged-not-Running" quality leading \
      null "percent-organs-active" "unknown" "roll-call + revive the dead organ" \
      "uninstrumented: no 'enabled' rows in organ-manifest.txt" \
      "{\"green\":\">$CFG_ORGAN_GREEN\",\"amber\":\"$CFG_ORGAN_AMBER-$CFG_ORGAN_GREEN\",\"red_desc\":\"<$CFG_ORGAN_AMBER% active\"}")")
  fi
else
  SIGNS+=("$(mksign merged_not_running "Merged-not-Running" quality leading \
    null "percent-organs-active" "unknown" "roll-call + revive the dead organ" \
    "uninstrumented: organ-manifest.txt or systemctl unavailable on this host" \
    "{\"green\":\">$CFG_ORGAN_GREEN\",\"amber\":\"$CFG_ORGAN_AMBER-$CFG_ORGAN_GREEN\",\"red_desc\":\"<$CFG_ORGAN_AMBER% active\"}")")
fi

# ════════════════════════════════════════════════════════════════════════════
# 5 · conflict_churn  (waste / leading)  — DIRTY open PR count (rework backlog).
# ════════════════════════════════════════════════════════════════════════════
dirty="$(gh pr list --repo "$GH_REPO" --state open --limit 400 --json mergeStateStatus \
         --jq '[.[]|select(.mergeStateStatus=="DIRTY")]|length' 2>/dev/null)"
if [[ "$dirty" =~ ^[0-9]+$ ]]; then
  s="$(status_lo "$dirty" "$CFG_DIRTY_GREEN" "$CFG_DIRTY_AMBER")"
  SIGNS+=("$(mksign conflict_churn "Conflict Churn" waste leading \
    "$(jnum "$dirty")" "DIRTY-open-PRs" "$s" \
    "resolver drain / merge-queue" \
    "$dirty open PR(s) in mergeStateStatus=DIRTY (gh pr list)" \
    "{\"green\":\"<$CFG_DIRTY_GREEN\",\"amber\":\"$CFG_DIRTY_GREEN-$CFG_DIRTY_AMBER\",\"red_desc\":\">$CFG_DIRTY_AMBER DIRTY PRs\"}")")
else
  SIGNS+=("$(mksign conflict_churn "Conflict Churn" waste leading \
    null "DIRTY-open-PRs" "unknown" "resolver drain / merge-queue" \
    "uninstrumented: gh pr list returned no parseable count" \
    "{\"green\":\"<$CFG_DIRTY_GREEN\",\"amber\":\"$CFG_DIRTY_GREEN-$CFG_DIRTY_AMBER\",\"red_desc\":\">$CFG_DIRTY_AMBER DIRTY PRs\"}")")
fi

# ════════════════════════════════════════════════════════════════════════════
# 6 · calibration_brier  (trust / meta)  — is the PR-book pricing HONEST?
#     Brier from pr-book-calibration.log if present; else unknown (uninstrumented).
#     Log format expected: one JSON obj/line with .predicted (0..1) and .outcome (0|1).
# ════════════════════════════════════════════════════════════════════════════
brier=""
if [[ -s "$PR_BOOK_CALIB" ]]; then
  brier="$(jq -rs '
    [ .[] | select((.predicted!=null) and (.outcome!=null))
          | ((.predicted - .outcome) * (.predicted - .outcome)) ] as $sq
    | if ($sq|length)>0 then ($sq|add/length) else empty end' \
    "$PR_BOOK_CALIB" 2>/dev/null)"
fi
if [[ "$brier" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  brier_r="$(awk -v b="$brier" 'BEGIN{printf "%.4f", b}')"
  s="$(status_lo "$brier_r" "$CFG_BRIER_GREEN" "$CFG_BRIER_AMBER")"
  SIGNS+=("$(mksign calibration_brier "Calibration (Brier)" trust meta \
    "$(jnum "$brier_r")" "brier-score" "$s" \
    "audit pricing model — the board may be lying" \
    "Brier over scored predictions in $PR_BOOK_CALIB" \
    "{\"green\":\"<$CFG_BRIER_GREEN\",\"amber\":\"$CFG_BRIER_GREEN-$CFG_BRIER_AMBER\",\"red_desc\":\">$CFG_BRIER_AMBER\"}")")
else
  SIGNS+=("$(mksign calibration_brier "Calibration (Brier)" trust meta \
    null "brier-score" "unknown" \
    "audit pricing model — the board may be lying" \
    "uninstrumented: no scored-outcome log at $PR_BOOK_CALIB (pr-book-ledger.jsonl records predictions but not realized merge outcomes — a settler that joins price->did-it-merge would light this)" \
    "{\"green\":\"<$CFG_BRIER_GREEN\",\"amber\":\"$CFG_BRIER_GREEN-$CFG_BRIER_AMBER\",\"red_desc\":\">$CFG_BRIER_AMBER\"}")")
fi

# ════════════════════════════════════════════════════════════════════════════
# 7 · human_intervention  (autonomy / lagging)  — operator pages / 24h.
#     Counts kind in {operator_page, operator_paged, pager_notified} in 24h.
#     A missing organ is whatever keeps paging a human.
# ════════════════════════════════════════════════════════════════════════════
if [[ -f "$AMBIENT_LOG" ]]; then
  pages="$(grep -hE '"kind":"(operator_page|operator_paged|pager_notified)"' "$AMBIENT_LOG" 2>/dev/null \
    | awk -v c="$CUT_24H" -F'"ts":"' '{split($2,a,"\""); if(a[1]>c) n++} END{print n+0}')"
  [[ "$pages" =~ ^[0-9]+$ ]] || pages=0
  s="$(status_lo "$pages" "$CFG_PAGES_GREEN" "$CFG_PAGES_AMBER")"
  SIGNS+=("$(mksign human_intervention "Human Intervention" autonomy lagging \
    "$(jnum "$pages")" "pages/24h" "$s" \
    "a missing organ — find what humans keep doing" \
    "$pages operator page(s) in 24h (ambient kind in operator_page|operator_paged|pager_notified)" \
    "{\"green\":\"<$CFG_PAGES_GREEN\",\"amber\":\"$CFG_PAGES_GREEN-$CFG_PAGES_AMBER\",\"red_desc\":\">$CFG_PAGES_AMBER pages/24h\"}")")
else
  SIGNS+=("$(mksign human_intervention "Human Intervention" autonomy lagging \
    null "pages/24h" "unknown" \
    "a missing organ — find what humans keep doing" \
    "uninstrumented: ambient log not found at $AMBIENT_LOG" \
    "{\"green\":\"<$CFG_PAGES_GREEN\",\"amber\":\"$CFG_PAGES_GREEN-$CFG_PAGES_AMBER\",\"red_desc\":\">$CFG_PAGES_AMBER pages/24h\"}")")
fi

# ════════════════════════════════════════════════════════════════════════════
# 8 · outcomes_delivered  (mission / lagging)  — the TRUEST number: things that
#     actually reached a PERSON in 24h. No honest instrument exists yet: internal
#     fleet merges are NOT user outcomes, and conflating them would make the board
#     lie about the mission. Reported "unknown"/uninstrumented until a real
#     delivery signal (a deploy-to-user / giveaway-told / tool-shipped ambient
#     event keyed to an external human) exists.
# ════════════════════════════════════════════════════════════════════════════
outcomes=""  # no trustworthy proxy today
if [[ "$outcomes" =~ ^[0-9]+$ ]]; then
  s="$(status_hi "$outcomes" "$CFG_OUT_GREEN" "$CFG_OUT_AMBER")"
  SIGNS+=("$(mksign outcomes_delivered "Outcomes Delivered" mission lagging \
    "$(jnum "$outcomes")" "things-reaching-a-person/24h" "$s" \
    "the truest number — instrument it" \
    "$outcomes delivery event(s) in 24h" \
    "{\"green\":\">=$CFG_OUT_GREEN\",\"amber\":\"$CFG_OUT_AMBER-$CFG_OUT_GREEN\",\"red_desc\":\"<$CFG_OUT_AMBER/24h\"}")")
else
  SIGNS+=("$(mksign outcomes_delivered "Outcomes Delivered" mission lagging \
    null "things-reaching-a-person/24h" "unknown" \
    "the truest number — instrument it" \
    "uninstrumented: no delivery-to-a-person signal exists yet. Internal merges are NOT outcomes; a real proxy needs a deploy-to-user / giveaway-told / tool-shipped ambient event keyed to an external human. HONEST-unknown until then." \
    "{\"green\":\">=$CFG_OUT_GREEN\",\"amber\":\"$CFG_OUT_AMBER-$CFG_OUT_GREEN\",\"red_desc\":\"<$CFG_OUT_AMBER/24h\"}")")
fi

# ── p_full_trek roll-up (read from journey-odds.json if present, else null) ──
# init first: under set -u an absent journey-odds.json would leave p_full unbound
# and crash the whole board (no write = the worst dishonesty). Default to null.
p_full=""
if [[ -s "$JOURNEY_ODDS" ]]; then
  p_full="$(jq -r '.p_full_trek // empty' "$JOURNEY_ODDS" 2>/dev/null)"
fi
[[ "$p_full" =~ ^[0-9]+([.][0-9]+)?$ ]] || p_full=""

# ── assemble ────────────────────────────────────────────────────────────────
signs_json="$(printf '%s\n' "${SIGNS[@]}" | jq -s '.')"
DOC="$(jq -n \
  --arg ts "$NOW" \
  --argjson pft "$(jnum "$p_full")" \
  --argjson signs "$signs_json" \
  '{generated_at:$ts, p_full_trek:$pft, signs:$signs}')"

if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s\n' "$DOC"
  exit 0
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
tmp="$(mktemp "${TMPDIR:-$REAL_HOME/.chump}/vital-signs.XXXXXX.json" 2>/dev/null || echo "$OUT.tmp")"
printf '%s\n' "$DOC" > "$tmp" && mv -f "$tmp" "$OUT"

# ── ambient heartbeat: a dead collector / frozen board is observable ─────────
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
n_signs="$(printf '%s' "$DOC" | jq '.signs|length')"
n_red="$(printf '%s' "$DOC" | jq '[.signs[]|select(.status=="red")]|length')"
n_amber="$(printf '%s' "$DOC" | jq '[.signs[]|select(.status=="amber")]|length')"
n_green="$(printf '%s' "$DOC" | jq '[.signs[]|select(.status=="green")]|length')"
n_unknown="$(printf '%s' "$DOC" | jq '[.signs[]|select(.status=="unknown")]|length')"
printf '{"ts":"%s","kind":"vital_signs","signs":%s,"green":%s,"amber":%s,"red":%s,"unknown":%s,"p_full_trek":%s,"out":"%s"}\n' \
  "$NOW" "$n_signs" "$n_green" "$n_amber" "$n_red" "$n_unknown" "$(jnum "$p_full")" "$OUT" >> "$AMBIENT_LOG" 2>/dev/null || true

echo "[vital-signs] wrote $OUT ($n_signs signs: ${n_green}G/${n_amber}A/${n_red}R/${n_unknown}U, p_full_trek=${p_full:-null}) @ $NOW"
