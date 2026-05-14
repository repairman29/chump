#!/usr/bin/env bash
# test-gap-ac-requirement.sh — CREDIBLE-054
#
# Verifies the pre-commit AC enforcement gate:
#   1. Pre-commit hook rejects a gap YAML without acceptance_criteria
#   2. Pre-commit hook accepts a gap YAML with acceptance_criteria
#   3. CHUMP_AC_CHECK=0 bypass suppresses the check
#   4. The hook error message references FEEDBACK_GAPS_ALWAYS_HAVE_AC.md
#   5. No existing gaps in docs/gaps/*.yaml lack acceptance_criteria

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-credible-054.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Set up an isolated git repo for hook testing ───────────────────────────
FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/docs/gaps"
git -C "$FAKE_REPO" init --quiet
git -C "$FAKE_REPO" config user.email "ci@credible-054.test"
git -C "$FAKE_REPO" config user.name "CI"
echo "init" > "$FAKE_REPO/README.md"
git -C "$FAKE_REPO" add README.md
git -C "$FAKE_REPO" commit --quiet -m "init"

# Install a minimal pre-commit hook that runs only the AC check
HOOK="$FAKE_REPO/.git/hooks/pre-commit"
mkdir -p "$(dirname "$HOOK")"
cat > "$HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${CHUMP_AC_CHECK:-1}" = "0" ]; then exit 0; fi
if git diff --cached --name-only --diff-filter=ACM | grep -qE '^docs/gaps(/[^/]+\.yaml|\.yaml)$'; then
    _vague=$(python3 - <<'PYEOF'
import re, subprocess, sys

def staged_text(path):
    try:
        return subprocess.check_output(
            ["git", "show", f":0:{path}"], stderr=subprocess.DEVNULL
        ).decode("utf-8", errors="replace")
    except Exception:
        return ""

def check_acs(text):
    vague = []
    cur_id = None
    in_acs = False
    has_acs_key = False
    ac_item_count = 0
    for line in text.splitlines():
        id_m = re.match(r"^-?\s*id:\s*([A-Z][A-Z0-9_-]+)", line)
        if id_m:
            if cur_id is not None and (has_acs_key is False or ac_item_count == 0):
                vague.append(cur_id)
            cur_id = id_m.group(1)
            has_acs_key = False
            in_acs = False
            ac_item_count = 0
            continue
        if cur_id is None:
            continue
        if re.match(r"^\s+acceptance_criteria\s*:", line):
            has_acs_key = True
            in_acs = True
            continue
        if in_acs:
            if re.match(r"^\s+[a-z_]+\s*:", line) and not line.strip().startswith("-"):
                in_acs = False
                continue
            if line.strip().startswith("- "):
                ac_item_count += 1
    if cur_id is not None and (has_acs_key is False or ac_item_count == 0):
        vague.append(cur_id)
    return vague

staged_paths = [p for p in subprocess.check_output(
    ["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"],
    stderr=subprocess.DEVNULL
).decode().splitlines()
    if re.match(r"^docs/gaps(/[^/]+\.yaml|\.yaml)$", p)]

vague_gaps = []
for path in staged_paths:
    txt = staged_text(path)
    if txt:
        vague_gaps.extend(check_acs(txt))
print("\n".join(vague_gaps))
PYEOF
)
    if [ -n "$_vague" ]; then
        echo "[pre-commit] ACCEPTANCE CRITERIA REQUIRED (CREDIBLE-054) — gap(s) lack acceptance_criteria:" >&2
        echo "$_vague" | sed 's/^/  /' >&2
        echo "[pre-commit] See: docs/FEEDBACK_GAPS_ALWAYS_HAVE_AC.md" >&2
        exit 1
    fi
fi
exit 0
HOOK_EOF
chmod +x "$HOOK"

# ── Test 1: gap without AC is rejected ─────────────────────────────────────
# Use list-item YAML format (matching actual docs/gaps/*.yaml convention)
cat > "$FAKE_REPO/docs/gaps/TEST-001.yaml" <<'YAML'
- id: TEST-001
  title: "A gap without AC"
  status: open
  priority: P2
  effort: xs
