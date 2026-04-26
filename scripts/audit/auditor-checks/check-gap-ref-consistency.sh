#!/usr/bin/env bash
# check-gap-ref-consistency.sh — find code/doc references to gap IDs that don't
# exist in docs/gaps.yaml. Emits ONE finding per dead gap-id (not per ref site)
# so a single missing ID referenced from 8 files is one item to act on, not 8.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$REPO_ROOT"
log "scanning for gap references..."

KNOWN_IDS=" $(all_gap_ids) "
PATTERN='\b(INFRA|EVAL|COG|MEM|DOC|FLEET|PRODUCT|RESEARCH|FRONTIER|AUTO)-[0-9]{3}\b'

RAW="$(mktemp)"
GROUPED="$(mktemp)"
trap 'rm -f "$RAW" "$GROUPED"' EXIT

grep -REn --binary-files=without-match \
    --include='*.rs' --include='*.md' --include='*.sh' --include='*.py' --include='*.toml' --include='*.yml' --include='*.yaml' \
    --exclude-dir=target --exclude-dir=node_modules --exclude-dir=.git \
    --exclude=gaps.yaml --exclude=state.sql \
    -E "$PATTERN" . 2>/dev/null >"$RAW" || true

KNOWN_IDS="$KNOWN_IDS" python3 - "$RAW" >"$GROUPED" <<'PY'
import os, re, sys, json
from collections import defaultdict
known = set(os.environ['KNOWN_IDS'].split())
pat = re.compile(r'\b(INFRA|EVAL|COG|MEM|DOC|FLEET|PRODUCT|RESEARCH|FRONTIER|AUTO)-[0-9]{3}\b')
dead = defaultdict(list)
with open(sys.argv[1]) as f:
    for line in f:
        line = line.rstrip('\n')
        parts = line.split(':', 2)
        if len(parts) < 3:
            continue
        path, lineno, text = parts
        for m in pat.finditer(text):
            gid = m.group(0)
            if gid in known:
                continue
            # Skip sentinel placeholders used in test fixtures
            if gid.endswith(('-999', '-000')):
                continue
            dead[gid].append(f"{path}:{lineno}")
for gid, sites in sorted(dead.items()):
    print(json.dumps({"gap_id": gid, "count": len(sites), "samples": sites[:5]}))
PY

while IFS= read -r row; do
    [ -z "$row" ] && continue
    gap_id="$(echo "$row" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["gap_id"])')"
    count="$(echo "$row"  | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["count"])')"
    samples_json="$(echo "$row" | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())["samples"]))')"
    samples_pretty="$(echo "$samples_json" | python3 -c 'import json,sys; print(", ".join(json.loads(sys.stdin.read())))')"

    key="DEAD_GAP_REF::${gap_id}"
    title="Dead gap reference $gap_id ($count site(s))"
    desc="Code/doc references gap ID \`$gap_id\` but that ID does not exist in docs/gaps.yaml. Either the reference is stale (gap was renumbered or never filed) or the registry is missing an entry. Found at $count site(s); first few: $samples_pretty. Acceptance criteria: either remove all dead references or file/restore the gap."
    emit_finding "gap-ref-consistency" "$key" "$title" "$desc" "INFRA" "P2" "xs" "$samples_json"
done <"$GROUPED"

log "gap-ref-consistency done."
