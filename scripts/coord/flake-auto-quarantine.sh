#!/usr/bin/env bash
# flake-auto-quarantine.sh — INFRA-2361
#
# Closes the loop the INFRA-2346 BLOCKED_FLAKE tier left open: when a check
# keeps hitting the per-PR flake-rerun cap (kind=flake_rerun_capped, emitted
# by pr-shepherd-daemon.sh) across MANY DISTINCT PRs, that's no longer a
# per-PR nuisance — it's a persistently flaky check that deserves a
# `check_flakes:` entry in docs/process/KNOWN_FLAKES.yaml so every future PR
# gets the auto-rerun benefit, instead of every PR author separately eating
# the cap and getting a noise gap filed against them.
#
# Failure-class taxonomy (AC-3):
#   transient — a check was capped on < CHUMP_FLAKE_QUARANTINE_PR_THRESHOLD
#               distinct PRs within the window. Not actioned; may self-heal
#               (root cause fixed, or was a one-off runner blip).
#   permanent — a check was capped on >= threshold distinct PRs within the
#               window. Actioned: quarantined + a tracking gap filed, on
#               the theory that N independent PRs hitting the same cap is
#               no longer explainable by chance.
#
# Cost tracking (AC-2): every tick emits kind=flake_auto_quarantine_tick
# with checks_evaluated / quarantined_count / gaps_filed_count so the
# operator can see the run's cost (gaps filed) without re-deriving it from
# raw ambient. `--report` replays past ticks + quarantine events for a
# human-readable summary.
#
# Events emitted (AC-1): flake_auto_quarantined (success),
# flake_auto_quarantine_failed (gap-reserve or catalog-write failed),
# flake_auto_quarantine_tick (once per run, summary/cost).
#
# Smoke test (AC-4): scripts/ci/test-flake-auto-quarantine.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

AMBIENT="${CHUMP_AMBIENT_PATH:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
KNOWN_FLAKES_FILE="${CHUMP_KNOWN_FLAKES_FILE:-$REPO_ROOT/docs/process/KNOWN_FLAKES.yaml}"
STATE_FILE="${CHUMP_FLAKE_QUARANTINE_STATE_FILE:-$REPO_ROOT/.chump-locks/flake-auto-quarantine-state.json}"
WINDOW_HOURS="${CHUMP_FLAKE_QUARANTINE_WINDOW_HOURS:-72}"
PR_THRESHOLD="${CHUMP_FLAKE_QUARANTINE_PR_THRESHOLD:-3}"
GAP_DOMAIN="${CHUMP_FLAKE_QUARANTINE_GAP_DOMAIN:-INFRA}"
CHUMP_BIN="${CHUMP_BIN:-chump}"
DRY_RUN="${CHUMP_FLAKE_QUARANTINE_DRY_RUN:-}"

mode="tick"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --report) mode="report" ;;
    *) echo "usage: flake-auto-quarantine.sh [--dry-run|--report]" >&2; exit 1 ;;
  esac
done

_now_epoch() { date -u +%s; }
_today() { date -u +%Y-%m-%d; }

# scanner-anchor: "kind":"flake_auto_quarantined" (INFRA-2361)
# scanner-anchor: "kind":"flake_auto_quarantine_failed" (INFRA-2361)
# scanner-anchor: "kind":"flake_auto_quarantine_tick" (INFRA-2361)
_emit() {
  local kind="$1" fields="$2"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"%s",%s,"dry_run":%s}\n' "$ts" "$kind" "$fields" "$dry" >> "$AMBIENT"
}

if [ "$mode" = "report" ]; then
  [ -f "$AMBIENT" ] || { echo "(no ambient stream yet)"; exit 0; }
  echo "=== flake-auto-quarantine report ==="
  echo "--- ticks (cost) ---"
  grep '"kind":"flake_auto_quarantine_tick"' "$AMBIENT" 2>/dev/null | tail -20 || true
  echo "--- quarantined ---"
  grep '"kind":"flake_auto_quarantined"' "$AMBIENT" 2>/dev/null | tail -20 || true
  echo "--- failed ---"
  grep '"kind":"flake_auto_quarantine_failed"' "$AMBIENT" 2>/dev/null | tail -20 || true
  exit 0
fi

[ -f "$AMBIENT" ] || { echo "[flake-auto-quarantine] no ambient stream at $AMBIENT — nothing to scan" >&2; exit 0; }