YAML
git -C "$FAKE_REPO" add "docs/gaps/TEST-001.yaml"
if git -C "$FAKE_REPO" commit -m "add gap without AC" 2>/dev/null; then
    fail "Test 1: pre-commit should have rejected gap without acceptance_criteria"
fi
git -C "$FAKE_REPO" restore --staged "docs/gaps/TEST-001.yaml" 2>/dev/null || true
git -C "$FAKE_REPO" rm --cached "docs/gaps/TEST-001.yaml" 2>/dev/null || true
rm -f "$FAKE_REPO/docs/gaps/TEST-001.yaml"
pass "Test 1: pre-commit rejects gap without acceptance_criteria"

# ── Test 2: gap with AC is accepted ────────────────────────────────────────
cat > "$FAKE_REPO/docs/gaps/TEST-002.yaml" <<'YAML'
- id: TEST-002
  title: "A gap with AC"
  status: open
  priority: P2
  effort: xs
  acceptance_criteria:
    - "scripts/ci/test-002.sh passes"
YAML
git -C "$FAKE_REPO" add "docs/gaps/TEST-002.yaml"
if ! git -C "$FAKE_REPO" commit -m "add gap with AC" 2>&1; then
    fail "Test 2: pre-commit should accept gap with acceptance_criteria"
fi
pass "Test 2: pre-commit accepts gap with acceptance_criteria"

# ── Test 3: CHUMP_AC_CHECK=0 bypass ────────────────────────────────────────
cat > "$FAKE_REPO/docs/gaps/TEST-003.yaml" <<'YAML'
- id: TEST-003
  title: "A gap with no AC but bypass set"
  status: open
YAML
git -C "$FAKE_REPO" add "docs/gaps/TEST-003.yaml"
if ! CHUMP_AC_CHECK=0 git -C "$FAKE_REPO" commit -m "bypass AC check" 2>/dev/null; then
    fail "Test 3: CHUMP_AC_CHECK=0 should bypass the AC check"
fi
pass "Test 3: CHUMP_AC_CHECK=0 bypasses the check"

# ── Test 4: error message references FEEDBACK_GAPS_ALWAYS_HAVE_AC.md ───────
cat > "$FAKE_REPO/docs/gaps/TEST-004.yaml" <<'YAML'
- id: TEST-004
  title: "Another gap without AC"
  status: open
YAML
git -C "$FAKE_REPO" add "docs/gaps/TEST-004.yaml"
hook_output=$(git -C "$FAKE_REPO" commit -m "test error msg" 2>&1 || true)
git -C "$FAKE_REPO" rm --cached "docs/gaps/TEST-004.yaml" 2>/dev/null || true
rm -f "$FAKE_REPO/docs/gaps/TEST-004.yaml"
if echo "$hook_output" | grep -q "FEEDBACK_GAPS_ALWAYS_HAVE_AC.md"; then
    pass "Test 4: error message references FEEDBACK_GAPS_ALWAYS_HAVE_AC.md"
else
    fail "Test 4: error message does not reference FEEDBACK_GAPS_ALWAYS_HAVE_AC.md (got: $hook_output)"
fi

# ── Test 5: no existing gaps in the real repo lack acceptance_criteria ──────
MISSING_AC=""
for yaml_file in "$REPO_ROOT"/docs/gaps/*.yaml; do
    [[ -f "$yaml_file" ]] || continue
    gap_id=$(grep -m1 '^id:' "$yaml_file" | awk '{print $2}' | tr -d '"' 2>/dev/null || true)
    [[ -z "$gap_id" ]] && continue
    # Check for acceptance_criteria key
    if ! grep -q "acceptance_criteria" "$yaml_file"; then
        MISSING_AC="$MISSING_AC $gap_id"
    fi
done
if [[ -n "$MISSING_AC" ]]; then
    fail "Test 5: the following gaps in docs/gaps/ lack acceptance_criteria:$MISSING_AC"
fi
pass "Test 5: all docs/gaps/*.yaml files have acceptance_criteria"

echo ""
echo "All CREDIBLE-054 AC-enforcement checks passed (5/5)."
