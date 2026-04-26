#!/usr/bin/env bash
# check-open-but-landed.sh — find gaps marked status:open in docs/gaps.yaml that
# already have ≥1 commit on origin/main referencing the gap ID. Either the work
# landed without status flip (PR did not run `chump gap ship`), or someone
# reused the ID. Either way, an operator needs to look.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$REPO_ROOT"
log "scanning for open-but-landed gaps..."

git fetch origin main --quiet 2>/dev/null || true

TMP="$(mktemp)"
GAPS_JSON="$(mktemp)"
trap 'rm -f "$TMP" "$GAPS_JSON"' EXIT
all_gaps_json >"$GAPS_JSON"

python3 - "$GAPS_JSON" >"$TMP" <<'PY'
import sys, json, subprocess
with open(sys.argv[1]) as f:
    gaps = json.load(f)
for g in gaps:
    gid = g.get('id')
    if not gid or g.get('status') != 'open':
        continue
    r = subprocess.run(
        ['git', 'log', 'origin/main', '--grep', gid, '--oneline'],
        capture_output=True, text=True, check=False,
    )
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    if not lines:
        continue
    latest = lines[0].split()[0] if lines else ''
    print(f"{gid}|{len(lines)}|{latest}")
PY

count="$(wc -l <"$TMP" | awk '{print $1}')"
if [ "$count" -eq 0 ]; then
    log "open-but-landed done (0 found)."
    exit 0
fi

# When small (< 10), file per-gap so each shows up individually. When large,
# roll up into one finding — a 60-gap sweep is one batch ship, not 60 gaps.
if [ "$count" -lt 10 ]; then
    while IFS='|' read -r gap_id commit_count latest_sha; do
        [ -z "$gap_id" ] && continue
        key="OPEN_BUT_LANDED::${gap_id}"
        desc="Gap \`$gap_id\` is \`status: open\` in docs/gaps.yaml, but ${commit_count} commit(s) on origin/main reference its ID — most recently \`${latest_sha}\`. Either (a) the work landed and the ship step was skipped (run \`chump gap ship $gap_id --update-yaml\`), or (b) the ID was reused and one of the references is wrong. Acceptance criteria: gap is closed or the reuse is corrected."
        emit_finding "open-but-landed" "$key" "Open-but-landed: $gap_id" "$desc" "INFRA" "P2" "xs" "[\"$gap_id\",\"${latest_sha}\"]"
    done <"$TMP"
else
    samples_json="$(head -10 "$TMP" | python3 -c '
import json, sys
out=[]
for line in sys.stdin:
    parts = line.strip().split("|")
    if parts:
        out.append(parts[0])
print(json.dumps(out))
')"
    key="OPEN_BUT_LANDED_ROLLUP"
    title="Open-but-landed gaps: ${count} found"
    desc="${count} gaps are \`status: open\` in docs/gaps.yaml but already have commits on origin/main referencing their ID. Either (a) ship steps were skipped, or (b) IDs were reused. Acceptance criteria: regenerate via \`scripts/audit/auditor-checks/check-open-but-landed.sh\` and run \`chump gap ship <ID> --update-yaml\` for each landed gap, or correct ID-reuse. Close this rollup when count is < 5."
    emit_finding "open-but-landed" "$key" "$title" "$desc" "INFRA" "P1" "m" "$samples_json"
fi

log "open-but-landed done (${count} found)."
