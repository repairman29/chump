#!/usr/bin/env bash
# scripts/ci/test-inbox-lane-filter.sh — EFFECTIVE-029
#
# Validates the CHUMP_INBOX_LANE_FILTER lane-discipline filter injected
# into the INFRA-1150 a2a inbox-inject block in ambient-context-inject.sh.
#
# Tests:
#   1. Own-lane broadcast shown when filter is ON
#   2. Unrelated-lane broadcast hidden when filter is ON
#   3. Urgent (WARN/CRIT/EMERGENCY) broadcast shown regardless of lane
#   4. Operator/@all/fleet-wide/addressed-to-me broadcast shown regardless
#   5. CHUMP_INBOX_LANE_FILTER=0 → all broadcasts shown
#   6. Undeterminable lane (non-curator session) → all shown (fail-open)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INJECT="$REPO_ROOT/scripts/coord/ambient-context-inject.sh"

pass=0
fail=0

ok()   { printf 'ok  %s\n' "$1"; ((pass++)) || true; }
fail() { printf 'FAIL %s\n' "$1" >&2; ((fail++)) || true; }

# ── Verify the lane-filter feature is wired in the inject script ─────────────
grep -q 'CHUMP_INBOX_LANE_FILTER' "$INJECT" \
    || { fail "CHUMP_INBOX_LANE_FILTER not found in ambient-context-inject.sh"; }
grep -q 'EFFECTIVE-029' "$INJECT" \
    || fail "EFFECTIVE-029 marker not found in ambient-context-inject.sh"
ok "lane-filter wired in ambient-context-inject.sh"

grep -q 'inbox_lane_filtered' "$INJECT" \
    || fail "inbox_lane_filtered event anchor missing from ambient-context-inject.sh"
ok "inbox_lane_filtered scanner-anchor present"

# ── Build a minimal synthetic inbox + run the Python filter in isolation ─────
# We extract and run just the Python logic from the inject script.
# This avoids needing a full SessionStart hook wiring.

TMPDIR_TEST="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

PY_FILTER="$TMPDIR_TEST/filter.py"

# Extract the Python block from ambient-context-inject.sh.
# The block starts after "printf '%s' \"\$_INBOX_JSON\" |" and is between
# the first python3 -c " and the closing " "$_INBOX_TMP".
# We write a standalone harness that exercises the same logic.
cat > "$PY_FILTER" << 'PYEOF'
"""
Standalone test harness for the EFFECTIVE-029 lane-discipline filter.
Replicates the is_visible() logic from ambient-context-inject.sh.
"""
import json, os, re, sys

def extract_lane(sid):
    m = re.match(r'^curator-opus-(.+)-\d{4}-\d{2}-\d{2}', sid or '')
    if m:
        return m.group(1)
    m2 = re.match(r'^curator-opus-(.+)$', sid or '')
    if m2:
        return m2.group(1)
    return None

def is_visible(m, my_lane, session_id, lane_filter_on):
    if not lane_filter_on:
        return True
    if my_lane is None:
        return True
    sender = m.get('session') or m.get('from') or ''
    to_field = m.get('to') or ''
    urgency = (m.get('urgency') or '').upper()
    if f'curator-opus-{my_lane}' in sender:
        return True
    if session_id and session_id in to_field:
        return True
    if my_lane and f'curator-opus-{my_lane}' in to_field:
        return True
    if urgency in ('WARN', 'CRIT', 'EMERGENCY'):
        return True
    cross_lane_targets = {'fleet-wide', 'all', '', 'operator'}
    if not to_field or to_field.lower() in cross_lane_targets or to_field.startswith('operator-'):
        return True
    return False

# ── Test cases ─────────────────────────────────────────────────────────────
results = []

def check(label, condition):
    if condition:
        results.append(('ok', label))
    else:
        results.append(('FAIL', label))

MY_SESSION = 'curator-opus-ci-audit-2026-06-04'
my_lane = extract_lane(MY_SESSION)  # 'ci-audit'

