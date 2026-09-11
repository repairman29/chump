#!/usr/bin/env bash
# scripts/ops/self-model.sh — RESILIENT-1113 (DESIGN GAP 5: no faithful self-model)
#
# The one honest mirror: cross-references what the repo CLAIMS is running
# (scripts/ops/organ-manifest.txt — the desired-state roster of organs/timers)
# against what systemd says IS actually running, plus a static roster of the
# cockpit surfaces that exist on disk. Before this script, the operator had
# to hand-build a "Prime Operating State" page on claude.ai because no repo
# surface told the truth about itself in one place — 35+ organs, dozens of
# timers, several cockpit dashboards, and not one single honest reflection.
#
# This is NOT a new dashboard and NOT a new source of truth: it reads the
# manifest (already canonical, per organ-reconcile.sh) and systemd (already
# ground truth, per organ-manifest-lib.sh), and reports where they DISAGREE
# — that disagreement, "drifted", is exactly the thing a hand-built page
# can't compute because a human can't diff 35 organs against systemd by eye.
#
# Usage:
#   scripts/ops/self-model.sh              # collect + write ~/.chump/self-model.json
#   scripts/ops/self-model.sh --dry-run    # print JSON to stdout, no writes
#
# Env overrides (all optional, mirrors organ-reconcile.sh's stub pattern):
#   CHUMP_REPO_ROOT / REPO_ROOT            repo checkout root
#   CHUMP_SELF_MODEL_OUT                   output json path (default ~/.chump/self-model.json)
#   CHUMP_SELF_MODEL_MANIFEST              organ-manifest.txt path (default REPO_ROOT/scripts/ops/organ-manifest.txt)
#   CHUMP_SELF_MODEL_SYSTEMCTL_BIN         systemctl binary (test hook; default "systemctl")
#   CHUMP_AMBIENT_LOG                      ambient jsonl (default REPO_ROOT/.chump-locks/ambient.jsonl)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

MANIFEST="${CHUMP_SELF_MODEL_MANIFEST:-$REPO_ROOT/scripts/ops/organ-manifest.txt}"
OUT="${CHUMP_SELF_MODEL_OUT:-$HOME/.chump/self-model.json}"
SYSTEMCTL_BIN="${CHUMP_SELF_MODEL_SYSTEMCTL_BIN:-systemctl}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

DRY_RUN=0
for a in "$@"; do
  [[ "$a" == "--dry-run" ]] && DRY_RUN=1
done

# shellcheck source=scripts/ops/lib/organ-manifest-lib.sh
source "$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"

declare -a PAGING_OFF ENABLED
declare -A ROLE REQUIRES

if ! organ_manifest_parse "$MANIFEST" PAGING_OFF ENABLED ROLE REQUIRES; then
  echo "ERROR: could not parse manifest $MANIFEST" >&2
  exit 1
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")"

# ── the live cross-reference: for every unit the manifest CLAIMS is enabled,
# ask systemd what's ACTUALLY true. A unit is "drifted" when the manifest
# says it must be active but systemd disagrees — the exact class that hid
# the CHDIR incident (is-active=true while every run failed is a DIFFERENT,
# narrower check owned by organ-success-verifier.sh; this one is coarser:
# "is it even running at all", the first honesty bar before verified-working).
organs=() timers=()
active_organs=0 active_timers=0
drifted=()

for unit in "${ENABLED[@]}"; do
  state="inactive"
  if "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null; then
    state="active"
  fi
  if [[ "$unit" == *.timer ]]; then
    timers+=("$unit")
    [[ "$state" == active ]] && active_timers=$((active_timers+1))
  else
    organs+=("$unit")
    [[ "$state" == active ]] && active_organs=$((active_organs+1))
  fi
  if [[ "$state" != active ]]; then
    drifted+=("$unit")
  fi
done

organs_total=${#organs[@]}
timers_total=${#timers[@]}
drifted_total=${#drifted[@]}

# ── cockpit surfaces: the repo-known dashboards, checked for real presence
# on disk (not assumed). Any surface not found is honestly reported absent
# rather than silently dropped from the count.
declare -A COCKPIT_SURFACES=(
  [web/cockpit]="$REPO_ROOT/web/cockpit"
  [web/cockpit-live]="$REPO_ROOT/web/cockpit-live"
  [web/v2 cockpit.js]="$REPO_ROOT/web/v2/cockpit.js"
  [chump-fleet-server]="$REPO_ROOT/crates/chump-fleet-server"
)
cockpit_json="[]"
cockpit_present=0
for name in "${!COCKPIT_SURFACES[@]}"; do
  path="${COCKPIT_SURFACES[$name]}"
  present=false
  if [[ -e "$path" ]]; then
    present=true
    cockpit_present=$((cockpit_present+1))
  fi
  cockpit_json="$(printf '%s' "$cockpit_json" | jq --arg n "$name" --arg p "$path" --argjson pr "$present" \
    '. + [{name:$n, path:$p, present:$pr}]')"
done
cockpit_total=${#COCKPIT_SURFACES[@]}

organs_json="$(printf '%s\n' "${organs[@]:-}" | jq -R 'select(length>0)' | jq -s '.')"
timers_json="$(printf '%s\n' "${timers[@]:-}" | jq -R 'select(length>0)' | jq -s '.')"
drifted_json="$(printf '%s\n' "${drifted[@]:-}" | jq -R 'select(length>0)' | jq -s '.')"

DOC="$(jq -n \
  --arg ts "$NOW" \
  --argjson organs_total "$organs_total" \
  --argjson organs_active "$active_organs" \
  --argjson timers_total "$timers_total" \
  --argjson timers_active "$active_timers" \
  --argjson organs "$organs_json" \
  --argjson timers "$timers_json" \
  --argjson drifted "$drifted_json" \
  --argjson drifted_total "$drifted_total" \
  --argjson cockpit_surfaces "$cockpit_json" \
  --argjson cockpit_total "$cockpit_total" \
  --argjson cockpit_present "$cockpit_present" \
  '{
    generated_at: $ts,
    honest: true,
    organs: {manifest_total: $organs_total, active: $organs_active, names: $organs},
    timers: {manifest_total: $timers_total, active: $timers_active, names: $timers},
    drifted: {total: $drifted_total, units: $drifted},
    cockpit_surfaces: {total: $cockpit_total, present: $cockpit_present, surfaces: $cockpit_surfaces}
  }')"

if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s\n' "$DOC"
  exit 0
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
tmp="$(mktemp "${TMPDIR:-$HOME/.chump}/self-model.XXXXXX.json" 2>/dev/null || echo "$OUT.tmp")"
printf '%s\n' "$DOC" > "$tmp" && mv -f "$tmp" "$OUT"

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
printf '{"ts":"%s","kind":"self_model_tick","organs_total":%s,"organs_active":%s,"timers_total":%s,"timers_active":%s,"drifted_total":%s,"cockpit_total":%s,"cockpit_present":%s,"out":"%s"}\n' \
  "$NOW" "$organs_total" "$active_organs" "$timers_total" "$active_timers" "$drifted_total" "$cockpit_total" "$cockpit_present" "$OUT" >> "$AMBIENT_LOG" 2>/dev/null || true

echo "[self-model] wrote $OUT (organs ${active_organs}/${organs_total}, timers ${active_timers}/${timers_total}, drifted ${drifted_total}, cockpit ${cockpit_present}/${cockpit_total}) @ $NOW"
