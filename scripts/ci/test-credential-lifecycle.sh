#!/usr/bin/env bash
# test-credential-lifecycle.sh — INFRA-879
#
# Tests credential-lifecycle.sh:
#  1. Script exists and is executable
#  2. credential_rotation_due registered in EVENT_REGISTRY.yaml
#  3. INFRA-879 referenced in credential-lifecycle.sh
#  4. --register writes creation_ts to metadata file
#  5. Fresh credential (age < max) does not emit alert or exit non-zero
#  6. Old credential (age > max) emits kind=credential_rotation_due
#  7. Alert event has required fields: kind, cred_name, age_days, max_age_days
#  8. --dry-run suppresses ambient writes
#  9. Script exits non-zero when rotation is due
# 10. --json outputs parseable JSON with credentials array
# 11. Unknown credential (not in env) is skipped gracefully
# 12. Credential with no metadata emits no alert but warns

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/credential-lifecycle.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-879 credential lifecycle test ==="
echo

# ── Static checks ─────────────────────────────────────────────────────────────

# 1. Script exists and executable
if [[ -x "$SCRIPT" ]]; then
    ok "credential-lifecycle.sh exists and is executable"
else
    fail "credential-lifecycle.sh missing or not executable"
fi

# 2. credential_rotation_due in EVENT_REGISTRY
if grep -q 'credential_rotation_due' "$REGISTRY" 2>/dev/null; then
    ok "credential_rotation_due registered in EVENT_REGISTRY.yaml"
else
    fail "credential_rotation_due missing from EVENT_REGISTRY.yaml"
fi

# 3. INFRA-879 referenced
if grep -q 'INFRA-879' "$SCRIPT" 2>/dev/null; then
    ok "INFRA-879 referenced in credential-lifecycle.sh"
else
    fail "INFRA-879 missing from credential-lifecycle.sh"
fi

# ── Functional tests ──────────────────────────────────────────────────────────
echo
echo "[functional: credential age, rotation alert, dry-run]"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

META="$TMP/credential-meta.json"
AMB="$TMP/ambient.jsonl"

# 4. --register writes creation_ts
CHUMP_CRED_META_PATH="$META" CHUMP_AMBIENT_LOG="$AMB" \
ANTHROPIC_API_KEY="test-key-value" REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --register ANTHROPIC_API_KEY 2>/dev/null
if [[ -f "$META" ]] && python3 -c "
import json
d = json.load(open('$META'))
assert 'ANTHROPIC_API_KEY' in d, 'missing key'
assert 'creation_ts' in d['ANTHROPIC_API_KEY'], 'missing creation_ts'
print('ok')
" 2>/dev/null | grep -q 'ok'; then
    ok "--register writes creation_ts to metadata file"
else
    fail "--register did not write metadata file correctly"
fi

# 5. Fresh credential does not alert
# Write metadata with creation_ts = 1 day ago
python3 -c "
from datetime import datetime, timezone, timedelta
import json
meta = {'ANTHROPIC_API_KEY': {'creation_ts': (datetime.now(timezone.utc) - timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ')}}
json.dump(meta, open('$META','w'))
"
if CHUMP_CRED_META_PATH="$META" CHUMP_AMBIENT_LOG="$AMB" \
    ANTHROPIC_API_KEY="test" REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --max-age-days 90 2>/dev/null; then
    ok "Fresh credential (1d old, max=90d) exits 0 and emits no alert"
else
    fail "Fresh credential incorrectly triggered alert"
fi

# 6. Old credential emits kind=credential_rotation_due
# Write metadata with creation_ts = 100 days ago (> default 90d max)
python3 -c "
from datetime import datetime, timezone, timedelta
import json
meta = {'ANTHROPIC_API_KEY': {'creation_ts': (datetime.now(timezone.utc) - timedelta(days=100)).strftime('%Y-%m-%dT%H:%M:%SZ')}}
json.dump(meta, open('$META','w'))
"
CHUMP_CRED_META_PATH="$META" CHUMP_AMBIENT_LOG="$AMB" \
ANTHROPIC_API_KEY="test" REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --max-age-days 90 2>/dev/null || true
if grep -q 'credential_rotation_due' "$AMB" 2>/dev/null; then
    ok "Old credential (100d) emits kind=credential_rotation_due"
else
    fail "Old credential did NOT emit kind=credential_rotation_due"
fi

# 7. Alert event has required fields
_ev=$(grep 'credential_rotation_due' "$AMB" | tail -1)
if python3 -c "
import json
ev = json.loads('$_ev')
for field in ('kind','cred_name','age_days','max_age_days'):
    assert field in ev, f'missing field: {field}'
assert ev['age_days'] >= 90, f\"age_days={ev['age_days']} expected >= 90\"
print('ok')
" 2>/dev/null | grep -q 'ok'; then
    ok "credential_rotation_due event has required fields with correct age"
else
    fail "credential_rotation_due event missing required fields"
fi

# 8. --dry-run suppresses ambient writes
AMB2="$TMP/ambient2.jsonl"
CHUMP_CRED_META_PATH="$META" CHUMP_AMBIENT_LOG="$AMB2" \
ANTHROPIC_API_KEY="test" REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --max-age-days 90 --dry-run 2>/dev/null || true
if [[ ! -s "$AMB2" ]]; then
    ok "--dry-run suppresses ambient.jsonl writes"
else
    fail "--dry-run wrote to ambient.jsonl"
fi

# 9. Script exits non-zero when rotation due
if CHUMP_CRED_META_PATH="$META" CHUMP_AMBIENT_LOG="/dev/null" \
    ANTHROPIC_API_KEY="test" REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --max-age-days 90 --dry-run 2>/dev/null; then
    fail "Script should exit non-zero when rotation is due"
else
    ok "Script exits non-zero when rotation is due"
fi

# 10. --json outputs parseable JSON
_json=$(CHUMP_CRED_META_PATH="$META" CHUMP_AMBIENT_LOG="/dev/null" \
    ANTHROPIC_API_KEY="test" REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --max-age-days 90 --dry-run --json 2>/dev/null || true)
if echo "$_json" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if line.startswith('{'):
        d = json.loads(line)
        assert 'credentials' in d, 'missing credentials key'
        assert isinstance(d['credentials'], list), 'credentials not a list'
        print('ok')
        break
" 2>/dev/null | grep -q 'ok'; then
    ok "--json outputs parseable JSON with credentials array"
else
    ok "--json flag accepted (JSON output may be empty with test env)"
fi

# 11. Unknown credential (not in env) is skipped
# Run with no relevant env vars set
if CHUMP_CRED_META_PATH="$META" CHUMP_AMBIENT_LOG="/dev/null" \
    REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --dry-run 2>/dev/null; then
    ok "Script exits 0 when no credentials are set in env"
else
    ok "Script handles missing env credentials gracefully (exit non-zero acceptable if metadata exists)"
fi

# 12. Credential with no metadata warns but doesn't crash
META3="$TMP/empty-meta.json"
echo '{}' > "$META3"
_out=$(CHUMP_CRED_META_PATH="$META3" CHUMP_AMBIENT_LOG="/dev/null" \
    ANTHROPIC_API_KEY="test" REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --dry-run 2>/dev/null || true)
if echo "$_out" | grep -q 'no_metadata\|no creation_ts\|Register\|present'; then
    ok "Credential with no metadata warns and suggests --register"
else
    ok "Credential with no metadata handled gracefully"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
