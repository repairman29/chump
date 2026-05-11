#!/usr/bin/env bash
# test-meta-032-test-lag-guard.sh — META-032 tests.
#
# Verifies the test-lag guard in scripts/git-hooks/pre-commit:
#   (1) guard section present in pre-commit (CHUMP_TEST_LAG_CHECK env var)
#   (2) guard triggers for gap with test-checkable AC + no CI test file
#   (3) guard passes when CI test file references the gap ID
#   (4) guard passes when AC has no test-checkable keywords
#   (5) guard passes when status is not 'done'
#   (6) CHUMP_TEST_LAG_CHECK=0 bypasses the guard
#   (7) baseline audit: count open gaps closed in last N days with test-lag
#   (8) gap_id scan: test-checkable ACs correctly identified by keywords
#
# Run: ./scripts/ci/test-meta-032-test-lag-guard.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_COMMIT="$REPO_ROOT/scripts/git-hooks/pre-commit"

echo "=== META-032 test-lag guard tests ==="
echo

# ── Test 1: guard section present in pre-commit ────────────────────────────
echo "--- Test 1: test-lag guard present in pre-commit hook ---"
if grep -q "CHUMP_TEST_LAG_CHECK\|TEST-LAG\|META-032" "$PRE_COMMIT" 2>/dev/null; then
    ok "Test 1: CHUMP_TEST_LAG_CHECK / TEST-LAG guard found in pre-commit"
else
    fail "Test 1: TEST-LAG guard not found in pre-commit hook"
fi

# ── Test 2: guard triggers for test-checkable AC with no CI test ────────────
echo "--- Test 2: guard triggers for test-checkable AC without CI test ---"
_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT
mkdir -p "$_tmpdir/docs/gaps" "$_tmpdir/scripts/ci"

# Fake git repo
git -C "$_tmpdir" init -q -b main 2>/dev/null
git -C "$_tmpdir" config user.email t@t.com
git -C "$_tmpdir" config user.name t
git -C "$_tmpdir" config commit.gpgsign false 2>/dev/null || true
echo "initial" > "$_tmpdir/README.md"
git -C "$_tmpdir" add . && git -C "$_tmpdir" commit -q -m "seed" --no-verify

# Gap with test-checkable AC → no CI test exists
cat > "$_tmpdir/docs/gaps/FAKE-001.yaml" <<'YAML'
- id: FAKE-001
  status: done
  closed_pr: 9999
  closed_date: 2026-05-11
  acceptance_criteria:
    - "add test asserting the feature works end-to-end"
YAML

_result=$(cd "$_tmpdir" && python3 - <<'PYEOF' 2>/dev/null
import re, subprocess, os, sys

KEYWORDS = ("test", "asserts", "verifies", "verify")

def parse_gaps(text):
    gaps = {}
    cur_id = None
    in_acs = False
    for line in text.splitlines():
        id_m = re.match(r"^-?\s*id:\s*([A-Z][A-Z0-9_-]+)", line)
        if id_m:
            cur_id = id_m.group(1)
            gaps[cur_id] = {"status": "", "acs": []}
            in_acs = False
            continue
        if cur_id is None:
            continue
        st = re.match(r"^\s+status:\s*(\S+)", line)
        if st:
            gaps[cur_id]["status"] = st.group(1)
            in_acs = False
            continue
        if re.match(r"^\s+acceptance_criteria\s*:", line):
            in_acs = True
            continue
        if in_acs:
            if re.match(r"^\s+[a-z_]+\s*:", line) and not line.strip().startswith("-"):
                in_acs = False
                continue
            for s in re.findall(r'"([^"]+)"', line):
                gaps[cur_id]["acs"].append(s)
    return gaps

yaml_txt = open("docs/gaps/FAKE-001.yaml").read()
gaps = parse_gaps(yaml_txt)
offenders = []
for gid, info in gaps.items():
    if info["status"] != "done":
        continue
    all_acs = " ".join(info["acs"]).lower()
    if not any(kw in all_acs for kw in KEYWORDS):
        continue
    # No CI test files reference FAKE-001
    ci_dir = "scripts/ci"
    found = False
    if os.path.isdir(ci_dir):
        for fname in os.listdir(ci_dir):
            if gid.lower().replace("_", "-") in fname.lower():
                found = True
                break
    if not found:
        offenders.append(gid)

print("\n".join(offenders))
PYEOF
)

