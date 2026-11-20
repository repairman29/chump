#!/usr/bin/env bash
# test-research032-workflows-schema.sh — INFRA-329 — schema invariants for research032_workflows_v1.json
#
# Validates that the RESEARCH-032 workflow fixture contains exactly 5 entries
# (W1..W5 in order), each entry has every required field, IDs are unique, the
# scope_estimate_minutes is within the prereg's 90-min budget, and — most
# importantly — each workflow's success_criteria.primary matches the verbatim
# binary success criterion in docs/eval/preregistered/RESEARCH-032.md §3
# (whitespace-tolerant; paraphrase will fail). The prereg is locked, so this
# guard catches any silent drift between fixture and prereg.
#
# Run-time near-zero; safe to wire into the test job alongside
# test-cog032-bench-schema.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$REPO_ROOT/scripts/ab-harness/fixtures/research032_workflows_v1.json"
PREREG="$REPO_ROOT/docs/eval/preregistered/RESEARCH-032.md"

if [[ ! -f "$FIXTURE" ]]; then
    echo "FAIL: fixture missing at $FIXTURE" >&2
    exit 1
fi
if [[ ! -f "$PREREG" ]]; then
    echo "FAIL: prereg missing at $PREREG" >&2
    exit 1
fi

python3 - "$FIXTURE" "$PREREG" <<'PY'
import json, re, sys
fixture_path, prereg_path = sys.argv[1], sys.argv[2]
with open(fixture_path) as f:
    d = json.load(f)
with open(prereg_path) as f:
    prereg_text = f.read()

errors = []
def fail(msg):
    errors.append(msg)

# --- top-level shape ---
required_top = {'_version', '_status', '_target_size', 'workflows',
                '_per_task_schema', '_prereg', '_substrates'}
missing = required_top - set(d.keys())
if missing:
    fail(f"top-level missing keys: {missing}")

if d.get('_target_size') != 5:
    fail(f"_target_size must be 5, got {d.get('_target_size')!r}")

# --- workflows ---
required_per_workflow = {
    'id', 'name', 'starting_state', 'instruction', 'success_criteria',
    'expected_frontier_behavior', 'expected_local_failure_modes',
    'exclusion_reasons', 'scope_estimate_minutes', 'rationale',
}
required_starting_state = {'branch', 'preconditions'}
required_success_criteria = {'primary', 'all_must_hold'}
required_exclusion = {'infrastructure_failure', 'substrate_ceiling', 'agent_error'}

workflows = d.get('workflows', [])
if len(workflows) != 5:
    fail(f"expected 5 workflows, got {len(workflows)}")

expected_id_prefixes = ['W1', 'W2', 'W3', 'W4', 'W5']
ids_seen = set()
for i, w in enumerate(workflows):
    label = f"workflows[{i}] id={w.get('id', '?')}"
    miss = required_per_workflow - set(w.keys())
    if miss:
        fail(f"{label} missing fields: {sorted(miss)}")
        continue

    wid = w['id']
    if wid in ids_seen:
        fail(f"{label} duplicate id")
    ids_seen.add(wid)

    if i < len(expected_id_prefixes):
        prefix = expected_id_prefixes[i]
        if not wid.startswith(prefix + '-'):
            fail(f"{label} expected id to start with {prefix}- (workflows must be W1..W5 in order)")

    ss_miss = required_starting_state - set(w.get('starting_state', {}).keys())
    if ss_miss:
        fail(f"{label} starting_state missing: {sorted(ss_miss)}")

    sc = w.get('success_criteria', {})
    sc_miss = required_success_criteria - set(sc.keys())
    if sc_miss:
        fail(f"{label} success_criteria missing: {sorted(sc_miss)}")
    if 'all_must_hold' in sc and (not isinstance(sc['all_must_hold'], list) or not sc['all_must_hold']):
        fail(f"{label} success_criteria.all_must_hold must be a non-empty list")

    ex_miss = required_exclusion - set(w.get('exclusion_reasons', {}).keys())
    if ex_miss:
        fail(f"{label} exclusion_reasons missing: {sorted(ex_miss)}")

    sm = w.get('scope_estimate_minutes')
    if not isinstance(sm, int) or sm <= 0 or sm > 90:
        fail(f"{label} scope_estimate_minutes must be int in (0,90], got {sm!r}")

    if not w.get('instruction', '').strip():
        fail(f"{label} instruction is empty")
    if not w.get('rationale', '').strip():
        fail(f"{label} rationale is empty")

# --- verbatim-prereg check (whitespace-tolerant) ---
# The prereg §3 Workflows table has one row per workflow with the binary
# criterion as the last column. We normalize whitespace and require the
# fixture's primary text to appear as a contiguous substring of the
# whitespace-normalized prereg.
def normalize_ws(s):
    # Collapse all runs of whitespace (incl. newlines) to a single space; strip ends.
    return re.sub(r'\s+', ' ', s).strip()

prereg_norm = normalize_ws(prereg_text)
for w in workflows:
    label = f"workflow {w.get('id', '?')}"
    primary = w.get('success_criteria', {}).get('primary', '')
    if not primary:
        fail(f"{label} success_criteria.primary is empty")
        continue
    primary_norm = normalize_ws(primary)
    if primary_norm not in prereg_norm:
        # Help the author by showing the first ~80 chars that don't match.
        # Find longest matching prefix.
        lo, hi = 0, len(primary_norm)
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if primary_norm[:mid] in prereg_norm:
                lo = mid
            else:
                hi = mid - 1
        snippet_match = primary_norm[:lo]
        snippet_diverge = primary_norm[lo:lo+80]
        fail(f"{label} success_criteria.primary not found verbatim in prereg "
             f"(matched first {lo} chars: ...{snippet_match[-40:]!r}; "
             f"diverged at: {snippet_diverge!r})")

if errors:
    print("FAIL: research032 workflow fixture schema violations:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"PASS: research032_workflows_v1.json schema OK "
      f"({len(workflows)}/5 workflows; all primaries verbatim-match prereg §3)")
PY
