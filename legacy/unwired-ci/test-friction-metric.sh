#!/usr/bin/env bash
# Smoke test for friction-metric.sh (MISSION-044 AC5).
# Asserts:
#   (a) executable
#   (b) default (no gh/network) mode never crashes — bash -n syntax check
#   (c) --help exits 0
#   (d) unknown flag exits non-zero with error message
#   (e) --window rejects a non-numeric value
#   (f) --json --no-history emits a single-line JSON object with the
#       expected keys, without touching the history file

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/friction-metric.sh"

[[ -x "$SCRIPT" ]] || { echo "[test] FAIL: friction-metric.sh not executable"; exit 1; }
echo "[test] (a) executable: OK"

bash -n "$SCRIPT" || { echo "[test] FAIL: syntax error"; exit 1; }
echo "[test] (b) bash -n syntax check: OK"

"$SCRIPT" --help >/dev/null 2>&1 || { echo "[test] FAIL: --help non-zero"; exit 1; }
echo "[test] (c) --help exits 0: OK"

"$SCRIPT" --not-a-real-flag >/dev/null 2>&1 && { echo "[test] FAIL: unknown flag should exit non-zero"; exit 1; }
echo "[test] (d) unknown flag exits non-zero: OK"

"$SCRIPT" --window abc >/dev/null 2>&1 && { echo "[test] FAIL: non-numeric --window should exit non-zero"; exit 1; }
echo "[test] (e) non-numeric --window exits non-zero: OK"

history_file="$REPO_ROOT/.chump/metrics/friction-metric-history.jsonl"
before_hash=""
[[ -f "$history_file" ]] && before_hash=$(md5sum "$history_file" 2>/dev/null || md5 -q "$history_file" 2>/dev/null)

out=$(FRICTION_METRIC_SAMPLE_CAP=2 "$SCRIPT" --window 1d --json --no-history 2>&1)
echo "$out" | python3 -c "
import json, sys
line = sys.stdin.read().strip()
obj = json.loads(line)
for k in ('ts', 'window', 'repo', 'ships', 'attempts_per_ship', 'turns_to_first_ship_hours'):
    assert k in obj, f'missing key {k}'
" || { echo "[test] FAIL: --json output not valid / missing keys: $out"; exit 1; }
echo "[test] (f) --json --no-history emits well-formed single-line JSON: OK"

after_hash=""
[[ -f "$history_file" ]] && after_hash=$(md5sum "$history_file" 2>/dev/null || md5 -q "$history_file" 2>/dev/null)
[[ "$before_hash" == "$after_hash" ]] || { echo "[test] FAIL: --no-history still wrote history file"; exit 1; }
echo "[test] (f2) --no-history does not touch history file: OK"

echo "[test-friction-metric] PASS"
