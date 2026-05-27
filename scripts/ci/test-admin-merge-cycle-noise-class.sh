#!/usr/bin/env bash
# scripts/ci/test-admin-merge-cycle-noise-class.sh — RESILIENT-031
#
# Smoke test for admin-merge-cycle.sh noise-class discipline gate.
# 4 test cases:
#   T1: --noise-class audit-orphan-pre-existing + audit check fails → PROCEED
#   T2: --noise-class audit-orphan-pre-existing + different check fails → REFUSE
#   T3: --force-admin --reason "operator emergency" → PROCEED + emits admin_merge_forced
#   T4: --noise-class for expired class → REFUSE with explanation
#
# Usage: bash scripts/ci/test-admin-merge-cycle-noise-class.sh
# Exit:  0 = all 4 pass; 1 = one or more failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/admin-merge-cycle.sh"
NOISE_CLASSES="$REPO_ROOT/scripts/ops/known-noise-classes.yaml"

pass=0
fail=0

ok()  { printf '[PASS] %s\n' "$*"; (( pass++ )) || true; }
nok() { printf '[FAIL] %s\n' "$*"; (( fail++ )) || true; }

# ── Test fixtures ─────────────────────────────────────────────────────────────

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Ambient log for capturing emitted events
AMBIENT_TEST="$TMPDIR_TEST/ambient.jsonl"
touch "$AMBIENT_TEST"

# Minimal ruleset snapshot JSONs (script checks these files exist before the cycle)
SNAPSHOT_DIR="$TMPDIR_TEST/ruleset-snapshots"
mkdir -p "$SNAPSHOT_DIR"
printf '{"name":"test-ruleset","rules":[]}\n'                              > "$SNAPSHOT_DIR/drop.json"
printf '{"name":"test-ruleset","rules":[{"type":"required_status_checks"}]}\n' > "$SNAPSHOT_DIR/restore.json"

# ── Mock gh binary ────────────────────────────────────────────────────────────
# Interprets: repo view, pr checks, pr merge, api PUT.
# Failing check name is injected via MOCK_FAILING_CHECK env variable.
# Output format mirrors real `gh pr checks`: "<name>\t<status>\t<url>"

MOCK_GH="$TMPDIR_TEST/mock-gh"
cat > "$MOCK_GH" <<'MOCK'
#!/usr/bin/env bash
MOCK_FAILING="${MOCK_FAILING_CHECK:-audit}"
case "${1:-}" in
    repo)
        echo "test-owner/test-repo"
        ;;
    pr)
        case "${2:-}" in
            checks)
                printf '%s\tFAILURE\t\n' "$MOCK_FAILING"
                printf 'some-passing-check\tSUCCESS\t\n'
                ;;
            merge)
                echo "merged PR" >&2
                exit 0
                ;;
        esac
        ;;
    api)
        exit 0
        ;;
    *)
        echo "mock-gh: unhandled: $*" >&2
        exit 1
        ;;
esac
MOCK
chmod +x "$MOCK_GH"

# ── Noise classes fixture for T4 (expired class) ──────────────────────────────
EXPIRED_CLASSES="$TMPDIR_TEST/expired-noise-classes.yaml"
cat > "$EXPIRED_CLASSES" <<'YAML'
classes:
  - id: expired-class
    description: "Test expired class — upstream fix is done"
    matches:
      - "some-check"
    pattern: ""
    upstream_fix_gap: RESILIENT-DONE-GAP
    expires_after_ship: true
YAML

# ── Build a patched copy of the script pointing at our test SCRIPT_DIR ───────
# admin-merge-cycle.sh derives SNAPSHOT_DIR from its own $(dirname $0), so we
# copy the script to our tmp dir (which has the ruleset-snapshots/ subdir).
SCRIPT_COPY="$TMPDIR_TEST/admin-merge-cycle.sh"
cp "$SCRIPT" "$SCRIPT_COPY"
# Patch the SCRIPT_DIR derivation to point at TMPDIR_TEST
sed -i.bak "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|SCRIPT_DIR=\"$TMPDIR_TEST\"|g" "$SCRIPT_COPY"
chmod +x "$SCRIPT_COPY"

# ── Common env exported for all tests ────────────────────────────────────────
export CHUMP_AMBIENT_LOG="$AMBIENT_TEST"
export CHUMP_ADMIN_MERGE_TEST_GH="$MOCK_GH"
export CHUMP_NOISE_CLASSES_FILE="$NOISE_CLASSES"
export CHUMP_ADMIN_MERGE_REPO="test-owner/test-repo"
# Inject INFRA-2044 as still open so audit-orphan-pre-existing class is active
export CHUMP_ADMIN_MERGE_TEST_GAP_STATUS="INFRA-2044:open"

