#!/usr/bin/env bash
# test-gap-opened-date-coverage.sh — INFRA-1611
#
# Guards the P0 aging census: no open P0 or P1 gap may have a missing or
# placeholder opened_date. Without this, `chump gap audit-priorities`
# silently reports every P0 as "0d old" and the CLAUDE.md Mission Driver
# "P0 budget = 5 max" aging enforcement has nothing to bite on.
#
# Scans docs/gaps/*.yaml directly (not state.db) so the gate also fires on
# hand-edited YAML that hasn't been synced yet.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GAPS_DIR="$REPO_ROOT/docs/gaps"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1611 gap opened_date coverage test ==="
echo

if [[ ! -d "$GAPS_DIR" ]]; then
    fail "docs/gaps/ directory not found"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

VIOLATIONS="$(python3 - "$GAPS_DIR" <<'PYEOF'
import glob
import os
import sys

import yaml

gaps_dir = sys.argv[1]
violations = []
placeholders = {"", "tbd", "todo", "n/a", "unknown", "0000-00-00"}

for path in sorted(glob.glob(os.path.join(gaps_dir, "*.yaml"))):
    try:
        with open(path) as f:
            docs = yaml.safe_load(f)
    except Exception as e:
        # Malformed YAML is a different gate's problem; don't fail this one.
        continue
    if not docs:
        continue
    if isinstance(docs, dict):
        docs = [docs]
    for g in docs:
        if not isinstance(g, dict):
            continue
        status = str(g.get("status", "")).strip().lower()
        priority = str(g.get("priority", "")).strip().upper()
        if status != "open" or priority not in ("P0", "P1"):
            continue
        opened = g.get("opened_date")
        opened_str = str(opened).strip().lower() if opened is not None else ""
        if opened_str in placeholders:
            violations.append(f"{g.get('id', os.path.basename(path))} ({priority}, opened_date={opened!r})")

for v in violations:
    print(v)
PYEOF
)"

if [[ -z "$VIOLATIONS" ]]; then
    ok "no open P0/P1 gap has a missing or placeholder opened_date"
else
    fail "open P0/P1 gaps missing opened_date:"
    while IFS= read -r line; do
        echo "    - $line"
    done <<< "$VIOLATIONS"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
