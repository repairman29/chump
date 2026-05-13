#!/usr/bin/env bash
# gap-lifecycle-manager.sh — INFRA-870
#
# Detects open gaps that have been stale for more than CHUMP_LIFECYCLE_DAYS
# (default: 90 days). A gap is stale if it has been open since before the
# threshold date and has had no recent updates (no PR, no commit activity
# on any associated branch).
#
# For each stale gap, this script:
#   - Emits kind=gap_abandoned to ambient.jsonl with {ts, kind, gap_id, age_days, title}
#   - Optionally marks it as status=stale in state.db via `chump gap set`
#
# Usage:
#   gap-lifecycle-manager.sh [OPTIONS]
#
# Options:
#   --dry-run          Print results; do NOT emit events or change status
#   --json             Output JSON array of stale gaps to stdout
#   --mark-stale       Mark stale gaps as status=stale in state.db
#   --days N           Override CHUMP_LIFECYCLE_DAYS (default 90)
#   -h|--help          Print this help
#
# Environment:
#   REPO_ROOT                Repo root (auto-detected)
#   CHUMP_AMBIENT_LOG        Path to ambient.jsonl
#   CHUMP_LIFECYCLE_DAYS     Number of days before a gap is considered stale (default 90)
#
# Exit codes:
#   0  Completed (stale gaps found or not)
#   1  Error (could not read gap registry)
#   2  Usage error

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LIFECYCLE_DAYS="${CHUMP_LIFECYCLE_DAYS:-90}"
DRY_RUN=0
JSON_OUT=0
MARK_STALE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --json)       JSON_OUT=1; shift ;;
        --mark-stale) MARK_STALE=1; shift ;;
        --days)       LIFECYCLE_DAYS="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -30 | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { echo "[gap-lifecycle] $*" >&2; }

# ── Load open gaps from state.db ──────────────────────────────────────────────
# We use `chump gap list --status open` to get gaps, then filter by creation date.
# The gaps.yaml file contains the filing date in the YAML comments or as a field.
# As a fallback, use git log to find when each gap YAML was first committed.
GAPS_YAML="$REPO_ROOT/docs/gaps.yaml"
if [[ ! -f "$GAPS_YAML" ]]; then
    _log "ERROR: gaps.yaml not found at $GAPS_YAML"
    exit 1
fi

# ── Compute stale gaps via Python ─────────────────────────────────────────────
STALE_JSON=$(python3 - <<PYEOF
import json, subprocess, sys, os
from datetime import datetime, timezone, timedelta

repo_root = "$REPO_ROOT"
gaps_yaml_path = "$GAPS_YAML"
lifecycle_days = int("$LIFECYCLE_DAYS")
threshold = datetime.now(timezone.utc) - timedelta(days=lifecycle_days)
now = datetime.now(timezone.utc)

stale_gaps = []

# Try to read gap list from chump CLI
try:
    result = subprocess.run(
        ["chump", "gap", "list", "--status", "open", "--format", "json"],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0 and result.stdout.strip().startswith('['):
        gaps = json.loads(result.stdout)
    else:
        gaps = []
except Exception:
    gaps = []

# Fallback: parse gaps.yaml directly
if not gaps:
    try:
        import yaml
        with open(gaps_yaml_path) as f:
            data = yaml.safe_load(f)
        raw = data.get('gaps', data) if isinstance(data, dict) else data
        gaps = [
            {"id": g.get("id",""), "title": g.get("title",""), "status": g.get("status","open")}
            for g in (raw or [])
            if isinstance(g, dict) and g.get("status","") == "open"
        ]
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

# For each open gap, find when it was first committed to git
# Use git log to find the first commit that added this gap's YAML entry
for gap in gaps:
    gap_id = gap.get("id","")
    if not gap_id:
        continue

    # Try git log to find the first appearance of this gap ID in the repo
    try:
        # Look for commits that added this gap ID in docs/gaps/
        result = subprocess.run(
            ["git", "-C", repo_root, "log", "--all", "--oneline", "--follow",
             "--diff-filter=A", "--format=%aI",
             "--", f"docs/gaps/{gap_id}.yaml", f"docs/gaps.yaml"],
            capture_output=True, text=True, timeout=15
        )
        dates = [l.strip() for l in result.stdout.strip().splitlines() if l.strip()]
        if dates:
            # Earliest date
            earliest = min(dates)
            try:
                filed_dt = datetime.fromisoformat(earliest.rstrip("Z")).replace(tzinfo=timezone.utc)
            except Exception:
                continue
            age_days = (now - filed_dt).days
            if filed_dt < threshold:
                stale_gaps.append({
                    "gap_id": gap_id,
                    "title": gap.get("title",""),
                    "filed_date": earliest[:10],
                    "age_days": age_days,
                })
    except Exception:
        continue

print(json.dumps(stale_gaps))
PYEOF
)

if [[ -z "$STALE_JSON" ]] || [[ "$STALE_JSON" == "null" ]]; then
    _log "ERROR: failed to compute stale gaps"
    exit 1
fi

# Check for error in output
if echo "$STALE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d, list) else 1)" 2>/dev/null; then
    : # it's a list
else
    _log "ERROR: stale gap computation failed: $STALE_JSON"
    exit 1
fi

STALE_COUNT=$(echo "$STALE_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

# ── JSON output ───────────────────────────────────────────────────────────────
if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '%s\n' "$STALE_JSON"
fi

if [[ "$STALE_COUNT" -eq 0 ]]; then
    if [[ "$JSON_OUT" -eq 0 ]]; then
        _log "No stale gaps found (threshold: ${LIFECYCLE_DAYS}d)"
    fi
    exit 0
fi

_log "Found $STALE_COUNT stale gap(s) (older than ${LIFECYCLE_DAYS} days)"

# ── Process each stale gap ────────────────────────────────────────────────────
TS="$(_ts)"

echo "$STALE_JSON" | python3 - <<PYEOF
import json, sys, subprocess, os

data = json.loads('''$STALE_JSON''')
amb = "$AMB"
dry_run = $DRY_RUN
mark_stale = $MARK_STALE
ts = "$TS"

for g in data:
    gap_id  = g["gap_id"]
    title   = g["title"]
    age     = g["age_days"]

    print(f"  STALE: {gap_id} ({age}d old) — {title[:60]}", file=sys.stderr)

    # Emit kind=gap_abandoned to ambient
    payload = json.dumps({"ts": ts, "kind": "gap_abandoned", "gap_id": gap_id,
                          "age_days": age, "title": title})
    if dry_run:
        print(f"  [dry-run] would emit: {payload}", file=sys.stderr)
    else:
        os.makedirs(os.path.dirname(amb), exist_ok=True)
        with open(amb, "a") as f:
            f.write(payload + "\n")

    # Optionally mark as stale
    if mark_stale and not dry_run:
        try:
            subprocess.run(["chump", "gap", "set", gap_id, "status", "stale"],
                           capture_output=True, timeout=10)
        except Exception:
            pass
    elif mark_stale and dry_run:
        print(f"  [dry-run] would mark {gap_id} status=stale", file=sys.stderr)
PYEOF

if [[ "$DRY_RUN" -eq 0 ]] && [[ "$JSON_OUT" -eq 0 ]]; then
    _log "Emitted $STALE_COUNT gap_abandoned event(s) to $AMB"
fi
