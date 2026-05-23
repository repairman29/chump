#!/usr/bin/env bash
# scripts/ops/audit-flake-catalog.sh — INFRA-1866 (parent INFRA-1861 slice a)
#
# Daily audit: every '- test:' entry in docs/process/KNOWN_FLAKES.yaml MUST
# have a sibling 'tracking_gap: INFRA-NNNN' key. Entries missing tracking_gap
# are 'orphans' — the flake-rerun harness will keep masking them indefinitely
# without anyone owning the fix. Catalog discipline (per the file's own
# preamble): the catalog is a stop-gap, not a parking lot.
#
# Emits:
#   - kind=flake_catalog_orphan {test, last_observed}  for each orphan
#   - WARN broadcast to operator-*  if any orphans found
#
# Exit:
#   0 — no orphans
#   1 — orphans found (cron alerts via launchctl monitoring)
#
# Bypass: CHUMP_AUDIT_FLAKE_CATALOG=0 silently exits 0 (still emits audit line).
#
# Usage:
#   audit-flake-catalog.sh            # daily mode: emit + broadcast
#   audit-flake-catalog.sh --json     # machine-readable, no broadcast
#   audit-flake-catalog.sh --dry-run  # compute + log, skip ambient + broadcast

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
FLAKES_YAML="${CHUMP_KNOWN_FLAKES:-$REPO_ROOT/docs/process/KNOWN_FLAKES.yaml}"

JSON=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "audit-flake-catalog: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [[ "${CHUMP_AUDIT_FLAKE_CATALOG:-1}" == "0" ]]; then
    printf '{"ts":"%s","kind":"audit_flake_catalog_bypassed","reason":"CHUMP_AUDIT_FLAKE_CATALOG=0"}\n' \
        "$(now_ts)" >> "$AMBIENT_LOG" 2>/dev/null || true
    echo "[audit-flake-catalog] bypassed via CHUMP_AUDIT_FLAKE_CATALOG=0"
    exit 0
fi

if [[ ! -r "$FLAKES_YAML" ]]; then
    echo "[audit-flake-catalog] cannot read $FLAKES_YAML — skipping" >&2
    exit 0
fi

# Parse via python3 (no PyYAML dep — line-oriented walk against the documented
# 2-space-indent schema in docs/process/KNOWN_FLAKES.yaml preamble).
REPORT=$(FLAKES_YAML="$FLAKES_YAML" python3 - <<'PYEOF'
import os
import json
import re

path = os.environ["FLAKES_YAML"]

orphans = []
all_entries = []
current = None

with open(path) as f:
    for raw in f:
        line = raw.rstrip("\n")
        # Match '  - test: foo::bar::baz' (entry header).
        m = re.match(r"^\s{0,4}-\s+test:\s+(.+?)\s*$", line)
        if m:
            if current is not None:
                all_entries.append(current)
            current = {"test": m.group(1).strip(), "tracking_gap": None,
                       "last_observed": None, "added": None}
            continue
        # Match indented child keys.
        if current is not None:
            mt = re.match(r"^\s+tracking_gap:\s+(\S+)\s*$", line)
            mo = re.match(r"^\s+last_observed:\s+(\S+)\s*$", line)
            ma = re.match(r"^\s+added:\s+(\S+)\s*$", line)
            if mt:
                current["tracking_gap"] = mt.group(1).strip()
            elif mo:
                current["last_observed"] = mo.group(1).strip()
            elif ma:
                current["added"] = ma.group(1).strip()

if current is not None:
    all_entries.append(current)

for e in all_entries:
    if not e.get("tracking_gap"):
        orphans.append({
            "test": e["test"],
            "last_observed": e.get("last_observed") or "unknown",
            "added": e.get("added") or "unknown",
        })

print(json.dumps({
    "total_entries": len(all_entries),
    "orphan_count": len(orphans),
    "orphans": orphans,
}, separators=(',', ':')))
PYEOF
)

ORPHAN_COUNT=$(echo "$REPORT" | python3 -c "import json,sys; print(json.load(sys.stdin)['orphan_count'])")

if [[ "$JSON" -eq 1 ]]; then
    echo "$REPORT"
    if (( ORPHAN_COUNT > 0 )); then exit 1; fi
    exit 0
fi

# Emit per-orphan ambient lines + summarize.
if [[ "$DRY_RUN" -eq 0 && "$ORPHAN_COUNT" -gt 0 ]]; then
    python3 -c "
import json
d = json.loads('''$REPORT''')
ts = '$(now_ts)'
for o in d['orphans']:
    line = json.dumps({
        'ts': ts, 'kind': 'flake_catalog_orphan',
        'test': o['test'], 'last_observed': o['last_observed'],
        'added': o['added'],
    }, separators=(',', ':'))
    print(line)
" >> "$AMBIENT_LOG" 2>/dev/null || true
fi

SUMMARY=$(python3 -c "
import json
d = json.loads('''$REPORT''')
if d['orphan_count'] == 0:
    print(f\"all {d['total_entries']} entries tracked — no orphans\")
else:
    out = [f\"{d['orphan_count']} of {d['total_entries']} entries missing tracking_gap:\"]
    for o in d['orphans'][:10]:
        out.append(f\"  - {o['test']}  (last_observed={o['last_observed']}, added={o['added']})\")
    if d['orphan_count'] > 10:
        out.append(f\"  ... and {d['orphan_count'] - 10} more\")
    print(chr(10).join(out))
")

cat <<EOM
[audit-flake-catalog] $FLAKES_YAML
$SUMMARY
EOM

if [[ "$DRY_RUN" -eq 0 && "$ORPHAN_COUNT" -gt 0 ]]; then
    bash "$REPO_ROOT/scripts/coord/broadcast.sh" WARN \
        --reason "[audit-flake-catalog] ${ORPHAN_COUNT} orphan(s) in KNOWN_FLAKES.yaml — entries masking failures without tracking gaps. Run 'scripts/ops/audit-flake-catalog.sh' for details." \
        2>/dev/null || true
fi

if (( ORPHAN_COUNT > 0 )); then exit 1; fi
exit 0
