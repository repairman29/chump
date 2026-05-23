#!/usr/bin/env bash
# test-chump-dashboard-tui.sh — INFRA-1894 smoke.
#
# Network-free. Stubs `chump` + `gh` on PATH, points ambient/lock dirs at TMP.
# Asserts the dashboard renders all 5 sections.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/chump-dashboard-tui.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/locks/inbox"
export PATH="$TMP/bin:$PATH"
export CHUMP_LOCK_DIR="$TMP/locks"
export CHUMP_AMBIENT_LOG="$TMP/locks/ambient.jsonl"
export CHUMP_SESSION_ID="test-dashboard-session"
touch "$CHUMP_AMBIENT_LOG"

# Stub chump: serves --leases + audit-priorities --json + gap (other) as no-ops.
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--leases" ]]; then
  cat <<'L'
2 active agent lease(s) (this session: test-dashboard-session):
  claim-stub-1 expires 2026-05-24T00:00:00Z (1 paths)
    - scripts/foo
  claim-stub-2 expires 2026-05-24T00:00:00Z (1 paths)
    - scripts/bar
L
  exit 0
fi
if [[ "${1:-}" == "gap" && "${2:-}" == "audit-priorities" ]]; then
  echo '{"pickable_by_pillar":{"EFFECTIVE":3,"CREDIBLE":2,"RESILIENT":4,"ZERO-WASTE":1}}'
  exit 0
fi
echo "(stub)"
EOF
chmod +x "$TMP/bin/chump"

# Stub gh for lightning-timeline's gh pr list call.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "[]"
EOF
chmod +x "$TMP/bin/gh"

# Add some synthetic ambient events.
{
    printf '{"ts":"2026-05-23T00:00:00Z","event":"ALERT","reason":"test alert one"}\n'
    printf '{"ts":"2026-05-23T00:01:00Z","event":"WARN","reason":"test warn one"}\n'
    printf '{"ts":"2026-05-23T00:02:00Z","kind":"graphql_exhausted"}\n'
} >> "$CHUMP_AMBIENT_LOG"

# ── Test 1: human render contains all 5 sections ───────────────────────────
echo "Test 1: human render shows all 5 sections"
# bash -c so set -e doesn't propagate inner failures.
out=$(bash "$SCRIPT" 2>&1 || true)
missing=()
for h in "SHIPS" "ACTIVE LEASES" "INBOX" "PILLAR PICKABLE" "ALERT/WARN/STUCK"; do
    if ! echo "$out" | grep -q "$h"; then
        missing+=("$h")
    fi
done
if [[ ${#missing[@]} -eq 0 ]]; then
    echo "  PASS (all 5 sections present)"
else
    echo "  FAIL: missing sections: ${missing[*]}"
    echo "$out"
    exit 1
fi

# ── Test 2: --json envelope is valid JSON ─────────────────────────────────
echo "Test 2: --json envelope parses cleanly"
json=$(bash "$SCRIPT" --json 2>&1)
if echo "$json" | python3 -m json.tool >/dev/null 2>&1; then
    if echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'ts' in d
assert 'lightning' in d
assert 'session_id' in d
print('ok')
" 2>/dev/null | grep -q ok; then
        echo "  PASS"
    else
        echo "  FAIL: --json missing expected fields"
        echo "$json" | head -5
        exit 1
    fi
else
    echo "  FAIL: --json not valid JSON"
    echo "$json" | head -5
    exit 1
fi

# ── Test 3: ALERT/WARN section shows synthetic events ──────────────────────
echo "Test 3: ALERT/WARN section surfaces synthetic events"
out=$(bash "$SCRIPT" 2>&1 || true)
if echo "$out" | grep -q "test alert one" && echo "$out" | grep -q "test warn one"; then
    echo "  PASS"
else
    echo "  FAIL: synthetic ALERT/WARN events not surfaced"
    echo "$out" | grep -A 6 "ALERT/WARN"
    exit 1
fi

# ── Test 4: pillar section shows breakdown ──────────────────────────────────
echo "Test 4: pillar section reads audit-priorities"
out=$(bash "$SCRIPT" 2>&1 || true)
if echo "$out" | grep -q "EFFECTIVE=3" && echo "$out" | grep -q "RESILIENT=4"; then
    echo "  PASS"
else
    echo "  FAIL: pillar breakdown missing"
    echo "$out" | grep -A 1 "PILLAR PICKABLE"
    exit 1
fi

echo
echo "All 4 chump-dashboard-tui smoke tests passed."