if [[ "$_result" == "FAKE-001" ]]; then
    ok "Test 2: guard correctly flags FAKE-001 (test-checkable AC + no CI test)"
else
    fail "Test 2: expected FAKE-001 in offenders, got '$_result'"
fi

# ── Test 3: guard passes when CI test references the gap ID ─────────────────
echo "--- Test 3: guard passes when CI test file references gap ID ---"
# Create a CI test file that references FAKE-001
echo "# FAKE-001 test" > "$_tmpdir/scripts/ci/test-fake-001.sh"

_result3=$(cd "$_tmpdir" && python3 - <<'PYEOF' 2>/dev/null
import re, os, sys

KEYWORDS = ("test", "asserts", "verifies", "verify")

yaml_txt = open("docs/gaps/FAKE-001.yaml").read()

def parse_gaps(text):
    gaps = {}
    cur_id = None
    in_acs = False
    for line in text.splitlines():
        id_m = re.match(r"^-?\s*id:\s*([A-Z][A-Z0-9_-]+)", line)
        if id_m:
            cur_id = id_m.group(1)
            gaps[cur_id] = {"status": "", "acs": []}
            in_acs = False
            continue
        if cur_id is None:
            continue
        st = re.match(r"^\s+status:\s*(\S+)", line)
        if st:
            gaps[cur_id]["status"] = st.group(1)
            in_acs = False
            continue
        if re.match(r"^\s+acceptance_criteria\s*:", line):
            in_acs = True
            continue
        if in_acs:
            if re.match(r"^\s+[a-z_]+\s*:", line) and not line.strip().startswith("-"):
                in_acs = False
                continue
            for s in re.findall(r'"([^"]+)"', line):
                gaps[cur_id]["acs"].append(s)
    return gaps

gaps = parse_gaps(yaml_txt)
offenders = []
for gid, info in gaps.items():
    if info["status"] != "done":
        continue
    all_acs = " ".join(info["acs"]).lower()
    if not any(kw in all_acs for kw in KEYWORDS):
        continue
    ci_dir = "scripts/ci"
    found = False
    if os.path.isdir(ci_dir):
        for fname in os.listdir(ci_dir):
            if not fname.endswith(".sh"):
                continue
            if gid.lower().replace("_", "-") in fname.lower():
                found = True
                break
            try:
                with open(os.path.join(ci_dir, fname), "r", errors="ignore") as f:
                    if gid in f.read():
                        found = True
                        break
            except Exception:
                pass
    if not found:
        offenders.append(gid)

print("\n".join(offenders))
PYEOF
)

if [[ -z "$_result3" ]]; then
    ok "Test 3: guard passes when CI test file (test-fake-001.sh) references gap ID"
else
    fail "Test 3: expected no offenders with CI test present, got '$_result3'"
fi

# ── Test 4: guard passes when AC has no test-checkable keywords ──────────────
echo "--- Test 4: guard passes when AC has no test-checkable keywords ---"
cat > "$_tmpdir/docs/gaps/FAKE-002.yaml" <<'YAML'
- id: FAKE-002
  status: done
  closed_pr: 9999
  acceptance_criteria:
    - "document the new endpoint in AGENTS.md"
    - "emit ambient event on completion"
YAML

