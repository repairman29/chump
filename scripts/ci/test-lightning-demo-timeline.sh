#!/usr/bin/env bash
# test-lightning-demo-timeline.sh — INFRA-1887 smoke.
#
# Network-free: stubs `gh` on PATH. Verifies the timeline script:
#   1. Empty PR list → renders header + summary "0 ships" + exit 0.
#   2. Synthetic 3-PR list → JSON output has 3 records + summary fields.
#   3. Table mode renders gap_ids extracted from titles + delta columns.
#   4. --json mode produces parseable JSON envelope.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/lightning-demo-timeline.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

make_gh_stub() {
    # $1 = json text the stub will emit for `gh pr list ...`
    cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
# Stub: ignore args, emit canned JSON.
cat <<'PRS_EOF'
$1
PRS_EOF
EOF
    chmod +x "$TMP/bin/gh"
}

# ── Test 1: empty PR list ────────────────────────────────────────────────────
echo "Test 1: empty PR list"
make_gh_stub "[]"
out=$("$SCRIPT" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q '0 ships'; then
    echo "  PASS"
else
    echo "  FAIL: rc=$rc out=$out"
    exit 1
fi

# ── Test 2: 3-PR JSON envelope ──────────────────────────────────────────────
echo "Test 2: 3 PRs → JSON envelope shape"
PR_DATA='[
  {"number":2001,"title":"feat(INFRA-1809): RESILIENT firewall","createdAt":"2026-05-23T22:00:00Z","mergedAt":"2026-05-23T22:10:00Z","headRefName":"chump/infra-1809-claim"},
  {"number":2002,"title":"feat(INFRA-1828): RPC wrappers","createdAt":"2026-05-23T21:30:00Z","mergedAt":"2026-05-23T21:45:00Z","headRefName":"chump/infra-1828-claim"},
  {"number":2003,"title":"feat(META-083): taxonomy","createdAt":"2026-05-23T20:00:00Z","mergedAt":"2026-05-23T20:20:00Z","headRefName":"chump/meta-083-claim"}
]'
make_gh_stub "$PR_DATA"
json=$("$SCRIPT" --json 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'records' in d and 'summary' in d
assert len(d['records']) == 3
assert d['summary']['ship_count'] == 3
gaps = {r['gap_id'] for r in d['records']}
assert {'INFRA-1809','INFRA-1828','META-083'}.issubset(gaps)
print('ok')
" 2>/dev/null | grep -q ok; then
    echo "  PASS"
else
    echo "  FAIL: rc=$rc json=$json"
    exit 1
fi

# ── Test 3: Table mode prints gap IDs + delta columns ───────────────────────
echo "Test 3: table mode renders gap_id columns"
out=$("$SCRIPT" 2>&1)
if echo "$out" | grep -q "INFRA-1809" && echo "$out" | grep -q "claim→open" && echo "$out" | grep -q "Summary:"; then
    echo "  PASS"
else
    echo "  FAIL: table missing expected content"
    echo "$out"
    exit 1
fi

# ── Test 4: --json mode shape stable ────────────────────────────────────────
echo "Test 4: --json output parses cleanly"
json=$("$SCRIPT" --json 2>&1)
if echo "$json" | python3 -m json.tool > /dev/null 2>&1; then
    echo "  PASS"
else
    echo "  FAIL: --json output not valid JSON"
    echo "$json"
    exit 1
fi

echo
echo "All 4 lightning-demo-timeline smoke tests passed."
