#!/usr/bin/env bash
# scripts/ci/test-inventory-agent-sync.sh — INFRA-2366 smoke test
#
# Verifies scripts/coord/inventory-agent-sync.sh AC#6:
#   1. One synthetic artifact mentioned in one doc and NOT in another.
#   2. Only the unmentioned slice surfaces (mentioned artifact excluded).
#   3. --json output is valid JSON.
#   4. --dry-run suppresses ambient events.
#   5. Exit code is 0 even when findings exist (advisory, not gate).
#
# Does NOT require a real chump binary — uses sqlite3 directly to seed
# a synthetic inventory.db with two artifacts.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/inventory-agent-sync.sh"

if [[ ! -x "$SCRIPT" ]]; then
    echo "[test-inventory-agent-sync] FAIL: $SCRIPT not executable" >&2
    exit 1
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Build a synthetic inventory DB ────────────────────────────────────────────

INVENTORY_DB="$TMPDIR_TEST/inventory.db"
AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl"

sqlite3 "$INVENTORY_DB" <<'SQL'
CREATE TABLE artifact_index (
    artifact_id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL UNIQUE,
    class TEXT NOT NULL,
    size_bytes INTEGER NOT NULL DEFAULT 0,
    first_seen_at INTEGER NOT NULL,
    last_modified_at INTEGER NOT NULL,
    activation_state TEXT NOT NULL,
    reference_count INTEGER NOT NULL DEFAULT 0,
    referenced_from TEXT,
    introducing_pr INTEGER,
    introducing_gap TEXT,
    notes TEXT,
    last_synced_at INTEGER NOT NULL
);
SQL

# Two artifacts introduced within last 30 days.
NOW="$(date +%s)"
RECENT=$(( NOW - 86400 ))   # yesterday

sqlite3 "$INVENTORY_DB" \
    "INSERT INTO artifact_index (path, class, size_bytes, first_seen_at, last_modified_at, activation_state, last_synced_at, introducing_pr, introducing_gap)
     VALUES ('scripts/coord/mentioned-tool.sh', 'shell-script', 100, $RECENT, $RECENT, 'referenced', $NOW, 999, 'INFRA-9001'),
            ('scripts/coord/unmentioned-tool.sh', 'shell-script', 100, $RECENT, $RECENT, 'dormant', $NOW, 998, 'INFRA-9002');"

# ── Build a synthetic doc tree ─────────────────────────────────────────────────

FAKE_DOCS="$TMPDIR_TEST/docs"
mkdir -p "$FAKE_DOCS/.claude/agents" "$FAKE_DOCS/docs/process"

# AGENTS.md mentions the first artifact (by basename).
cat > "$FAKE_DOCS/AGENTS.md" <<'MD'
# Agents
mentioned-tool.sh is a core tool used by all agents.
MD

# CLAUDE.md does NOT mention either artifact.
cat > "$FAKE_DOCS/CLAUDE.md" <<'MD'
# Claude
This file mentions nothing relevant.
MD

# A process doc also does not mention either.
cat > "$FAKE_DOCS/docs/process/workflow.md" <<'MD'
# Workflow
General workflow notes.
MD

# An agent doc also does not mention either.
cat > "$FAKE_DOCS/.claude/agents/quartermaster.md" <<'MD'
# Quartermaster
General quartermaster notes.
MD

# ── Run the script ─────────────────────────────────────────────────────────────

# We need to point the script at our synthetic paths.
# The script uses CHUMP_AGENT_SYNC_INVENTORY_DB, CHUMP_AGENT_SYNC_AMBIENT_LOG,
# and scans hardcoded paths relative to MAIN_REPO (resolved via git rev-parse).
# We can't easily override doc paths, but we CAN verify the DB+ambient behavior
# by pointing the script at a repo root that has our synthetic docs.
#
# Strategy: create a fake git repo, populate it with synthetic docs + inventory DB,
# then run the script from within it.

FAKE_REPO="$TMPDIR_TEST/fake-repo"
mkdir -p "$FAKE_REPO/.claude/agents" "$FAKE_REPO/docs/process" "$FAKE_REPO/.chump" "$FAKE_REPO/.chump-locks" "$FAKE_REPO/scripts/coord"

# Init git so git rev-parse works.
git -C "$FAKE_REPO" init --quiet
git -C "$FAKE_REPO" config user.email "test@chump.test"
git -C "$FAKE_REPO" config user.name "Test"

# Populate docs.
cp "$FAKE_DOCS/AGENTS.md" "$FAKE_REPO/AGENTS.md"
cp "$FAKE_DOCS/CLAUDE.md" "$FAKE_REPO/CLAUDE.md"
cp "$FAKE_DOCS/docs/process/workflow.md" "$FAKE_REPO/docs/process/workflow.md"
cp "$FAKE_DOCS/.claude/agents/quartermaster.md" "$FAKE_REPO/.claude/agents/quartermaster.md"

# Copy the inventory DB into .chump.
cp "$INVENTORY_DB" "$FAKE_REPO/.chump/inventory.db"

# Copy the script into a temporary location within the fake repo so it can resolve ROOT.
mkdir -p "$FAKE_REPO/scripts/coord"
cp "$SCRIPT" "$FAKE_REPO/scripts/coord/inventory-agent-sync.sh"
chmod +x "$FAKE_REPO/scripts/coord/inventory-agent-sync.sh"