# _candidates — TSV of check_name\tpr_count\tpr_list_csv for checks that hit
# the flake-rerun cap on >= PR_THRESHOLD distinct PRs within WINDOW_HOURS,
# excluding checks already present in KNOWN_FLAKES.yaml check_flakes: or
# already quarantined per STATE_FILE.
_candidates() {
  python3 - "$AMBIENT" "$KNOWN_FLAKES_FILE" "$STATE_FILE" "$WINDOW_HOURS" "$PR_THRESHOLD" << 'PYEOF'
import json, re, sys, time
from datetime import datetime, timezone

ambient_path, catalog_path, state_path, window_hours, threshold = sys.argv[1:6]
window_hours = float(window_hours)
threshold = int(threshold)
cutoff = time.time() - window_hours * 3600

def parse_ts(ts):
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return 0

groups = {}
try:
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line or '"kind":"flake_rerun_capped"' not in line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if ev.get("kind") != "flake_rerun_capped":
                continue
            if parse_ts(ev.get("ts", "")) < cutoff:
                continue
            pr = ev.get("pr")
            names = ev.get("check_names", "")
            for name in names.split(","):
                name = name.strip()
                if not name:
                    continue
                groups.setdefault(name, set()).add(pr)
except FileNotFoundError:
    pass

known = set()
try:
    with open(catalog_path) as f:
        content = f.read()
    m = re.search(r'^check_flakes:\s*(.*?)(?=\n[A-Za-z_]+:|\Z)', content, re.DOTALL | re.MULTILINE)
    if m and not m.group(1).strip().startswith('[]'):
        for line in m.group(1).split('\n'):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            m2 = re.match(r'-?\s*check_name:\s*["\']?([^"\']+)["\']?\s*$', line)
            if m2:
                known.add(m2.group(1).strip())
except FileNotFoundError:
    pass

quarantined = set()
try:
    with open(state_path) as f:
        quarantined = set(json.load(f).keys())
except Exception:
    pass

for name, prs in sorted(groups.items()):
    if name in known or name in quarantined:
        continue
    if len(prs) < threshold:
        continue
    pr_list = ",".join(str(p) for p in sorted(prs))
    print(f"{name}\t{len(prs)}\t{pr_list}")
PYEOF
}

checks_evaluated=0
quarantined_count=0
gaps_filed_count=0

while IFS=$'\t' read -r check_name pr_count pr_list; do
  [ -z "$check_name" ] && continue
  checks_evaluated=$((checks_evaluated + 1))

  gap_id=""
  if [ -n "$DRY_RUN" ]; then
    echo "[flake-auto-quarantine] DRY_RUN: would quarantine '${check_name}' (capped on ${pr_count} PRs: ${pr_list})" >&2
    gap_id="DRY_RUN"
  else
    gap_title="quarantine flaky check: ${check_name}"
    gap_out=""
    if gap_out=$("$CHUMP_BIN" gap reserve --domain "$GAP_DOMAIN" --title "$gap_title" --priority P2 2>&1); then
      gap_id=$(echo "$gap_out" | grep -oE '(INFRA|RESILIENT|EFFECTIVE|CREDIBLE|ZERO-WASTE|MISSION|META)-[0-9]+' | tail -1 || true)
    fi
    if [ -z "$gap_id" ]; then
      _emit "flake_auto_quarantine_failed" "\"check_name\":\"${check_name}\",\"pr_count\":${pr_count},\"reason\":\"gap_reserve_failed\""
      continue
    fi
  fi

  entry="  - check_name: \"${check_name}\"
    reason: \"auto-quarantined: capped flake-reruns on ${pr_count} distinct PRs within ${WINDOW_HOURS}h window (INFRA-2361 auto-detector)\"
    tracking_gap: ${gap_id}
    added: \"$(_today)\"
    last_observed: \"$(_today)\"
    max_reruns: 2
"

  if [ -n "$DRY_RUN" ]; then
    _emit "flake_auto_quarantined" "\"check_name\":\"${check_name}\",\"pr_count\":${pr_count},\"gap_id\":\"${gap_id}\",\"failure_class\":\"permanent\""
    quarantined_count=$((quarantined_count + 1))
    continue
  fi

  if ! python3 - "$KNOWN_FLAKES_FILE" "$entry" << 'PYEOF'
import sys
path, entry = sys.argv[1], sys.argv[2]
if not entry.endswith("\n"):
    entry += "\n"
with open(path) as f:
    lines = f.readlines()
out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and line.rstrip("\n") == "check_flakes: []":
        out[-1] = "check_flakes:\n"
        out.append(entry)
        inserted = True
    elif not inserted and line.rstrip("\n") == "check_flakes:":
        out.append(entry)
        inserted = True
if not inserted:
    sys.exit(1)
with open(path, "w") as f:
    f.writelines(out)
PYEOF
  then
    _emit "flake_auto_quarantine_failed" "\"check_name\":\"${check_name}\",\"pr_count\":${pr_count},\"reason\":\"catalog_write_failed\""
    continue
  fi

  python3 -c "
import json
path = '$STATE_FILE'
try:
    with open(path) as f:
        state = json.load(f)
except Exception:
    state = {}
state['$check_name'] = {'quarantined_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)', 'gap_id': '$gap_id', 'pr_count': $pr_count}
with open(path, 'w') as f:
    json.dump(state, f, indent=2)
"

  _emit "flake_auto_quarantined" "\"check_name\":\"${check_name}\",\"pr_count\":${pr_count},\"gap_id\":\"${gap_id}\",\"failure_class\":\"permanent\""
  quarantined_count=$((quarantined_count + 1))
  gaps_filed_count=$((gaps_filed_count + 1))
done < <(_candidates)

_emit "flake_auto_quarantine_tick" "\"checks_evaluated\":${checks_evaluated},\"quarantined_count\":${quarantined_count},\"gaps_filed_count\":${gaps_filed_count},\"window_hours\":${WINDOW_HOURS},\"pr_threshold\":${PR_THRESHOLD}"
echo "[flake-auto-quarantine] evaluated=${checks_evaluated} quarantined=${quarantined_count} gaps_filed=${gaps_filed_count}" >&2