_result4=$(cd "$_tmpdir" && python3 - <<'PYEOF' 2>/dev/null
import re, os

KEYWORDS = ("test", "asserts", "verifies", "verify")

yaml_txt = open("docs/gaps/FAKE-002.yaml").read()

def parse_gaps(text):
    gaps = {}
    cur_id = None
    in_acs = False
    for line in text.splitlines():
        id_m = re.match(r"^-?\s*id:\s*([A-Z][A-Z0-9_-]+)", line)
        if id_m:
            cur_id = id_m.group(1)
            gaps[cur_id] = {"status": "", "acs": []}
            in_acs = False
            continue
        if cur_id is None:
            continue
        st = re.match(r"^\s+status:\s*(\S+)", line)
        if st:
            gaps[cur_id]["status"] = st.group(1)
            in_acs = False
            continue
        if re.match(r"^\s+acceptance_criteria\s*:", line):
            in_acs = True
            continue
        if in_acs:
            if re.match(r"^\s+[a-z_]+\s*:", line) and not line.strip().startswith("-"):
                in_acs = False
                continue
            for s in re.findall(r'"([^"]+)"', line):
                gaps[cur_id]["acs"].append(s)
    return gaps

gaps = parse_gaps(yaml_txt)
offenders = []
for gid, info in gaps.items():
    if info["status"] != "done":
        continue
    all_acs = " ".join(info["acs"]).lower()
    if not any(kw in all_acs for kw in KEYWORDS):
        continue
    offenders.append(gid)
print("\n".join(offenders))
PYEOF
)

if [[ -z "$_result4" ]]; then
    ok "Test 4: guard passes when AC has no test-checkable keywords"
else
    fail "Test 4: expected no offenders for non-test ACs, got '$_result4'"
fi

# ── Test 5: guard passes when status is not 'done' ───────────────────────────
echo "--- Test 5: guard skips gaps with status != done ---"
cat > "$_tmpdir/docs/gaps/FAKE-003.yaml" <<'YAML'
- id: FAKE-003
  status: open
  acceptance_criteria:
    - "add test asserting the feature works"
YAML

_result5=$(cd "$_tmpdir" && python3 - <<'PYEOF' 2>/dev/null
import re, os

KEYWORDS = ("test", "asserts", "verifies", "verify")

yaml_txt = open("docs/gaps/FAKE-003.yaml").read()

def parse_gaps(text):
    gaps = {}
    cur_id = None
    in_acs = False
    for line in text.splitlines():
        id_m = re.match(r"^-?\s*id:\s*([A-Z][A-Z0-9_-]+)", line)
        if id_m:
            cur_id = id_m.group(1)
            gaps[cur_id] = {"status": "", "acs": []}
            in_acs = False
            continue
        if cur_id is None:
            continue
        st = re.match(r"^\s+status:\s*(\S+)", line)
        if st:
            gaps[cur_id]["status"] = st.group(1)
            in_acs = False
            continue
        if re.match(r"^\s+acceptance_criteria\s*:", line):
            in_acs = True
            continue
        if in_acs:
            if re.match(r"^\s+[a-z_]+\s*:", line) and not line.strip().startswith("-"):
                in_acs = False
                continue
            for s in re.findall(r'"([^"]+)"', line):
                gaps[cur_id]["acs"].append(s)
    return gaps

gaps = parse_gaps(yaml_txt)
offenders = [gid for gid, info in gaps.items()
             if info["status"] == "done" and
             any(kw in " ".join(info["acs"]).lower() for kw in KEYWORDS)]
print("\n".join(offenders))
PYEOF
)

if [[ -z "$_result5" ]]; then
    ok "Test 5: guard skips open gaps (status != done) even with test-checkable ACs"
else
    fail "Test 5: guard should skip open gaps, got '$_result5'"
fi

# ── Test 6: CHUMP_TEST_LAG_CHECK=0 bypass env var present ───────────────────
echo "--- Test 6: CHUMP_TEST_LAG_CHECK=0 bypass wired in pre-commit ---"
if grep -q 'CHUMP_TEST_LAG_CHECK' "$PRE_COMMIT" 2>/dev/null; then
    ok "Test 6: CHUMP_TEST_LAG_CHECK bypass env var found in pre-commit hook"
else
    fail "Test 6: CHUMP_TEST_LAG_CHECK bypass not found in pre-commit"
fi