# Initial commit so git rev-parse --show-toplevel works.
git -C "$FAKE_REPO" add -A
git -C "$FAKE_REPO" commit --quiet -m "test fixture"

FAKE_AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"

# ── Case 1: basic run (--dry-run) ─────────────────────────────────────────────

echo "[test-inventory-agent-sync] case 1: dry-run, expect 1 unmentioned artifact"

OUTPUT="$(
    cd "$FAKE_REPO"
    CHUMP_AGENT_SYNC_AMBIENT_LOG="$FAKE_AMBIENT" \
        bash scripts/coord/inventory-agent-sync.sh --dry-run 2>&1
)"
echo "  output: $OUTPUT"

# Expect exactly 1 unmentioned.
if ! echo "$OUTPUT" | grep -q "found 1 shipped-but-unmentioned artifacts"; then
    echo "[test-inventory-agent-sync] FAIL: expected '1 shipped-but-unmentioned' in output" >&2
    echo "  got: $OUTPUT" >&2
    exit 1
fi

# Dry-run: ambient log must NOT exist or be empty.
if [[ -f "$FAKE_AMBIENT" ]] && [[ -s "$FAKE_AMBIENT" ]]; then
    echo "[test-inventory-agent-sync] FAIL: ambient log was written in --dry-run mode" >&2
    exit 1
fi
echo "  PASS: 1 unmentioned, no ambient events (dry-run)"

# ── Case 2: --json output ──────────────────────────────────────────────────────

echo "[test-inventory-agent-sync] case 2: --json output is valid JSON"

JSON_OUTPUT="$(
    cd "$FAKE_REPO"
    CHUMP_AGENT_SYNC_AMBIENT_LOG="$FAKE_AMBIENT" \
        bash scripts/coord/inventory-agent-sync.sh --json --dry-run 2>/dev/null
    )"

if ! echo "$JSON_OUTPUT" | python3 -c "import json,sys; data=json.load(sys.stdin); assert len(data)==1, f'expected 1 finding, got {len(data)}'" 2>/dev/null; then
    echo "[test-inventory-agent-sync] FAIL: --json output invalid or wrong finding count" >&2
    echo "  got: $JSON_OUTPUT" >&2
    exit 1
fi
echo "  PASS: --json output is valid JSON with exactly 1 finding"

# ── Case 3: ambient events emitted when NOT in dry-run ───────────────────────

echo "[test-inventory-agent-sync] case 3: ambient events emitted (live mode)"

rm -f "$FAKE_AMBIENT"
(
    cd "$FAKE_REPO"
    CHUMP_AGENT_SYNC_AMBIENT_LOG="$FAKE_AMBIENT" \
        bash scripts/coord/inventory-agent-sync.sh >/dev/null 2>&1
)

if [[ ! -f "$FAKE_AMBIENT" ]]; then
    echo "[test-inventory-agent-sync] FAIL: ambient log not created in live mode" >&2
    exit 1
fi

FINDING_COUNT="$(grep -c '"kind":"inventory_agent_sync_finding"' "$FAKE_AMBIENT" 2>/dev/null || echo 0)"
RUN_COUNT="$(grep -c '"kind":"inventory_agent_sync_run"' "$FAKE_AMBIENT" 2>/dev/null || echo 0)"

if [[ "$FINDING_COUNT" -ne 1 ]]; then
    echo "[test-inventory-agent-sync] FAIL: expected 1 inventory_agent_sync_finding event, got $FINDING_COUNT" >&2
    exit 1
fi
if [[ "$RUN_COUNT" -ne 1 ]]; then
    echo "[test-inventory-agent-sync] FAIL: expected 1 inventory_agent_sync_run event, got $RUN_COUNT" >&2
    exit 1
fi
echo "  PASS: 1 finding event + 1 run summary event in ambient log"

# ── Case 4: exit code 0 even with findings ────────────────────────────────────

echo "[test-inventory-agent-sync] case 4: exit code 0 with findings (advisory, not gate)"

EXIT_CODE=0
(
    cd "$FAKE_REPO"
    CHUMP_AGENT_SYNC_AMBIENT_LOG="$FAKE_AMBIENT" \
        bash scripts/coord/inventory-agent-sync.sh >/dev/null 2>&1
) || EXIT_CODE=$?

if [[ "$EXIT_CODE" -ne 0 ]]; then
    echo "[test-inventory-agent-sync] FAIL: expected exit 0 with findings, got $EXIT_CODE" >&2
    exit 1
fi
echo "  PASS: exit code 0 even with findings"

# ── Case 5: --window-days 0 surfaces nothing ──────────────────────────────────

echo "[test-inventory-agent-sync] case 5: --window-days 0 finds nothing (too old)"

OUTPUT_ZERO="$(
    cd "$FAKE_REPO"
    CHUMP_AGENT_SYNC_AMBIENT_LOG="$FAKE_AMBIENT" \
        bash scripts/coord/inventory-agent-sync.sh --window-days 0 --dry-run 2>&1
)"
echo "  output: $OUTPUT_ZERO"

if ! echo "$OUTPUT_ZERO" | grep -q "found 0 shipped-but-unmentioned artifacts"; then
    echo "[test-inventory-agent-sync] FAIL: expected 0 findings with --window-days 0" >&2
    echo "  got: $OUTPUT_ZERO" >&2
    exit 1
fi
echo "  PASS: 0 findings with --window-days 0"

# ── All cases passed ──────────────────────────────────────────────────────────

echo "[test-inventory-agent-sync] ALL CASES PASSED"
exit 0
