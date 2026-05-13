#!/usr/bin/env bash
# refresh-roadmap-status.sh — DOC-037
#
# Reads docs/gaps/*.yaml and rewrites the "Pillar balance" line in
# docs/ROADMAP.md in place.
#
# Definitions (matching META-046 + the operator's hygiene rules):
#   - pickable: status:open AND acceptance_criteria present AND non-TODO
#   - vague:    status:open AND (acceptance_criteria missing OR all entries
#                                start with "TODO: ")
#   - per-pillar share: EFFECTIVE / CREDIBLE / RESILIENT / ZERO-WASTE / MISSION
#                       computed against the pickable pool
#
# Usage:
#   scripts/coord/refresh-roadmap-status.sh           # rewrite in place
#   scripts/coord/refresh-roadmap-status.sh --dry-run # print only
#
# Mission Driver invokes on every gap close/open. Atomic temp + rename
# so a concurrent reader never sees a partial file.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"
ROADMAP="$REPO_ROOT/docs/ROADMAP.md"
GAPS_DIR="$REPO_ROOT/docs/gaps"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ ! -f "$ROADMAP" ]]; then
    echo "[refresh-roadmap-status] $ROADMAP not found" >&2
    exit 1
fi
if [[ ! -d "$GAPS_DIR" ]]; then
    echo "[refresh-roadmap-status] $GAPS_DIR not found" >&2
    exit 1
fi

# Compute counts via python — single pass, robust YAML parse.
counts_line="$(python3 - <<'PYEOF'
import os
import re
from pathlib import Path

gaps_dir = Path('docs/gaps')

# Pillar tag → label
TAGS = {
    'EFFECTIVE': 'EFFECTIVE',
    'CREDIBLE':  'CREDIBLE',
    'RESILIENT': 'RESILIENT',
    'ZERO-WASTE': 'ZERO-WASTE',
    'MISSION':   'MISSION',
}

def parse_gap(path):
    """Return (status, has_real_ac, title) — cheap line-by-line, no full YAML."""
    status = None
    in_ac = False
    ac_lines = []
    title = ''
    try:
        with open(path) as f:
            for line in f:
                if line.startswith('  status:'):
                    status = line.split(':', 1)[1].strip()
                elif line.startswith('  title:'):
                    title = line.split(':', 1)[1].strip().strip('"').strip("'")
                elif line.startswith('  acceptance_criteria:'):
                    in_ac = True
                    # Inline list form like 'acceptance_criteria: [...]'
                    inline = line.split(':', 1)[1].strip()
                    if inline:
                        ac_lines.append(inline)
                elif in_ac and line.startswith('    -'):
                    ac_lines.append(line.strip().lstrip('-').strip())
                elif in_ac and not line.startswith(' '):
                    in_ac = False
    except Exception:
        pass
    real_ac = any(
        ac and not ac.startswith('"TODO:') and not ac.startswith('TODO:')
        for ac in ac_lines
    )
    return status, real_ac, title

def pillar_of(title):
    for tag, label in TAGS.items():
        if title.startswith(f'{tag}:') or f' {tag}:' in title or f'{tag} —' in title or tag in title.split(':')[0]:
            return label
    return None

pickable_by_pillar = {p: 0 for p in TAGS.values()}
pickable_total = 0
vague_total = 0

for yaml_file in sorted(gaps_dir.glob('*.yaml')):
    status, real_ac, title = parse_gap(yaml_file)
    if status != 'open':
        continue
    if real_ac:
        pickable_total += 1
        p = pillar_of(title)
        if p:
            pickable_by_pillar[p] += 1
    else:
        vague_total += 1

def pct(n, d):
    return f"{round(100 * n / d)}%" if d else "0%"

parts = []
for label, count in sorted(pickable_by_pillar.items(), key=lambda kv: -kv[1]):
    parts.append(f"{label} {pct(count, pickable_total)}")

import datetime as dt
today = dt.date.today().isoformat()
print(
    f"- **Pillar balance ({today}):** "
    + ", ".join(parts)
    + f". **~{pickable_total} pickable, ~{vague_total} vague**."
)
PYEOF
)"

if [[ -z "$counts_line" ]]; then
    echo "[refresh-roadmap-status] no counts computed; aborting" >&2
    exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Would rewrite Pillar balance line to:"
    echo "$counts_line"
    exit 0
fi

# Rewrite in-place atomically: temp + rename.
tmp="$(mktemp "${ROADMAP}.XXXXXX")"
awk -v new="$counts_line" '
    /^- \*\*Pillar balance/ { print new; next }
    { print }
' "$ROADMAP" > "$tmp"
mv "$tmp" "$ROADMAP"

echo "[refresh-roadmap-status] rewrote Pillar balance line: $counts_line"
