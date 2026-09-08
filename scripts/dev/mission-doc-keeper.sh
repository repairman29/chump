#!/usr/bin/env bash
# mission-doc-keeper.sh (EFFECTIVE-514) — regenerates the dynamic section of
# docs/mission-tote-board.html from live fleet state so the canonical,
# version-controlled HTML asset stays current without a human hand-editing it.
#
# Data sources (live state, not opinion):
#   - gap status counts, by domain          .chump/state.db (via `chump gap list --json`)
#   - live_pct / debt crown gauge            `chump kpi report --debt-index --json`
#
# Usage:
#   scripts/dev/mission-doc-keeper.sh              regenerate in place
#   scripts/dev/mission-doc-keeper.sh --html PATH   target a different HTML file (default: docs/mission-tote-board.html)
#
# Constraint (per gap description): republishing an artifact URL needs a
# Claude Code session; this script only keeps the in-repo static HTML fresh.
# A scheduled session (see launchd/ or `chump cron install`) is what actually
# republishes the artifact on a cadence.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

HTML="$ROOT/docs/mission-tote-board.html"
BEGIN_MARK="<!-- MISSION-DOC-KEEPER:BEGIN dynamic -->"
END_MARK="<!-- MISSION-DOC-KEEPER:END dynamic -->"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --html) HTML="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0 ;;
    *) echo "[mission-doc-keeper] unknown flag: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$HTML" ]] || { echo "[mission-doc-keeper] target HTML not found: $HTML" >&2; exit 1; }
grep -qF "$BEGIN_MARK" "$HTML" || { echo "[mission-doc-keeper] missing BEGIN marker in $HTML" >&2; exit 1; }
grep -qF "$END_MARK" "$HTML" || { echo "[mission-doc-keeper] missing END marker in $HTML" >&2; exit 1; }

# --- gap status counts (live fleet state) -----------------------------------
open_count=0
if command -v chump >/dev/null 2>&1; then
  open_count="$(chump gap list --status open --json 2>/dev/null \
    | python3 -c 'import json,sys
try:
    rows = json.load(sys.stdin)
    print(len(rows) if isinstance(rows, list) else 0)
except Exception:
    print(0)' 2>/dev/null || echo 0)"
fi
open_count="${open_count:-0}"

# --- debt index crown gauge (live_pct / debt) -------------------------------
debt_json="$(chump kpi report --debt-index --json 2>/dev/null || echo '{}')"
live_pct="$(echo "$debt_json" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(f"{float(d.get(\"live_pct\", 0.0)) * 100:.1f}")
except Exception:
    print("0.0")' 2>/dev/null || echo "0.0")"
debt="$(echo "$debt_json" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(f"{float(d.get(\"debt\", 0.0)):.2f}")
except Exception:
    print("0.00")' 2>/dev/null || echo "0.00")"

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

new_block=$(cat <<EOF
$BEGIN_MARK
  <ul id="mission-tote-board-stats">
    <li id="stat-open-gaps">Open gaps: <strong>${open_count}</strong></li>
    <li id="stat-live-pct">live_pct: <strong>${live_pct}%</strong></li>
    <li id="stat-debt">debt: <strong>${debt}</strong></li>
  </ul>
  <p class="generated-at">Generated: ${generated_at} by scripts/dev/mission-doc-keeper.sh</p>
  $END_MARK
EOF
)

# Replace everything between (and including) the markers with the new block.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
python3 - "$HTML" "$BEGIN_MARK" "$END_MARK" "$new_block" > "$tmp" <<'PYEOF'
import sys
path, begin, end, block = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    text = f.read()
start = text.index(begin)
stop = text.index(end) + len(end)
sys.stdout.write(text[:start] + block + text[stop:])
PYEOF

cp "$tmp" "$HTML"
echo "[mission-doc-keeper] regenerated $HTML (open_gaps=$open_count live_pct=${live_pct}% debt=${debt})"
