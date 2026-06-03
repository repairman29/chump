#!/usr/bin/env bash
# test-event-registry-audit-regression.sh — INFRA-2496
#
# Regression test: verifies that kinds registered in EVENT_REGISTRY.yaml are
# actually recognised by the audit parser (not silently dropped).
#
# Background: INFRA-2417 added daemon_exit_loop_detected/recovered/disabled to
# the registry. INFRA-1121 (commit 25d4219af) clobbered all three via a bad
# merge-conflict resolution. The audit reported them as EMIT-NO-REG even though
# the scanner-anchor comments were present in the emit script — because the
# registry entries themselves were gone. INFRA-2496 restored them and added this
# regression guard.
#
# Test strategy:
#   1. Write a minimal synthetic registry YAML containing a single test kind.
#   2. Write a synthetic production script that emits that kind via a JSON literal.
#   3. Run test-event-registry-coverage.sh pointing at these fixtures (via env
#      vars the script itself uses if present, or directly via PYEOF invocation).
#   4. Assert exit code is 0 (no EMIT-NO-REG for the registered kind).
#   5. Flip the scenario: remove the kind from the registry and assert exit 1.
#
# Also verifies the specific INFRA-2417 kinds are present in the real registry.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
_pass() { echo "  PASS: $*"; ((PASS++)) || true; }
_fail() { echo "  FAIL: $*"; ((FAIL++)) || true; }

echo "[registry-regression] INFRA-2496 regression suite"

# ── Test 1: Real registry contains all 3 INFRA-2417 kinds ────────────────────
echo ""
echo "Test 1: INFRA-2417 kinds present in real EVENT_REGISTRY.yaml"
REAL_REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
for kind in daemon_exit_loop_detected daemon_exit_loop_recovered daemon_exit_loop_disabled; do
    if grep -q "kind: $kind" "$REAL_REGISTRY"; then
        _pass "kind '$kind' is registered in EVENT_REGISTRY.yaml"
    else
        _fail "kind '$kind' is MISSING from EVENT_REGISTRY.yaml"
    fi
done

# ── Test 2: Audit script does not report INFRA-2417 kinds as EMIT-NO-REG ─────
echo ""
echo "Test 2: audit script passes with real registry (no EMIT-NO-REG for INFRA-2417 kinds)"
audit_out=$(cd "$REPO_ROOT" && bash "$SCRIPT_DIR/test-event-registry-coverage.sh" 2>&1)
audit_rc=$?
for kind in daemon_exit_loop_detected daemon_exit_loop_recovered daemon_exit_loop_disabled; do
    if echo "$audit_out" | grep -q "EMIT-NO-REG: $kind"; then
        _fail "audit reports EMIT-NO-REG for '$kind' — merge-clobber regression reoccurred"
    else
        _pass "audit does NOT report EMIT-NO-REG for '$kind'"
    fi
done
if [[ $audit_rc -eq 0 ]]; then
    _pass "audit script exits 0 (overall pass)"
else
    _fail "audit script exits $audit_rc (overall fail) — may have other violations"
fi

# ── Test 3: Synthetic fixture — registered + emitted → no EMIT-NO-REG ────────
echo ""
echo "Test 3: synthetic registry+emit fixture — registered kind is NOT flagged"
TMPDIR_FIX=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FIX"' EXIT

# Minimal registry with one synthetic kind.
cat > "$TMPDIR_FIX/REGISTRY.yaml" <<'YAML'
events:
  - kind: infra_2496_regression_sentinel
    effect_metric: self
    emitter: test-fixture (INFRA-2496)
    trigger: Synthetic kind used only by the regression test.
    consumers: []
    fields_required: [ts, kind]
    status: stable
YAML

# Synthetic production script that emits via JSON literal.
mkdir -p "$TMPDIR_FIX/scripts/coord"
cat > "$TMPDIR_FIX/scripts/coord/synthetic-emitter.sh" <<'SH'
#!/usr/bin/env bash
printf '{"ts":"2026-01-01T00:00:00Z","kind":"infra_2496_regression_sentinel"}\n'
SH

# Run the inline Python audit logic directly against the fixtures.
result=$(python3 - "$TMPDIR_FIX/REGISTRY.yaml" /dev/null "strict-emit" \
    "$TMPDIR_FIX/scripts/coord/" <<'PYEOF'
import re, subprocess, sys, pathlib

registry_path, allowlist_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
prod_path = sys.argv[4]
yaml_text = pathlib.Path(registry_path).read_text()

registered = set(re.findall(r'^\s*-\s+kind:\s*([A-Za-z0-9_]+)', yaml_text, re.M))

def grep_lines(pattern, paths):
    existing = [p for p in paths if pathlib.Path(p).exists()]
    if not existing:
        return []
    proc = subprocess.run(['grep', '-rEnI', pattern, *existing],
                          capture_output=True, text=True)
    if proc.returncode > 1:
        return []
    return [ln for ln in proc.stdout.splitlines() if ln]

def extract_kinds(lines, kind_re):
    out = set()
    for line in lines:
        parts = line.split(':', 2)
        if len(parts) < 3:
            continue
        m = re.search(kind_re, parts[2])
        if m:
            out.add(m.group(1))
    return out

emitted = extract_kinds(
    grep_lines(r'"kind"\s*:\s*"[a-zA-Z0-9_]+"', [prod_path]),
    r'"kind"\s*:\s*"([a-zA-Z0-9_]+)"',
)

NOISE = {'X', 'kind', 'name', 'value', 'type', 'event', 'other', 'test'}
emitted -= NOISE

emit_without_register = sorted(emitted - registered)
print('\n'.join(emit_without_register) if emit_without_register else 'NONE')
sys.exit(1 if emit_without_register else 0)
PYEOF
)
rc=$?
if [[ $rc -eq 0 ]] && [[ "$result" == "NONE" ]]; then
    _pass "synthetic: registered+emitted kind produces no EMIT-NO-REG"
