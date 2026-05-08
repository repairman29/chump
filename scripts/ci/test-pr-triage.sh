#!/usr/bin/env bash
# test-pr-triage.sh — INFRA-605 smoke test.
#
# Verifies `chump pr triage` against 4 fixture PR states:
#   1. clean   — all checks SUCCESS
#   2. dirty   — mergeStateStatus BEHIND
#   3. failing (flake) — FAILURE on a test-* check name
#   4. auto-merge-armed — autoMergeRequest set
#
# Uses CHUMP_GH env var to inject a mock gh binary.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || git -C "$(dirname "$0")" rev-parse --show-toplevel)"

# Resolve binary — worktrees share target-dir with main repo via .cargo/config.toml.
CHUMP="${REPO_ROOT}/target/debug/chump"
if [[ ! -f "$CHUMP" ]]; then
    CHUMP="${REPO_ROOT}/target/release/chump"
fi
if [[ ! -f "$CHUMP" ]]; then
    # Shared target-dir: read from .cargo/config.toml if present.
    _CARGO_CFG="${REPO_ROOT}/.cargo/config.toml"
    if [[ -f "$_CARGO_CFG" ]]; then
        _SHARED=$(grep '^target-dir' "$_CARGO_CFG" | sed 's/.*"\(.*\)".*/\1/')
        [[ -f "${_SHARED}/debug/chump" ]] && CHUMP="${_SHARED}/debug/chump"
        [[ ! -f "$CHUMP" && -f "${_SHARED}/release/chump" ]] && CHUMP="${_SHARED}/release/chump"
    fi
fi
if [[ ! -f "$CHUMP" ]]; then
    echo "[SKIP] chump binary not found — run 'cargo build' first"
    exit 0
fi

# ── Mock gh ───────────────────────────────────────────────────────────────────
MOCK_GH_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_GH_DIR"' EXIT

cat > "$MOCK_GH_DIR/gh" <<'SH'
#!/usr/bin/env bash
# Mock gh for pr triage tests.
# Responds to: gh pr list --state open --json ...
# All other invocations exit 0 silently.
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
    cat <<'JSON'
[
  {
    "number": 101,
    "title": "Clean PR",
    "headRefName": "feat-clean",
    "isDraft": false,
    "autoMergeRequest": null,
    "mergeStateStatus": "CLEAN",
    "statusCheckRollup": [
      {
        "name": "ci-summary",
        "state": "SUCCESS",
        "conclusion": "SUCCESS",
        "startedAt": "2026-05-08T10:00:00Z",
        "completedAt": "2026-05-08T10:10:00Z",
        "databaseId": 111
      }
    ]
  },
  {
    "number": 102,
    "title": "Dirty PR needs rebase",
    "headRefName": "feat-dirty",
    "isDraft": false,
    "autoMergeRequest": null,
    "mergeStateStatus": "BEHIND",
    "statusCheckRollup": []
  },
  {
    "number": 103,
    "title": "Failing PR with flaky test",
    "headRefName": "feat-flaky",
    "isDraft": false,
    "autoMergeRequest": null,
    "mergeStateStatus": "BLOCKED",
    "statusCheckRollup": [
      {
        "name": "test-cargo-unit",
        "state": "FAILURE",
        "conclusion": "FAILURE",
        "startedAt": "2026-05-08T09:00:00Z",
        "completedAt": "2026-05-08T09:05:00Z",
        "databaseId": 333
      }
    ]
  },
  {
    "number": 104,
    "title": "Auto-merge armed PR",
    "headRefName": "feat-armed",
    "isDraft": false,
    "autoMergeRequest": {"mergeMethod": "SQUASH"},
    "mergeStateStatus": "CLEAN",
    "statusCheckRollup": []
  }
]
JSON
    exit 0
fi
# gh run rerun, gh pr update-branch — succeed silently
exit 0
SH
chmod +x "$MOCK_GH_DIR/gh"

run_triage() {
    CHUMP_GH="$MOCK_GH_DIR/gh" "$CHUMP" pr triage "$@" 2>/dev/null
}

# ── Test 1: text output contains all 4 PR states ─────────────────────────────
echo "=== Test 1: text output — 4 fixture states ==="
out=$(run_triage)
echo "$out"

echo "$out" | grep -q "101" || { echo "[FAIL] Test 1: PR #101 not in output"; exit 1; }
echo "$out" | grep -q "clean" || { echo "[FAIL] Test 1: 'clean' classification missing"; exit 1; }
echo "$out" | grep -q "102" || { echo "[FAIL] Test 1: PR #102 not in output"; exit 1; }
echo "$out" | grep -q "dirty" || { echo "[FAIL] Test 1: 'dirty' classification missing"; exit 1; }
echo "$out" | grep -q "103" || { echo "[FAIL] Test 1: PR #103 not in output"; exit 1; }
echo "$out" | grep -q "failing" || { echo "[FAIL] Test 1: 'failing' classification missing"; exit 1; }
echo "$out" | grep -qi "flake" || { echo "[FAIL] Test 1: flake tag missing for PR #103"; exit 1; }
echo "$out" | grep -q "104" || { echo "[FAIL] Test 1: PR #104 not in output"; exit 1; }
echo "$out" | grep -q "auto-merge" || { echo "[FAIL] Test 1: 'auto-merge-armed' classification missing"; exit 1; }
echo "[PASS] Test 1: text output contains all 4 states"

# ── Test 2: --json output is valid JSON array ─────────────────────────────────
echo ""
echo "=== Test 2: --json output ==="
json=$(run_triage --json)
echo "$json"
echo "$json" | grep -q '"class":"clean"' || { echo "[FAIL] Test 2: clean class not in JSON"; exit 1; }
echo "$json" | grep -q '"class":"dirty"' || { echo "[FAIL] Test 2: dirty class not in JSON"; exit 1; }
echo "$json" | grep -q '"class":"failing"' || { echo "[FAIL] Test 2: failing class not in JSON"; exit 1; }
echo "$json" | grep -q '"class":"auto-merge-armed"' || { echo "[FAIL] Test 2: auto-merge-armed class not in JSON"; exit 1; }
echo "$json" | grep -q '"flake_detected":true' || { echo "[FAIL] Test 2: flake_detected not set in JSON"; exit 1; }
echo "[PASS] Test 2: --json output is correct"

# ── Test 3: --rerun-flakes exits 0 (mock gh accepts the call) ─────────────────
echo ""
echo "=== Test 3: --rerun-flakes exits 0 ==="
CHUMP_GH="$MOCK_GH_DIR/gh" "$CHUMP" pr triage --rerun-flakes 2>/dev/null
echo "[PASS] Test 3: --rerun-flakes exited 0"

# ── Test 4: --rebase-dirty exits 0 ───────────────────────────────────────────
echo ""
echo "=== Test 4: --rebase-dirty exits 0 ==="
CHUMP_GH="$MOCK_GH_DIR/gh" "$CHUMP" pr triage --rebase-dirty 2>/dev/null
echo "[PASS] Test 4: --rebase-dirty exited 0"

echo ""
echo "[OK] All INFRA-605 pr triage smoke tests passed"
