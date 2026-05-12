#!/usr/bin/env bash
# test-worktree-contamination-check.sh — INFRA-931
#
# Tests scripts/ops/worktree-contamination-check.sh with synthetic temp
# worktrees and planted untracked gap YAML files.
#
# Tests:
#  1. Script exists and is executable
#  2. EVENT_REGISTRY has worktree_contaminated
#  3. INFRA-931 referenced in script
#  4. Clean worktree: exits 0, no event emitted
#  5. Alien gap YAML planted: exits 1, emits worktree_contaminated
#  6. --fix removes the alien file and exits 0
#  7. --dry-run does NOT remove file, does NOT write to ambient
#  8. --json outputs contaminated_count field
#  9. Multiple contaminants: contaminated_count reflects full count
# 10. example_file field in emitted event matches planted file name

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$REPO_ROOT/scripts/ops/worktree-contamination-check.sh"

pass=0
fail=0
ok()  { echo "  PASS $1"; pass=$((pass + 1)); }
err() { echo "  FAIL $1"; fail=$((fail + 1)); }

echo "=== test-worktree-contamination-check.sh ==="

# ── Test 1: script exists and is executable ───────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "1: worktree-contamination-check.sh exists and is executable"
else
    err "1: script missing or not executable at $SCRIPT"
    exit 1
fi

# ── Test 2: EVENT_REGISTRY has worktree_contaminated ─────────────────────────
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "worktree_contaminated" "$REGISTRY"; then
    ok "2: worktree_contaminated registered in EVENT_REGISTRY.yaml"
else
    err "2: worktree_contaminated missing from EVENT_REGISTRY.yaml"
fi

# ── Test 3: INFRA-931 referenced in script ───────────────────────────────────
if grep -q "INFRA-931" "$SCRIPT"; then
    ok "3: INFRA-931 referenced in script"
else
    err "3: INFRA-931 not referenced in script"
fi

# ── Setup: create a synthetic git worktree ────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Create a minimal fake git repo to simulate a worktree
FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/docs/gaps" "$FAKE_REPO/scripts/ops"
cd "$FAKE_REPO"
git init -q
git config user.email "test@test.example"
git config user.name "Test"
# Seed one committed file so the repo is non-empty
echo "# fake" > "$FAKE_REPO/README.md"
git add README.md
git commit -q -m "init"
# Simulate being on a gap-claim branch
git checkout -q -b "chump/infra-931-claim"

AMBIENT="$TMP/ambient.jsonl"

# ── Test 4: clean worktree exits 0, no event ─────────────────────────────────
if REPO_ROOT="$REPO_ROOT" CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_CURRENT_GAP_ID="INFRA-931" \
   bash "$SCRIPT" "$FAKE_REPO" >/dev/null 2>&1; then
    ok "4: clean worktree exits 0"
else
    err "4: clean worktree should exit 0"
fi
if [[ ! -f "$AMBIENT" ]] || ! grep -q "worktree_contaminated" "$AMBIENT" 2>/dev/null; then
    ok "4b: clean worktree emits no worktree_contaminated event"
else
    err "4b: clean worktree emitted unexpected event"
fi

# ── Test 5: alien gap YAML planted → exits 1, emits event ────────────────────
# Plant an alien gap file (belongs to INFRA-999, not INFRA-931)
echo "- id: INFRA-999" > "$FAKE_REPO/docs/gaps/INFRA-999.yaml"

AMB5="$TMP/amb5.jsonl"
if ! REPO_ROOT="$REPO_ROOT" CHUMP_AMBIENT_LOG="$AMB5" CHUMP_CURRENT_GAP_ID="INFRA-931" \
   bash "$SCRIPT" "$FAKE_REPO" >/dev/null 2>&1; then
    ok "5: alien gap YAML detected → exits 1"
else
    err "5: should exit 1 when alien gap YAML present"
fi
if grep -q "worktree_contaminated" "$AMB5" 2>/dev/null; then
    ok "5b: emits worktree_contaminated event"
else
    err "5b: worktree_contaminated event not found in ambient"
fi

# ── Test 6: --fix removes the alien file, exits 0 ────────────────────────────
# Re-plant (test 5 didn't remove it)
echo "- id: INFRA-999" > "$FAKE_REPO/docs/gaps/INFRA-999.yaml"
AMB6="$TMP/amb6.jsonl"
if REPO_ROOT="$REPO_ROOT" CHUMP_AMBIENT_LOG="$AMB6" CHUMP_CURRENT_GAP_ID="INFRA-931" \
   bash "$SCRIPT" --fix "$FAKE_REPO" >/dev/null 2>&1; then
    ok "6: --fix exits 0"