echo "=== admin-merge-cycle noise-class smoke tests ==="
echo ""

# ── T1: noise-class matches failing check → PROCEED ──────────────────────────
# Failing check "audit-required" matches "audit" substring in audit-orphan-pre-existing.
echo "--- T1: noise-class match → PROCEED ---"
t1_out="$(MOCK_FAILING_CHECK="audit-required" \
    bash "$SCRIPT_COPY" --pr 9999 --noise-class audit-orphan-pre-existing --dry-run 2>&1)"
if echo "$t1_out" | grep -q "MATCH"; then
    ok "T1: noise-class match proceeds — saw MATCH line"
else
    nok "T1: expected MATCH in output; got: $(echo "$t1_out" | head -5)"
fi

if MOCK_FAILING_CHECK="audit-required" \
    bash "$SCRIPT_COPY" --pr 9999 --noise-class audit-orphan-pre-existing --dry-run >/dev/null 2>&1; then
    ok "T1: exit code 0 on match"
else
    nok "T1: exit code should be 0 on match"
fi

# ── T2: noise-class does NOT match failing check → REFUSE ────────────────────
# "totally-unrelated-check" shares no substring/pattern with the audit class.
echo "--- T2: noise-class mismatch → REFUSE ---"
t2_out="$(MOCK_FAILING_CHECK="totally-unrelated-check" \
    bash "$SCRIPT_COPY" --pr 9999 --noise-class audit-orphan-pre-existing --dry-run 2>&1)"
if echo "$t2_out" | grep -q "REFUSE"; then
    ok "T2: mismatch refuses — saw REFUSE line"
else
    nok "T2: expected REFUSE in output; got: $(echo "$t2_out" | head -5)"
fi

if MOCK_FAILING_CHECK="totally-unrelated-check" \
    bash "$SCRIPT_COPY" --pr 9999 --noise-class audit-orphan-pre-existing --dry-run >/dev/null 2>&1; then
    nok "T2: exit code should be non-zero on mismatch"
else
    ok "T2: exit code non-zero on mismatch"
fi

# ── T3: --force-admin --reason → PROCEED + emits admin_merge_forced ───────────
echo "--- T3: --force-admin --reason → PROCEED + emit admin_merge_forced ---"

# dry-run: must print FORCE-ADMIN line
t3_dry="$(MOCK_FAILING_CHECK="some-check" \
    bash "$SCRIPT_COPY" --pr 9999 --force-admin --reason "operator emergency T3" --dry-run 2>&1)"
if echo "$t3_dry" | grep -q "FORCE-ADMIN"; then
    ok "T3: force-admin dry-run shows FORCE-ADMIN line"
else
    nok "T3: expected FORCE-ADMIN in dry-run output; got: $(echo "$t3_dry" | head -5)"
fi

# real run (no --dry-run): must emit kind=admin_merge_forced
true > "$AMBIENT_TEST"
MOCK_FAILING_CHECK="some-check" \
    bash "$SCRIPT_COPY" --pr 9999 --force-admin --reason "T3 real-emit test" 2>/dev/null || true
if grep -q "admin_merge_forced" "$AMBIENT_TEST"; then
    ok "T3: admin_merge_forced emitted to ambient.jsonl"
else
    nok "T3: admin_merge_forced not found in ambient.jsonl (contents: $(cat "$AMBIENT_TEST"))"
fi

# ── T4: expired noise class → REFUSE with explanation ─────────────────────────
echo "--- T4: expired noise class → REFUSE ---"
t4_out="$(CHUMP_NOISE_CLASSES_FILE="$EXPIRED_CLASSES" \
CHUMP_ADMIN_MERGE_TEST_GAP_STATUS="RESILIENT-DONE-GAP:done" \
MOCK_FAILING_CHECK="some-check" \
    bash "$SCRIPT_COPY" --pr 9999 --noise-class expired-class --dry-run 2>&1)"
if echo "$t4_out" | grep -qE "REFUSE|EXPIRED"; then
    ok "T4: expired class refuses — saw REFUSE/EXPIRED line"
else
    nok "T4: expected REFUSE or EXPIRED in output; got: $(echo "$t4_out" | head -5)"
fi

if CHUMP_NOISE_CLASSES_FILE="$EXPIRED_CLASSES" \
CHUMP_ADMIN_MERGE_TEST_GAP_STATUS="RESILIENT-DONE-GAP:done" \
MOCK_FAILING_CHECK="some-check" \
    bash "$SCRIPT_COPY" --pr 9999 --noise-class expired-class --dry-run >/dev/null 2>&1; then
    nok "T4: exit code should be non-zero for expired class"
else
    ok "T4: exit code non-zero for expired class"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