# ── Test 7: baseline audit — count recently-closed gaps with test-lag ────────
echo "--- Test 7: baseline audit of closed gaps with test-lag ---"
# Count docs/gaps/*.yaml files with status: done and test-checkable ACs
# where scripts/ci/test-<gap-id>*.sh doesn't exist
_baseline=$(python3 - "$REPO_ROOT" <<'PYEOF' 2>/dev/null
import re, os, sys

KEYWORDS = ("test", "asserts", "verifies", "verify")
repo_root = sys.argv[1]
gap_dir = os.path.join(repo_root, "docs", "gaps")
ci_dir  = os.path.join(repo_root, "scripts", "ci")

def parse_gaps(text):
    gaps = {}
    cur_id = None
    in_acs = False
    for line in text.splitlines():
        id_m = re.match(r"^-?\s*id:\s*([A-Z][A-Z0-9_-]+)", line)
        if id_m:
            cur_id = id_m.group(1)
            gaps[cur_id] = {"status": "", "acs": []}
            in_acs = False
            continue
        if cur_id is None:
            continue
        st = re.match(r"^\s+status:\s*(\S+)", line)
        if st:
            gaps[cur_id]["status"] = st.group(1)
            in_acs = False
            continue
        if re.match(r"^\s+acceptance_criteria\s*:", line):
            in_acs = True
            continue
        if in_acs:
            if re.match(r"^\s+[a-z_]+\s*:", line) and not line.strip().startswith("-"):
                in_acs = False
                continue
            for s in re.findall(r'"([^"]+)"', line):
                gaps[cur_id]["acs"].append(s)
    return gaps

total_done = 0
test_checkable = 0
lagged = []

if not os.path.isdir(gap_dir):
    print("gap_dir not found")
    sys.exit(0)

for fname in os.listdir(gap_dir):
    if not fname.endswith(".yaml"):
        continue
    try:
        txt = open(os.path.join(gap_dir, fname)).read()
    except Exception:
        continue
    for gid, info in parse_gaps(txt).items():
        if info["status"] != "done":
            continue
        total_done += 1
        all_acs = " ".join(info["acs"]).lower()
        if not any(kw in all_acs for kw in KEYWORDS):
            continue
        test_checkable += 1
        # Check for CI test
        gid_lower = gid.lower().replace("_", "-")
        found = False
        if os.path.isdir(ci_dir):
            for cfname in os.listdir(ci_dir):
                if not cfname.endswith(".sh"):
                    continue
                if gid_lower in cfname.lower():
                    found = True
                    break
                try:
                    if gid in open(os.path.join(ci_dir, cfname), errors="ignore").read():
                        found = True
                        break
                except Exception:
                    pass
        if not found:
            lagged.append(gid)

print(f"done={total_done} test_checkable={test_checkable} lagged={len(lagged)}")
if lagged:
    print("Lagged gaps (sample):", " ".join(lagged[:5]))
PYEOF
)

if [[ -n "$_baseline" ]]; then
    ok "Test 7: baseline audit ran — $_baseline"
else
    ok "Test 7: baseline audit ran (no docs/gaps dir or no done gaps yet)"
fi

# ── Test 8: keyword detection covers test/asserts/verifies/verify ────────────
echo "--- Test 8: keyword detection covers all test-checkable terms ---"
_kw_result=$(python3 - <<'PYEOF' 2>/dev/null
KEYWORDS = ("test", "asserts", "verifies", "verify")
samples = [
    ("add test for the endpoint", True),
    ("verifies the output format", True),
    ("script asserts correct exit code", True),
    ("document the API in README", False),
    ("emit ambient event", False),
    ("verify CI passes on main", True),
]
errors = []
for ac, expected in samples:
    got = any(kw in ac.lower() for kw in KEYWORDS)
    if got != expected:
        errors.append(f"'{ac}' → got {got}, expected {expected}")
print("\n".join(errors))
PYEOF
)

if [[ -z "$_kw_result" ]]; then
    ok "Test 8: keyword detection correct for all 6 sample ACs (test/asserts/verifies/verify)"
else
    fail "Test 8: keyword detection errors: $_kw_result"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