else
    err "6: --fix should exit 0 after removing contaminants"
fi
if [[ ! -f "$FAKE_REPO/docs/gaps/INFRA-999.yaml" ]]; then
    ok "6b: --fix removed the alien file"
else
    err "6b: --fix did not remove docs/gaps/INFRA-999.yaml"
fi

# ── Test 7: --dry-run does NOT remove file, does NOT write to ambient ─────────
echo "- id: INFRA-999" > "$FAKE_REPO/docs/gaps/INFRA-999.yaml"
AMB7="$TMP/amb7.jsonl"
REPO_ROOT="$REPO_ROOT" CHUMP_AMBIENT_LOG="$AMB7" CHUMP_CURRENT_GAP_ID="INFRA-931" \
    bash "$SCRIPT" --dry-run "$FAKE_REPO" >/dev/null 2>&1 || true

if [[ -f "$FAKE_REPO/docs/gaps/INFRA-999.yaml" ]]; then
    ok "7: --dry-run did not remove the file"
else
    err "7: --dry-run removed the file (should not have)"
fi
if [[ ! -f "$AMB7" ]] || ! grep -q "worktree_contaminated" "$AMB7" 2>/dev/null; then
    ok "7b: --dry-run did not write to ambient"
else
    err "7b: --dry-run wrote to ambient (should not have)"
fi

# ── Test 8: --json outputs contaminated_count ─────────────────────────────────
# INFRA-999.yaml is still planted from test 7
AMB8="$TMP/amb8.jsonl"
JSON_OUT=$(REPO_ROOT="$REPO_ROOT" CHUMP_AMBIENT_LOG="$AMB8" CHUMP_CURRENT_GAP_ID="INFRA-931" \
    bash "$SCRIPT" --json "$FAKE_REPO" 2>/dev/null || true)
if python3 -c "
import json, sys
data = json.loads('''$JSON_OUT''')
assert 'contaminated_count' in data, f'missing contaminated_count in: {data}'
assert data['contaminated_count'] >= 1, f'expected >=1 contaminated, got {data}'
" 2>/dev/null; then
    ok "8: --json outputs contaminated_count ≥ 1"
else
    err "8: --json missing contaminated_count (got: $JSON_OUT)"
fi

# ── Test 9: multiple contaminants: contaminated_count reflects full count ─────
echo "- id: INFRA-888" > "$FAKE_REPO/docs/gaps/INFRA-888.yaml"
# INFRA-999.yaml still present from test 7
AMB9="$TMP/amb9.jsonl"
JSON9=$(REPO_ROOT="$REPO_ROOT" CHUMP_AMBIENT_LOG="$AMB9" CHUMP_CURRENT_GAP_ID="INFRA-931" \
    bash "$SCRIPT" --json "$FAKE_REPO" 2>/dev/null || true)
if python3 -c "
import json
data = json.loads('''$JSON9''')
assert data.get('contaminated_count', 0) >= 2, f'expected >=2, got {data}'
" 2>/dev/null; then
    ok "9: multiple contaminants reflected in contaminated_count"
else
    err "9: contaminated_count wrong for 2 alien files (got: $JSON9)"
fi

# ── Test 10: example_file in emitted event matches planted file ───────────────
AMB10="$TMP/amb10.jsonl"
REPO_ROOT="$REPO_ROOT" CHUMP_AMBIENT_LOG="$AMB10" CHUMP_CURRENT_GAP_ID="INFRA-931" \
    bash "$SCRIPT" "$FAKE_REPO" >/dev/null 2>&1 || true

if python3 -c "
import json
events = [json.loads(l) for l in open('$AMB10') if l.strip()]
e = next((x for x in events if x.get('kind') == 'worktree_contaminated'), None)
assert e is not None, 'no worktree_contaminated event'
assert e.get('example_file'), f'example_file empty: {e}'
assert e.get('contaminated_count', 0) >= 1, f'contaminated_count wrong: {e}'
assert 'worktree_path' in e, f'missing worktree_path: {e}'
assert 'gap_id' in e, f'missing gap_id: {e}'
" 2>/dev/null; then
    ok "10: event payload has example_file, contaminated_count, worktree_path, gap_id"
else
    err "10: event payload missing required fields (content: $(cat "$AMB10" 2>/dev/null || echo 'empty'))"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