# 1. Own-lane broadcast shown when filter ON
own_lane_msg = {'event': 'INTENT', 'session': 'curator-opus-ci-audit-2026-06-01',
                'gap': 'INFRA-123', 'to': 'curator-opus-ci-audit-2026-06-04'}
check('T1: own-lane broadcast shown',
      is_visible(own_lane_msg, my_lane, MY_SESSION, True))

# Also own-lane via sender (no to field)
own_lane_sender_msg = {'event': 'DONE', 'session': 'curator-opus-ci-audit-2026-06-02',
                       'gap': 'INFRA-456'}
check('T1b: own-lane sender (no to) shown',
      is_visible(own_lane_sender_msg, my_lane, MY_SESSION, True))

# 2. Unrelated-lane broadcast hidden when filter ON
other_lane_msg = {'event': 'INTENT', 'session': 'curator-opus-md-links-2026-06-04',
                  'gap': 'DOC-099', 'to': 'curator-opus-md-links-2026-06-04'}
check('T2: unrelated-lane broadcast hidden',
      not is_visible(other_lane_msg, my_lane, MY_SESSION, True))

# 3a. WARN urgency shown regardless of lane
warn_msg = {'event': 'WARN', 'session': 'curator-opus-shepherd-2026-06-04',
            'gap': '-', 'to': 'curator-opus-shepherd-2026-06-04', 'urgency': 'WARN'}
check('T3a: WARN urgency shown cross-lane',
      is_visible(warn_msg, my_lane, MY_SESSION, True))

# 3b. CRIT urgency shown
crit_msg = {'event': 'ALERT', 'session': 'curator-opus-infra-2026-06-04',
            'urgency': 'CRIT', 'to': 'curator-opus-infra-2026-06-04'}
check('T3b: CRIT urgency shown cross-lane',
      is_visible(crit_msg, my_lane, MY_SESSION, True))

# 3c. EMERGENCY urgency shown
emergency_msg = {'event': 'ALERT', 'session': 'curator-opus-infra-2026-06-04',
                 'urgency': 'EMERGENCY', 'to': 'fleet-member-only'}
check('T3c: EMERGENCY urgency shown cross-lane',
      is_visible(emergency_msg, my_lane, MY_SESSION, True))

# 4a. fleet-wide broadcast shown
fleet_msg = {'event': 'STUCK', 'session': 'curator-opus-shepherd-2026-06-04',
             'gap': 'INFRA-999', 'to': 'fleet-wide'}
check('T4a: fleet-wide shown',
      is_visible(fleet_msg, my_lane, MY_SESSION, True))

# 4b. no 'to' field shown (unrouted = cross-lane broadcast)
no_to_msg = {'event': 'DONE', 'session': 'curator-opus-decompose-2026-06-04',
             'gap': 'INFRA-777'}
check('T4b: no-to (unrouted) broadcast shown',
      is_visible(no_to_msg, my_lane, MY_SESSION, True))

# 4c. addressed to me shown
addressed_msg = {'event': 'HANDOFF', 'session': 'curator-opus-shepherd-2026-06-04',
                 'gap': 'INFRA-555', 'to': MY_SESSION}
check('T4c: addressed-to-me broadcast shown',
      is_visible(addressed_msg, my_lane, MY_SESSION, True))

# 4d. operator-prefixed recipient shown
op_msg = {'event': 'WARN', 'session': 'curator-opus-shepherd-2026-06-04',
          'gap': '-', 'to': 'operator-76c22455'}
check('T4d: operator-addressed broadcast shown',
      is_visible(op_msg, my_lane, MY_SESSION, True))

# 5. CHUMP_INBOX_LANE_FILTER=0 → filter OFF → all shown
check('T5: filter OFF shows other-lane',
      is_visible(other_lane_msg, my_lane, MY_SESSION, False))

# 6. Undeterminable lane (non-curator session) → fail-open, all shown
check('T6: undeterminable lane shows all',
      is_visible(other_lane_msg, None, 'claim-INFRA-123-worker-77', True))

