#!/usr/bin/env bash
# test-gap-gardener-no-ac-placeholder.sh — CREDIBLE-393 (CREDIBLE-284 slice)
#
# Locks in the invariant that scripts/coord/gap-gardener.py's seed_gaps()
# never mints a tautological "TODO: add acceptance criteria" placeholder
# for gaps it auto-files. An unauthored gap must have an empty/absent
# acceptance_criteria field (so the audit subsystem correctly flags it as
# "missing AC") rather than a fake-pass placeholder that reads as covered.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

OUT="$(python3 -c "
import sys
sys.path.insert(0, 'scripts/coord')
import importlib.util
spec = importlib.util.spec_from_file_location('gap_gardener', 'scripts/coord/gap-gardener.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Any gap dict seed_gaps() can produce (RED_LETTER / failing-CI / TODO
# sources) must never carry an 'acceptance_criteria' key — that field is
# left for the author (or claim-time decompose) to fill in, not stamped
# with a placeholder at seed time.
sample_gaps = [
    {
        'id': 'INFRA-9001', 'title': 'Red Letter #1: sample issue', 'domain': 'infra',
        'priority': 'P2', 'effort': 'm', 'status': 'open',
        'source_doc': 'docs/RED_LETTER.md Issue #1 (2026-09-02)',
        'description': 'sample description',
    },
    {
        'id': 'INFRA-9002', 'title': 'Fix repeatedly failing CI workflow: sample', 'domain': 'infra',
        'priority': 'P1', 'effort': 's', 'status': 'open',
        'source_doc': 'gh run list --state failure (2026-09-02)',
        'description': 'sample description',
    },
    {
        'id': 'QUALITY-9003', 'title': 'Address code TODO: sample', 'domain': 'reliability',
        'priority': 'P3', 'effort': 's', 'status': 'open',
        'source_doc': 'src/foo.rs:1 (2026-09-02)',
        'description': 'sample description',
    },
]

fails = []
for g in sample_gaps:
    if 'acceptance_criteria' in g:
        fails.append(f\"{g['id']}: gap dict carries an acceptance_criteria key ({g['acceptance_criteria']!r})\")

rendered = ''.join(mod._format_gap_yaml(g) for g in sample_gaps)
if 'acceptance_criteria' in rendered:
    fails.append('rendered YAML contains an acceptance_criteria field')
if 'TODO: add acceptance criteria' in rendered or 'TODO' in rendered.upper() and 'acceptance' in rendered.lower():
    fails.append('rendered YAML contains a TODO-style acceptance-criteria placeholder')

if fails:
    print('FAIL')
    for f in fails:
        print(f'  - {f}')
else:
    print('PASS')
")"

echo "$OUT"
if ! echo "$OUT" | head -1 | grep -q '^PASS$'; then
  echo "FAIL: gap-gardener.py seed output carries a placeholder/auto-filled acceptance_criteria — see CREDIBLE-393"
  exit 1
fi

echo "PASS: gap-gardener.py never auto-fills a tautological acceptance_criteria placeholder for unauthored gaps"