else
    _fail "synthetic: registered+emitted kind incorrectly flagged as EMIT-NO-REG (output='$result')"
fi

# ── Test 4: Synthetic fixture — emitted but NOT registered → EMIT-NO-REG ─────
echo ""
echo "Test 4: synthetic fixture — unregistered emit IS correctly flagged"
# Note: python3 exits 1 when violations found; use || true to prevent set -e from
# aborting the script so we can inspect the output and rc ourselves.
result2=$(python3 - "$TMPDIR_FIX/REGISTRY.yaml" /dev/null "strict-emit" \
    "$TMPDIR_FIX/scripts/coord/" <<'PYEOF'
import re, subprocess, sys, pathlib

registry_path, allowlist_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
prod_path = sys.argv[4]
# Use an EMPTY registry to ensure the kind is not registered.
yaml_text = "events:\n"

registered = set(re.findall(r'^\s*-\s+kind:\s*([A-Za-z0-9_]+)', yaml_text, re.M))

def grep_lines(pattern, paths):
    existing = [p for p in paths if pathlib.Path(p).exists()]
    if not existing:
        return []
    proc = subprocess.run(['grep', '-rEnI', pattern, *existing],
                          capture_output=True, text=True)
    if proc.returncode > 1:
        return []
    return [ln for ln in proc.stdout.splitlines() if ln]

def extract_kinds(lines, kind_re):
    out = set()
    for line in lines:
        parts = line.split(':', 2)
        if len(parts) < 3:
            continue
        m = re.search(kind_re, parts[2])
        if m:
            out.add(m.group(1))
    return out

emitted = extract_kinds(
    grep_lines(r'"kind"\s*:\s*"[a-zA-Z0-9_]+"', [prod_path]),
    r'"kind"\s*:\s*"([a-zA-Z0-9_]+)"',
)
NOISE = {'X', 'kind', 'name', 'value', 'type', 'event', 'other', 'test'}
emitted -= NOISE

emit_without_register = sorted(emitted - registered)
print('\n'.join(emit_without_register) if emit_without_register else 'NONE')
sys.exit(1 if emit_without_register else 0)
PYEOF
) || true   # rc=1 is the expected/correct outcome; capture it below
# Capture rc separately to avoid set -e interference above.
python3 - "$TMPDIR_FIX/REGISTRY.yaml" /dev/null "strict-emit" \
    "$TMPDIR_FIX/scripts/coord/" <<'PYEOF2' > /dev/null 2>&1 && rc2=0 || rc2=$?
import re, subprocess, sys, pathlib
registry_path, allowlist_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
prod_path = sys.argv[4]
yaml_text = "events:\n"
registered = set(re.findall(r'^\s*-\s+kind:\s*([A-Za-z0-9_]+)', yaml_text, re.M))
def grep_lines(pattern, paths):
    existing = [p for p in paths if pathlib.Path(p).exists()]
    if not existing: return []
    proc = subprocess.run(['grep', '-rEnI', pattern, *existing], capture_output=True, text=True)
    if proc.returncode > 1: return []
    return [ln for ln in proc.stdout.splitlines() if ln]
def extract_kinds(lines, kind_re):
    out = set()
    for line in lines:
        parts = line.split(':', 2)
        if len(parts) < 3: continue
        m = re.search(kind_re, parts[2])
        if m: out.add(m.group(1))
    return out
emitted = extract_kinds(grep_lines(r'"kind"\s*:\s*"[a-zA-Z0-9_]+"', [prod_path]), r'"kind"\s*:\s*"([a-zA-Z0-9_]+)"')
NOISE = {'X', 'kind', 'name', 'value', 'type', 'event', 'other', 'test'}
emitted -= NOISE
emit_without_register = sorted(emitted - registered)
sys.exit(1 if emit_without_register else 0)
PYEOF2
if [[ $rc2 -ne 0 ]] && echo "$result2" | grep -q "infra_2496_regression_sentinel"; then
    _pass "synthetic: unregistered kind is correctly flagged as EMIT-NO-REG"
else
    _fail "synthetic: unregistered kind was NOT flagged (false-negative) — audit is broken (rc=$rc2 result='$result2')"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "[registry-regression] Results: PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "[registry-regression] FAIL" >&2
    exit 1
fi
echo "[registry-regression] OK"
exit 0