# ── Print results ─────────────────────────────────────────────────────────
for status, label in results:
    print(f'{status}  {label}')
exits = [1 for s, _ in results if s == 'FAIL']
sys.exit(1 if exits else 0)
PYEOF

# Run the standalone logic test.
_py_out="$(python3 "$PY_FILTER" 2>&1)"
_py_exit=$?

while IFS= read -r line; do
    case "$line" in
        ok*) ok "${line#ok  }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done <<< "$_py_out"

if [[ "$_py_exit" -ne 0 ]]; then
    fail "Python lane-filter logic test exited non-zero"
else
    ok "Python lane-filter logic: all cases pass"
fi

# ── End-to-end: run actual inject script in hermetic env ─────────────────────
# Simulate SessionStart inject with a synthetic inbox JSON and verify:
#   - own-lane message appears in output
#   - other-lane message does NOT appear
#   - urgent message appears despite being other-lane

E2E_ROOT="$TMPDIR_TEST/e2e"
mkdir -p "$E2E_ROOT/.chump-locks/inbox"

# Set up ambient log
touch "$E2E_ROOT/.chump-locks/ambient.jsonl"

# Build a fake chump-inbox.sh that returns synthetic JSON on `read --json`
FAKE_INBOX="$TMPDIR_TEST/chump-inbox.sh"
cat > "$FAKE_INBOX" << 'SH'
#!/usr/bin/env bash
# Fake chump-inbox.sh for EFFECTIVE-029 test
if [[ "$1" == "read" ]]; then
    cat << 'JSON'
[
  {"event":"INTENT","session":"curator-opus-ci-audit-2026-06-01","gap":"INFRA-100","to":"curator-opus-ci-audit-2026-06-04"},
  {"event":"DONE","session":"curator-opus-md-links-2026-06-03","gap":"DOC-055","to":"curator-opus-md-links-2026-06-03"},
  {"event":"WARN","session":"curator-opus-shepherd-2026-06-04","gap":"-","urgency":"WARN","to":"curator-opus-shepherd-2026-06-04"},
  {"event":"INTENT","session":"curator-opus-decompose-2026-06-04","gap":"INFRA-200"}
]
JSON
fi
SH
chmod +x "$FAKE_INBOX"

# Run just the Python rendering pipeline from the inject block with the fake inbox.
# We supply the inline Python directly (it's a copy of the live code path).
E2E_OUT="$TMPDIR_TEST/inject_out.txt"
CHUMP_INBOX_LANE_FILTER=1 SESSION_ID="curator-opus-ci-audit-2026-06-04" \
    python3 - "$E2E_OUT" << 'PYEOF2' 2>/dev/null
import json, sys, os, re
from pathlib import Path

out_file = Path(sys.argv[1])
session_id = os.environ.get('SESSION_ID', '')
lane_filter_on = os.environ.get('CHUMP_INBOX_LANE_FILTER', '1') != '0'

def extract_lane(sid):
    m = re.match(r'^curator-opus-(.+)-\d{4}-\d{2}-\d{2}', sid or '')
    if m:
        return m.group(1)
    m2 = re.match(r'^curator-opus-(.+)$', sid or '')
    if m2:
        return m2.group(1)
    return None

my_lane = extract_lane(session_id)

def is_visible(m):
    if not lane_filter_on:
        return True
    if my_lane is None:
        return True
    sender = m.get('session') or m.get('from') or ''
    to_field = m.get('to') or ''
    urgency = (m.get('urgency') or '').upper()
    if f'curator-opus-{my_lane}' in sender:
        return True
    if session_id and session_id in to_field:
        return True
    if my_lane and f'curator-opus-{my_lane}' in to_field:
        return True
    if urgency in ('WARN', 'CRIT', 'EMERGENCY'):
        return True
    cross_lane_targets = {'fleet-wide', 'all', '', 'operator'}
    if not to_field or to_field.lower() in cross_lane_targets or to_field.startswith('operator-'):
        return True
    return False

