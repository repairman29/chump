#!/usr/bin/env bash
# CI-safe preflight for RESEARCH-026 harness + fixtures (no API calls).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3.12 scripts/ab-harness/sync-reflection-paired-formal.py

python3.12 - <<'PY'
import json
from pathlib import Path
base = Path("scripts/ab-harness/fixtures")
casual = json.loads((base / "reflection_tasks_casual_v1.json").read_text())["tasks"]
formal = json.loads((base / "reflection_tasks_formal_paired_v1.json").read_text())["tasks"]
assert [t["id"] for t in casual] == [t["id"] for t in formal], "ID/order mismatch"
assert len(casual) == 50
print("[research-026-preflight] paired fixtures OK (50 tasks, matching order)")
PY

python3.12 - "$ROOT/scripts/ab-harness/fixtures/reflection_tasks_formal_paired_v1.json" \
  "$ROOT/scripts/ab-harness/fixtures/reflection_tasks_casual_v1.json" <<'PYEOF'
import json, sys
formal = json.loads(open(sys.argv[1]).read())
casual = json.loads(open(sys.argv[2]).read())
formal_ids = {t['id'] for t in formal.get('tasks', [])}
casual_ids = {t['id'] for t in casual.get('tasks', [])}
missing_in_casual = casual_ids - formal_ids
if missing_in_casual:
    raise SystemExit(f"subset fail: {missing_in_casual}")
print("[research-026-preflight] observer subset check OK")
PYEOF

# Argparse smoke (no cloud).
python3.12 scripts/ab-harness/run-cloud-v2.py --help >/dev/null
python3.12 scripts/ab-harness/analyze-observer-effect.py --help >/dev/null

echo "[research-026-preflight] OK"
