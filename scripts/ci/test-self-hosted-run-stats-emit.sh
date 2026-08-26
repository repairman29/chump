#!/usr/bin/env bash
# test-self-hosted-run-stats-emit.sh — CREDIBLE-069
#
# Smoke test for .github/actions/emit-self-hosted-run-stats/action.yml.
# Extracts the composite action's `run:` script (via python+yaml, no `act`
# dependency needed) and drives it with a synthetic env: a job_start_ts in
# the past, a CARGO_TARGET_DIR fixture older than job start (cache hit) and
# one that doesn't exist (cache miss), and no CHUMP_AMBIENT_INGEST_URL so it
# falls back to the per-runner stats-file path. Asserts the resulting JSONL
# line is well-formed and each required field has the expected value/shape.
#
# Exit 0 = action emits a well-formed self_hosted_runner_run JSONL line in
#          both the cache-hit and cache-miss cases.
# Exit 1 = missing/malformed output.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

ACTION_FILE=".github/actions/emit-self-hosted-run-stats/action.yml"
[[ -f "$ACTION_FILE" ]] || { echo "FAIL: $ACTION_FILE missing" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Extract the composite step's `run:` block via python+yaml — avoids a
# hand-maintained duplicate of the action's bash that could drift from the
# real implementation.
python3 - "$ACTION_FILE" "$WORKDIR/run.sh" <<'PYEOF'
import sys
import yaml

action_path, out_path = sys.argv[1], sys.argv[2]
with open(action_path) as f:
    doc = yaml.safe_load(f)

steps = doc["runs"]["steps"]
assert len(steps) == 1, f"expected exactly 1 step, found {len(steps)}"
run_script = steps[0]["run"]

with open(out_path, "w") as f:
    f.write("#!/usr/bin/env bash\n")
    f.write(run_script)
PYEOF

chmod +x "$WORKDIR/run.sh"

run_case() {
    local case_name="$1"
    local target_dir="$2"
    local expect_cache_hit="$3"

    local stats_root="$WORKDIR/stats-$case_name"
    mkdir -p "$stats_root"

    local job_start
    job_start=$(( $(date -u +%s) - 120 ))  # job "started" 2 minutes ago

    # No CHUMP_AMBIENT_INGEST_URL set: the action falls back to the
    # /var/cache/chump-runner/stats path, and (since that's normally
    # unwritable in a CI sandbox) further falls back to $RUNNER_TEMP — point
    # that at our sandbox dir so the test never touches real system paths.
    local out
    out=$(
        cd "$WORKDIR" && \
        JOB_START_TS="$job_start" \
        WORKFLOW_NAME="test-workflow-$case_name" \
        TARGET_DIR="$target_dir" \
        RUNNER_NAME_ENV="test-runner-01" \
        RUNNER_OS_ENV="macOS" \
        RUNNER_TEMP="$stats_root" \
        bash "$WORKDIR/run.sh" 2>&1
    )
    echo "$out"

    local line
    line=$(echo "$out" | grep -m1 '"kind":"self_hosted_runner_run"') || {
        echo "FAIL[$case_name]: no self_hosted_runner_run line emitted" >&2
        return 1
    }

    python3 - "$line" "$expect_cache_hit" "test-workflow-$case_name" <<'PYEOF'
import json
import sys

line, expect_cache_hit, expect_workflow = sys.argv[1], sys.argv[2], sys.argv[3]
obj = json.loads(line)

required = ["ts", "kind", "runner_label", "workflow", "duration_s", "cache_hit"]
missing = [f for f in required if f not in obj]
assert not missing, f"missing fields: {missing}"

assert obj["kind"] == "self_hosted_runner_run", obj["kind"]
assert obj["runner_label"] == "test-runner-01", obj["runner_label"]
assert obj["workflow"] == expect_workflow, obj["workflow"]
assert isinstance(obj["duration_s"], int), obj["duration_s"]
assert obj["duration_s"] >= 100, f"expected ~120s duration, got {obj['duration_s']}"
assert obj["cache_hit"] == (expect_cache_hit == "true"), obj["cache_hit"]
print(f"OK: {line}")
PYEOF
}

echo "== case: cache miss (no target dir) =="
run_case "miss" "$WORKDIR/does-not-exist" "false"

echo "== case: cache hit (target dir older than job start) =="
mkdir -p "$WORKDIR/old-target"
touch -d '@1' "$WORKDIR/old-target" 2>/dev/null || touch -t 197001010000 "$WORKDIR/old-target"
run_case "hit" "$WORKDIR/old-target" "true"

echo "PASS: emit-self-hosted-run-stats action emits well-formed telemetry"