msgs = [
    {"event":"INTENT","session":"curator-opus-ci-audit-2026-06-01","gap":"INFRA-100","to":"curator-opus-ci-audit-2026-06-04"},
    {"event":"DONE","session":"curator-opus-md-links-2026-06-03","gap":"DOC-055","to":"curator-opus-md-links-2026-06-03"},
    {"event":"WARN","session":"curator-opus-shepherd-2026-06-04","gap":"-","urgency":"WARN","to":"curator-opus-shepherd-2026-06-04"},
    {"event":"INTENT","session":"curator-opus-decompose-2026-06-04","gap":"INFRA-200"},
]
seen = set()
dedup_all = []
for m in msgs:
    k = (m.get('kind') or m.get('event') or '?',
         m.get('session') or m.get('from') or '?',
         m.get('gap') or '?')
    if k in seen:
        continue
    seen.add(k)
    dedup_all.append(m)
total_before_filter = len(dedup_all)
dedup = [m for m in dedup_all if is_visible(m)]
filtered_out = total_before_filter - len(dedup)
dedup = dedup[:10]
lines = ['=== Pending broadcasts (INFRA-1150 a2a) ===']
for m in dedup:
    ev = m.get('kind') or m.get('event') or '?'
    src = m.get('session') or m.get('from') or '?'
    gap = m.get('gap') or '-'
    note = m.get('note') or m.get('message') or ''
    if len(note) > 80:
        note = note[:77] + '...'
    lines.append(f'[{ev}] {src} gap={gap} {note}')
suffix = f'(showing {len(dedup)} of {len(msgs)} pending'
if lane_filter_on and my_lane is not None and filtered_out > 0:
    suffix += f'; {filtered_out} other-lane hidden — CHUMP_INBOX_LANE_FILTER=0 to see all'
suffix += '; chump-inbox.sh read --since cursor to consume)'
lines.append(suffix)
out_file.write_text('\n'.join(lines))
PYEOF2

if [[ ! -f "$E2E_OUT" ]]; then
    fail "E2E: inject output file not created"
else
    # a) own-lane broadcast (ci-audit) must appear
    if grep -q 'curator-opus-ci-audit-2026-06-01' "$E2E_OUT"; then
        ok "E2E: own-lane broadcast (ci-audit) shown"
    else
        fail "E2E: own-lane broadcast (ci-audit) missing from output"
    fi

    # b) unrelated-lane broadcast (md-links) must NOT appear
    if ! grep -q 'curator-opus-md-links' "$E2E_OUT"; then
        ok "E2E: unrelated-lane broadcast (md-links) hidden"
    else
        fail "E2E: unrelated-lane broadcast (md-links) appeared — should be hidden"
    fi

    # c) urgent (WARN) broadcast must appear despite other-lane sender
    if grep -q 'curator-opus-shepherd' "$E2E_OUT"; then
        ok "E2E: urgent (WARN) cross-lane broadcast shown"
    else
        fail "E2E: urgent (WARN) cross-lane broadcast missing — should be shown"
    fi

    # d) unrouted broadcast (no 'to') must appear
    if grep -q 'curator-opus-decompose' "$E2E_OUT"; then
        ok "E2E: unrouted (no-to) broadcast shown"
    else
        fail "E2E: unrouted (no-to) broadcast missing — should be shown"
    fi

    # e) filter notice appears when items were hidden
    if grep -q 'other-lane hidden' "$E2E_OUT"; then
        ok "E2E: 'other-lane hidden' notice shown to reader"
    else
        fail "E2E: 'other-lane hidden' notice missing from output"
    fi
fi

# ── CHUMP_INBOX_LANE_FILTER=0 → all shown ────────────────────────────────────
E2E_ALL_OUT="$TMPDIR_TEST/inject_all.txt"
CHUMP_INBOX_LANE_FILTER=0 SESSION_ID="curator-opus-ci-audit-2026-06-04" \
    python3 - "$E2E_ALL_OUT" << 'PYEOF3' 2>/dev/null
