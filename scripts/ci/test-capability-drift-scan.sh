#!/usr/bin/env bash
# test-capability-drift-scan.sh — CREDIBLE-173
#
# Smoke test for scripts/dev/capability-drift-scan.py: proves the scanner
# actually flags real drift rather than always reporting clean. The registry
# deliberately omits chump-integrator/chump-policy/chump-reviewer-routing
# (see docs/observability/CAPABILITY_BUCKETS.yaml header) precisely so this
# test has known-true-positive fixtures without needing synthetic ones.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

OUT="$(python3 scripts/dev/capability-drift-scan.py --no-emit --json)"

echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin)" \
  || { echo "FAIL: scanner did not emit valid JSON"; exit 1; }

FLAGGED=$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['flagged']))")

if [ "$FLAGGED" -eq 0 ]; then
  echo "FAIL: expected at least one flagged cluster (deliberately-unregistered crates in CAPABILITY_BUCKETS.yaml), got 0 — scanner is not detecting real drift"
  exit 1
fi

echo "PASS: capability-drift-scan.py flagged $FLAGGED unattributed cluster(s), confirming it detects real drift (not a no-op)"

# Confirm the no-op path also works when everything's covered — a registry
# matching literally every file should flag nothing.
EMPTY_RESULT=$(python3 -c "
import sys
sys.path.insert(0, 'scripts/dev')
import importlib.util
spec = importlib.util.spec_from_file_location('scan', 'scripts/dev/capability-drift-scan.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
# a bucket matching everything should produce zero flags
buckets = [{'name': 'everything', 'globs': ['*', '**/*.rs']}]
files = mod.real_rust_files()
flagged = [f for f in files if mod.matches_any_bucket(f, buckets) is None]
print(len(flagged))
")

if [ "$EMPTY_RESULT" -ne 0 ]; then
  echo "FAIL: a catch-all bucket should match every file (0 unflagged), got $EMPTY_RESULT unflagged — glob matching logic is broken"
  exit 1
fi

echo "PASS: catch-all bucket correctly matches all files — glob matcher is sound"
