#!/usr/bin/env bash
# Scheduled wrapper around dogfood-matrix.sh.
#
# On failure, files a high-priority Chump task so the next autonomy round picks
# it up. Intended to be run by cron / launchd / the scheduled-tasks MCP.
#
# Usage:
#   ./scripts/eval/dogfood-matrix-scheduled.sh               # full matrix
#   MODE=quick ./scripts/eval/dogfood-matrix-scheduled.sh    # quick smoke only
#
# Env:
#   MODE                 — "all" (default) or "quick"
#   CHUMP_TASK_DB        — path to chump_memory.db (default: sessions/chump_memory.db)
#   DOGFOOD_SUPPRESS_TASK — "1" to skip filing a task on failure (dry-run)

set -o pipefail

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

MODE="${MODE:-all}"
TASK_DB="${CHUMP_TASK_DB:-$ROOT/sessions/chump_memory.db}"
SUPPRESS="${DOGFOOD_SUPPRESS_TASK:-0}"

case "$MODE" in
  all)   MATRIX_ARGS=() ;;
  quick) MATRIX_ARGS=(--quick) ;;
  *)     echo "MODE must be 'all' or 'quick'" >&2; exit 2 ;;
esac

# Run the matrix. Exit code: 0=pass, 1=fail, 2=setup.
set +e
./scripts/eval/dogfood-matrix.sh "${MATRIX_ARGS[@]}"
MATRIX_RC=$?
set -e

# Find the report we just wrote (most recent subdir of logs/dogfood-matrix/).
LATEST_DIR=$(ls -td "$ROOT"/logs/dogfood-matrix/*/ 2>/dev/null | head -1)
REPORT="${LATEST_DIR%/}/report.json"

if [[ "$MATRIX_RC" == "0" ]]; then
  echo "[dogfood-matrix-scheduled] all pass — no task filed"
  exit 0
fi

if [[ "$MATRIX_RC" == "2" ]]; then
  echo "[dogfood-matrix-scheduled] setup failure — not filing task (backend probably down)" >&2
  exit 2
fi

# ---- file a task on regression --------------------------------------------

if [[ "$SUPPRESS" == "1" ]]; then
  echo "[dogfood-matrix-scheduled] DOGFOOD_SUPPRESS_TASK=1 — skipping task creation"
  exit 1
fi

if [[ ! -f "$REPORT" ]]; then
  echo "[dogfood-matrix-scheduled] no report.json found; cannot file detailed task" >&2
  exit 1
fi

# Extract failing scenario names + reasons
FAIL_LINES=$(python3 - "$REPORT" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
fails = [x for x in r.get("results", []) if x.get("status") == "fail"]
for x in fails:
    print(f"- {x['name']} (exit={x['exit']}, {x['duration_ms']}ms): {x['reason']}")
PY
)
FAIL_NAMES=$(python3 - "$REPORT" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
names = [x["name"] for x in r.get("results", []) if x.get("status") == "fail"]
print(", ".join(names))
PY
)

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TITLE="dogfood-matrix regression: ${FAIL_NAMES}"
NOTES=$(cat <<EOF
Dogfood matrix detected a regression at ${NOW}.

Failing scenarios:
${FAIL_LINES}

Report: ${REPORT}
Per-scenario stdout/stderr: ${LATEST_DIR}
vLLM log slices: ${LATEST_DIR}*.vllm

Triage steps:
1. cat ${LATEST_DIR}summary.txt
2. For each failing scenario: cat ${LATEST_DIR}<scenario>.stdout
3. Check vLLM slice: cat ${LATEST_DIR}<scenario>.vllm
4. Common causes: model backend crash (Metal), tool timeout, context overflow,
   token budget (CHUMP_COMPLETION_MAX_TOKENS), tool middleware regression.

Re-run locally: ./scripts/eval/dogfood-matrix.sh --scenario=<name>
EOF
)

if [[ ! -f "$TASK_DB" ]]; then
  echo "[dogfood-matrix-scheduled] task DB not found at $TASK_DB; regression detected but no task filed" >&2
  exit 1
fi

# Insert via python sqlite3 (proper parameter binding; handles quotes/newlines in notes).
TASK_ID=$(python3 - "$TASK_DB" "$TITLE" "$NOTES" "$NOW" <<'PY'
import sqlite3, sys
db, title, notes, now = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
con = sqlite3.connect(db)
try:
    cur = con.execute(
        "INSERT INTO chump_tasks (title, status, priority, assignee, notes, created_at, updated_at) "
        "VALUES (?, 'open', 1, 'chump', ?, ?, ?)",
        (title, notes, now, now),
    )
    con.commit()
    print(cur.lastrowid)
finally:
    con.close()
PY
)

echo "[dogfood-matrix-scheduled] filed task #${TASK_ID}: ${TITLE}"
exit 1