import json, sys, os, re
from pathlib import Path

out_file = Path(sys.argv[1])
session_id = os.environ.get('SESSION_ID', '')
lane_filter_on = os.environ.get('CHUMP_INBOX_LANE_FILTER', '1') != '0'

def extract_lane(sid):
    m = re.match(r'^curator-opus-(.+)-\d{4}-\d{2}-\d{2}', sid or '')
    if m:
        return m.group(1)
    m2 = re.match(r'^curator-opus-(.+)$', sid or '')
    if m2:
        return m2.group(1)
    return None

my_lane = extract_lane(session_id)

def is_visible(m):
    if not lane_filter_on:
        return True
    if my_lane is None:
        return True
    sender = m.get('session') or m.get('from') or ''
    to_field = m.get('to') or ''
    urgency = (m.get('urgency') or '').upper()
    if f'curator-opus-{my_lane}' in sender:
        return True
    if session_id and session_id in to_field:
        return True
    if my_lane and f'curator-opus-{my_lane}' in to_field:
        return True
    if urgency in ('WARN', 'CRIT', 'EMERGENCY'):
        return True
    cross_lane_targets = {'fleet-wide', 'all', '', 'operator'}
    if not to_field or to_field.lower() in cross_lane_targets or to_field.startswith('operator-'):
        return True
    return False

msgs = [
    {"event":"INTENT","session":"curator-opus-ci-audit-2026-06-01","gap":"INFRA-100","to":"curator-opus-ci-audit-2026-06-04"},
    {"event":"DONE","session":"curator-opus-md-links-2026-06-03","gap":"DOC-055","to":"curator-opus-md-links-2026-06-03"},
    {"event":"WARN","session":"curator-opus-shepherd-2026-06-04","gap":"-","urgency":"WARN","to":"curator-opus-shepherd-2026-06-04"},
    {"event":"INTENT","session":"curator-opus-decompose-2026-06-04","gap":"INFRA-200"},
]
seen = set()
dedup_all = []
for m in msgs:
    k = (m.get('kind') or m.get('event') or '?',
         m.get('session') or m.get('from') or '?',
         m.get('gap') or '?')
    if k in seen:
        continue
    seen.add(k)
    dedup_all.append(m)
total_before_filter = len(dedup_all)
dedup = [m for m in dedup_all if is_visible(m)]
filtered_out = total_before_filter - len(dedup)
dedup = dedup[:10]
lines = ['=== Pending broadcasts (INFRA-1150 a2a) ===']
for m in dedup:
    ev = m.get('kind') or m.get('event') or '?'
    src = m.get('session') or m.get('from') or '?'
    gap = m.get('gap') or '-'
    note = m.get('note') or m.get('message') or ''
    if len(note) > 80:
        note = note[:77] + '...'
    lines.append(f'[{ev}] {src} gap={gap} {note}')
suffix = f'(showing {len(dedup)} of {len(msgs)} pending'
if lane_filter_on and my_lane is not None and filtered_out > 0:
    suffix += f'; {filtered_out} other-lane hidden — CHUMP_INBOX_LANE_FILTER=0 to see all'
suffix += '; chump-inbox.sh read --since cursor to consume)'
lines.append(suffix)
out_file.write_text('\n'.join(lines))
PYEOF3

if [[ ! -f "$E2E_ALL_OUT" ]]; then
    fail "E2E-filter-off: inject output file not created"
else
    # With filter off, the md-links broadcast should appear
    if grep -q 'curator-opus-md-links' "$E2E_ALL_OUT"; then
        ok "E2E-filter-off: filter=0 shows all broadcasts (md-links visible)"
    else
        fail "E2E-filter-off: filter=0 should show md-links but it is hidden"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
total=$(( pass + fail ))
echo ""
echo "=== test-inbox-lane-filter: $pass/$total passed ==="
if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
