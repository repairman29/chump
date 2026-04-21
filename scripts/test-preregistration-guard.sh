#!/usr/bin/env bash
# Test the RESEARCH-019 preregistration pre-commit guard.
# Mirrors the INFRA-015 / scripts/test-duplicate-id-guard.sh pattern.
# Run from repo root: bash scripts/test-preregistration-guard.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── helper: run guard python inline ──────────────────────────────────────────
# We exercise the python snippet from the pre-commit hook directly so the test
# doesn't require a full git commit setup.

run_guard_python() {
    local old_yaml="$1"
    local new_yaml="$2"
    local prereg_path="$3"   # path that "exists" in HEAD (empty = not present)

    python3 - "$old_yaml" "$new_yaml" "$prereg_path" <<'PYEOF'
import sys, re, os, tempfile, subprocess

old_yaml_path = sys.argv[1]
new_yaml_path = sys.argv[2]
prereg_path   = sys.argv[3]  # "" means "file does not exist"

old_text = open(old_yaml_path).read()
new_text = open(new_yaml_path).read()

def parse_statuses(text):
    out = {}
    cur_id = None
    for line in text.splitlines():
        m = re.match(r'^\s*-\s*id:\s*(\S+)', line)
        if m:
            cur_id = m.group(1)
        elif cur_id and re.match(r'^\s*status:\s*(\S+)', line):
            s = re.match(r'^\s*status:\s*(\S+)', line).group(1)
            out[cur_id] = s
    return out

old = parse_statuses(old_text)
new = parse_statuses(new_text)

missing = []
for gid, new_status in new.items():
    if new_status != 'done':
        continue
    old_status = old.get(gid, 'open')
    if old_status == 'done':
        continue
    if not re.match(r'^(EVAL|RESEARCH)-', gid):
        continue
    # Check if preregistration exists (simulate git show via plain file check)
    if prereg_path and os.path.exists(prereg_path):
        continue
    missing.append(gid)

print("\n".join(missing))
PYEOF
}

# ── test fixtures ─────────────────────────────────────────────────────────────

GAPS_OLD="$TMPDIR_TEST/gaps_old.yaml"
GAPS_NEW="$TMPDIR_TEST/gaps_new.yaml"
GAPS_INFRA="$TMPDIR_TEST/gaps_infra.yaml"
PREREG_FILE="$TMPDIR_TEST/EVAL-099.md"

cat > "$GAPS_OLD" <<'EOF'
- id: EVAL-099
  title: Test eval gap
  domain: eval
  priority: P1
  effort: s
  status: open
EOF

cat > "$GAPS_NEW" <<'EOF'
- id: EVAL-099
  title: Test eval gap
  domain: eval
  priority: P1
  effort: s
  status: done
  closed_date: '2026-04-21'
EOF

# Infra gap (should NOT need preregistration)
cat > "$GAPS_INFRA" <<'EOF'
- id: INFRA-099
  title: Test infra gap
  domain: infra
  priority: P2
  effort: s
  status: done
  closed_date: '2026-04-21'
EOF

# INFRA gaps old
GAPS_INFRA_OLD="$TMPDIR_TEST/gaps_infra_old.yaml"
cat > "$GAPS_INFRA_OLD" <<'EOF'
- id: INFRA-099
  title: Test infra gap
  domain: infra
  priority: P2
  effort: s
  status: open
EOF

# ── test 1: EVAL gap done → no prereg file → should flag ─────────────────────
result=$(run_guard_python "$GAPS_OLD" "$GAPS_NEW" "" 2>/dev/null)
if echo "$result" | grep -q "EVAL-099"; then
    pass "test 1: EVAL gap done without prereg → flagged"
else
    fail "test 1: EVAL gap done without prereg → NOT flagged (got: '$result')"
fi

# ── test 2: EVAL gap done → prereg file present → should pass ────────────────
touch "$PREREG_FILE"
result=$(run_guard_python "$GAPS_OLD" "$GAPS_NEW" "$PREREG_FILE" 2>/dev/null)
if [ -z "$result" ]; then
    pass "test 2: EVAL gap done with prereg present → not flagged"
else
    fail "test 2: EVAL gap done with prereg present → flagged (got: '$result')"
fi

# ── test 3: INFRA gap done → no prereg file → should NOT flag ────────────────
result=$(run_guard_python "$GAPS_INFRA_OLD" "$GAPS_INFRA" "" 2>/dev/null)
if [ -z "$result" ]; then
    pass "test 3: INFRA gap done without prereg → not flagged (out of scope)"
else
    fail "test 3: INFRA gap done without prereg → flagged (should be exempt)"
fi

# ── test 4: EVAL gap already done in OLD → no flip → no flag ─────────────────
result=$(run_guard_python "$GAPS_NEW" "$GAPS_NEW" "" 2>/dev/null)
if [ -z "$result" ]; then
    pass "test 4: already-done EVAL gap not re-flagged on re-commit"
else
    fail "test 4: already-done EVAL gap re-flagged (should be silent)"
fi

# ── test 5: RESEARCH gap done without prereg → should flag ───────────────────
GAPS_RES_OLD="$TMPDIR_TEST/gaps_res_old.yaml"
GAPS_RES_NEW="$TMPDIR_TEST/gaps_res_new.yaml"
cat > "$GAPS_RES_OLD" <<'EOF'
- id: RESEARCH-099
  title: Test research gap
  domain: research
  priority: P0
  effort: s
  status: open
EOF
cat > "$GAPS_RES_NEW" <<'EOF'
- id: RESEARCH-099
  title: Test research gap
  domain: research
  priority: P0
  effort: s
  status: done
  closed_date: '2026-04-21'
EOF
result=$(run_guard_python "$GAPS_RES_OLD" "$GAPS_RES_NEW" "" 2>/dev/null)
if echo "$result" | grep -q "RESEARCH-099"; then
    pass "test 5: RESEARCH gap done without prereg → flagged"
else
    fail "test 5: RESEARCH gap done without prereg → NOT flagged (got: '$result')"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
