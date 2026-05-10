#!/usr/bin/env bash
# test-feature-smoke-detects-silent-failure.sh — INFRA-396 CI gate.
#
# Verifies that run-feature-smokes.sh fires ALERT when --briefing is silently
# broken and passes when it returns valid structured output.
#
# Does NOT require a live LLM or real state.db — uses stub binaries that
# simulate the broken and working states described in the INFRA-396 AC.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SMOKE="$REPO_ROOT/scripts/ci/run-feature-smokes.sh"

[[ -f "$SMOKE" ]] || { echo "FAIL: run-feature-smokes.sh not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.chump-locks"
mkdir -p "$TMP/scripts/coord"

# Stub bot-merge.sh: outputs the two required stage labels in dry-run mode.
cat >"$TMP/scripts/coord/bot-merge.sh" <<'BOTMERGE'
#!/usr/bin/env bash
echo "[stage] git fetch origin/main"
echo "[stage] git push branch -> origin"
exit 0
BOTMERGE
chmod +x "$TMP/scripts/coord/bot-merge.sh"

# ── Test 1: broken --briefing (empty output, exit 0) → smoke must FAIL ────
cat >"$TMP/chump-broken" <<'STUB'
#!/usr/bin/env bash
# Simulates INFRA-188 failure mode: --briefing exits 0 but emits nothing.
if [[ "$*" == *"--briefing"* ]]; then
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/chump-broken"

touch "$TMP/.chump-locks/ambient.jsonl"
if REPO_ROOT="$TMP" CHUMP_BIN="$TMP/chump-broken" bash "$SMOKE" >/dev/null 2>&1; then
    echo "FAIL test-1: smoke should have exited non-zero for empty --briefing output"
    exit 1
fi
if ! grep -q "feature_silent_failure" "$TMP/.chump-locks/ambient.jsonl"; then
    echo "FAIL test-1: smoke did not emit ALERT kind=feature_silent_failure to ambient.jsonl"
    exit 1
fi
if ! grep -q "chump_briefing" "$TMP/.chump-locks/ambient.jsonl"; then
    echo "FAIL test-1: ALERT missing feature name 'chump_briefing'"
    exit 1
fi
echo "[OK] test-1: smoke detected broken --briefing (empty output) → ALERT emitted"

# ── Test 2: broken --briefing (missing Reflections section) → smoke must FAIL
cat >"$TMP/chump-partial" <<'STUB'
#!/usr/bin/env bash
# Simulates partial output (metadata present but Reflections section missing).
if [[ "$*" == *"--briefing"* ]]; then
    echo "# INFRA-396: Test gap"
    echo "## Acceptance Criteria"
    echo "- some AC"
    # Note: no "## Reflections" section
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/chump-partial"

> "$TMP/.chump-locks/ambient.jsonl"
if REPO_ROOT="$TMP" CHUMP_BIN="$TMP/chump-partial" bash "$SMOKE" >/dev/null 2>&1; then
    echo "FAIL test-2: smoke should have detected missing Reflections section"
    exit 1
fi
if ! grep -q "feature_silent_failure" "$TMP/.chump-locks/ambient.jsonl"; then
    echo "FAIL test-2: smoke did not emit ALERT for missing Reflections section"
    exit 1
fi
echo "[OK] test-2: smoke detected missing '## Reflections' section → ALERT emitted"

# ── Test 3: working --briefing → smoke must PASS ───────────────────────────
cat >"$TMP/chump-good" <<'STUB'
#!/usr/bin/env bash
# Simulates a healthy --briefing response with all required sections.
if [[ "$*" == *"--briefing"* ]]; then
    echo "# INFRA-396: Cascading silent-failure self-tests"
    echo ""
    echo "**Metadata**"
    echo "- Domain: INFRA"
    echo "- Priority: P1"
    echo ""
    echo "## Acceptance Criteria"
    echo ""
    echo "- Each load-bearing feature path gets a smoke."
    echo ""
    echo "## Reflections"
    echo ""
    echo "- lesson: always assert non-trivial output"
    echo ""
    echo "## Recent Activity"
    echo ""
    echo "- 18:00:00 gap claimed"
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/chump-good"

> "$TMP/.chump-locks/ambient.jsonl"
if ! REPO_ROOT="$TMP" CHUMP_BIN="$TMP/chump-good" bash "$SMOKE" >/dev/null 2>&1; then
    echo "FAIL test-3: smoke should have passed with valid structured output"
    exit 1
fi
if grep -q "feature_silent_failure" "$TMP/.chump-locks/ambient.jsonl"; then
    echo "FAIL test-3: smoke fired false-positive ALERT on valid output"
    exit 1
fi
echo "[OK] test-3: smoke passed with valid --briefing output (no ALERT)"

# ── Test 4: missing chump binary → smoke must exit 2 ─────────────────────
if REPO_ROOT="$TMP" CHUMP_BIN="/nonexistent/chump" bash "$SMOKE" >/dev/null 2>&1; then
    echo "FAIL test-4: smoke should exit non-zero when chump binary missing"
    exit 1
fi
echo "[OK] test-4: smoke correctly fails when chump binary is missing"

echo ""
echo "PASS: test-feature-smoke-detects-silent-failure (4/4 cases verified)"
