#!/usr/bin/env bash
# test-cog032-bench-schema.sh — INFRA-324 — schema invariants for cog032_gap_bench_v1.json
#
# Validates that every task in the bench has the per-task schema fields,
# that lessons_relevant is consistent with expected_lessons_fire, that
# difficulty tiers are populated when the bench reaches lock state, and
# that no IDs collide. Run-time near-zero; safe to wire into the test job.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$REPO_ROOT/scripts/ab-harness/fixtures/cog032_gap_bench_v1.json"

if [[ ! -f "$FIXTURE" ]]; then
    echo "FAIL: fixture missing at $FIXTURE" >&2
    exit 1
fi

python3 - "$FIXTURE" <<'PY'
import json, sys
fixture = sys.argv[1]
with open(fixture) as f:
    d = json.load(f)

errors = []
def fail(msg):
    errors.append(msg)

required_top = {'_version', '_status', '_target_size', 'tasks', '_per_task_schema'}
missing = required_top - set(d.keys())
if missing:
    fail(f"top-level missing keys: {missing}")

required_per_task = {'id', 'category', 'difficulty', 'lessons_relevant',
                     'expected_lessons_fire', 'instruction', 'success_criteria',
                     'scope_estimate_minutes', 'rationale'}

ids_seen = set()
for i, t in enumerate(d.get('tasks', [])):
    label = f"task[{i}] id={t.get('id', '?')}"
    miss = required_per_task - set(t.keys())
    if miss:
        fail(f"{label} missing {miss}")
        continue
    if t['id'] in ids_seen:
        fail(f"{label} duplicate id")
    ids_seen.add(t['id'])
    if t['difficulty'] not in ('easy', 'medium', 'hard'):
        fail(f"{label} invalid difficulty {t['difficulty']!r}")
    if not isinstance(t['lessons_relevant'], bool):
        fail(f"{label} lessons_relevant must be bool")
    if t['lessons_relevant'] != bool(t['expected_lessons_fire']):
        fail(f"{label} lessons_relevant/expected_lessons_fire inconsistent")
    if t['scope_estimate_minutes'] <= 0 or t['scope_estimate_minutes'] > 90:
        fail(f"{label} scope_estimate_minutes outside (0,90]")
    sc = t.get('success_criteria', {})
    for sc_key in ('pr_must_ship', 'ci_must_pass', 'files_must_change',
                   'files_must_not_change', 'max_lines_added', 'must_not_use_no_verify'):
        if sc_key not in sc:
            fail(f"{label} success_criteria missing {sc_key}")

# Bench is locked iff len(tasks) >= _target_size AND _locked_at_sha != "TBD..."
target = d.get('_target_size', 50)
locked_at = str(d.get('_locked_at_sha', ''))
n = len(d.get('tasks', []))
is_locked = n >= target and not locked_at.startswith('TBD')
if is_locked:
    diffs = {t['difficulty'] for t in d['tasks']}
    if diffs != {'easy', 'medium', 'hard'}:
        fail(f"locked bench missing difficulty tiers: have {diffs}")
    relev = [t['lessons_relevant'] for t in d['tasks']]
    if not any(relev) or all(relev):
        fail("locked bench must mix lessons_relevant true and false")

if errors:
    print("FAIL: cog032 bench schema violations:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"PASS: cog032_gap_bench_v1.json schema OK ({n}/{target} tasks; locked={is_locked})")
PY
