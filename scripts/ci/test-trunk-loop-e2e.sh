#!/usr/bin/env bash
# scripts/ci/test-trunk-loop-e2e.sh — INFRA-2337
#
# End-to-end smoke test for the trunk-health autonomous loop:
#   trunk-sentinel-daemon → fix-trunk-dispatcher → claude -p
#
# Exercises the full contract:
#   1. Sentinel detects RED, files a gap with skills_required=fix_trunk
#      backfilled via `chump gap set` (INFRA-2337: --skills-required is
#      silently dropped by `gap reserve`).
#   2. Sentinel emits trunk_red_persistent into ambient.
#   3. Dispatcher picks up trunk_red_persistent (regex match against the
#      grep pre-filter), finds the gap via SQL (skills_required LIKE
#      '%fix_trunk%'), claims it via stub `chump`, derives worktree
#      deterministically (INFRA-2337: lease JSON has no `worktree` field
#      per src/atomic_claim.rs:1680-1708), and spawns stub `claude -p`.
#   4. Dispatcher emits fix_trunk_dispatched with the claimed gap_id.
#   5. Recovery: GREEN fixture triggers trunk_recovered + closes the
#      filed gap via `chump gap set --status done`.
#
# All external dependencies (chump, claude, gh) are stubbed via PATH
# override so the test runs hermetically with no network and no real
# state-db writes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SENTINEL="$REPO_ROOT/scripts/coord/trunk-sentinel-daemon.sh"
DISPATCHER="$REPO_ROOT/scripts/dispatch/fix-trunk-dispatcher.sh"

[[ -x "$SENTINEL" ]] || { echo "[e2e] FAIL: sentinel not executable"; exit 1; }
[[ -x "$DISPATCHER" ]] || { echo "[e2e] FAIL: dispatcher not executable"; exit 1; }

# ── Isolated workdir ─────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d /tmp/trunk-loop-e2e-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

STUB_BIN="$WORK_DIR/bin"
STATE_DB="$WORK_DIR/state.db"
AMBIENT="$WORK_DIR/ambient.jsonl"
LOCK_DIR="$WORK_DIR/locks"
SENTINEL_STATE="$WORK_DIR/sentinel-state.json"
GREEN_FIXTURE="$WORK_DIR/run-green.json"
RED_FIXTURE="$WORK_DIR/run-red.json"
STUB_CHUMP_LOG="$WORK_DIR/chump.log"
STUB_CLAUDE_LOG="$WORK_DIR/claude.log"
FAKE_WORKTREE="$WORK_DIR/fake-wt"
DISPATCHER_LOCK="$LOCK_DIR/fix-trunk-dispatcher.lock"

mkdir -p "$STUB_BIN" "$LOCK_DIR" "$FAKE_WORKTREE"
: > "$AMBIENT"
: > "$STUB_CHUMP_LOG"
: > "$STUB_CLAUDE_LOG"

# ── Build fake state.db ───────────────────────────────────────────────────────
# Mirrors the canonical schema (sqlite3 .chump/state.db .schema gaps).
# We only need the columns the dispatcher's SQL references: id, status,
# skills_required, priority, opened_date.
sqlite3 "$STATE_DB" "
CREATE TABLE gaps (
    id TEXT PRIMARY KEY,
    domain TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT '',
    effort TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '',
    source_doc TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL DEFAULT 0,
    closed_at INTEGER,
    opened_date TEXT NOT NULL DEFAULT '',
    closed_date TEXT NOT NULL DEFAULT '',
    closed_pr INTEGER,
    skills_required TEXT NOT NULL DEFAULT '',
    preferred_backend TEXT NOT NULL DEFAULT '',
    preferred_machine TEXT NOT NULL DEFAULT '',
    estimated_minutes TEXT NOT NULL DEFAULT '',
    required_model TEXT NOT NULL DEFAULT '',
    shipped_in TEXT
);
INSERT INTO gaps (id, domain, title, priority, effort, status, opened_date,
    skills_required, acceptance_criteria)
VALUES ('INFRA-9999', 'INFRA',
    'RESILIENT: trunk red — main ci.yml failing on [test] (fp=e2etest123)',
    'P0', 's', 'open', '2026-05-31',
    'fix_trunk,ci_repair',
    '[\"CI passes\",\"main green for 1h\"]');
"

# ── Stub fixtures: sentinel mock run JSON ─────────────────────────────────────
cat > "$GREEN_FIXTURE" <<'EOF'
{"run_id":2001,"head_sha":"green123","conclusion":"success","status":"completed","created_at":"2026-05-31T00:00:00Z","html_url":"https://x","failing_jobs":""}
EOF

cat > "$RED_FIXTURE" <<'EOF'
{"run_id":2002,"head_sha":"red456","conclusion":"failure","status":"completed","created_at":"2026-05-31T00:05:00Z","html_url":"https://x","failing_jobs":"test,fast-checks"}
EOF

# ── Stub chump CLI ────────────────────────────────────────────────────────────
# Captures every invocation. Honors the contracts the daemons actually use:
#   chump claim <GAP-ID>       → writes a real claim-<id>-PID-EPOCH.json lease
#                                with the same schema as src/atomic_claim.rs
#                                write_basic_lease (NO worktree field!), and
#                                prints the standard "worktree : <path>" line
#                                so the dispatcher's fallback parser also has
#                                a source of truth.
#   chump gap set <id> ...     → updates STATE_DB via sqlite3 for the fields
#                                we actually care about (status, skills).
#   chump gap reserve ...      → no-op, returns INFRA-9999 (we pre-seeded it).
#   chump gap show ...         → no-op (dispatcher prompt mentions it but
#                                doesn't actually invoke it in the tick).
cat > "$STUB_BIN/chump" <<STUB
#!/usr/bin/env bash
echo "[stub-chump] \$*" >> "$STUB_CHUMP_LOG"
case "\$1" in
    claim)
        gap_id="\$2"
        gap_lower="\$(printf '%s' "\$gap_id" | tr '[:upper:]' '[:lower:]')"
        # Emit a deterministic lease file mirroring atomic_claim.rs:1680-1708.
        # Critical: NO worktree field — that is the bug we're testing for.
        session_id="claim-\${gap_lower}-99999-\$(date +%s)"
        lease_file="$LOCK_DIR/\${session_id}.json"
        cat > "\$lease_file" <<LEASE
{
  "session_id": "\$session_id",
  "paths": [],
  "taken_at": "\$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "expires_at": "\$(date -u -v+4H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+4 hours' +%Y-%m-%dT%H:%M:%SZ)",
  "heartbeat_at": "\$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "purpose": "gap:\$gap_id",
  "gap_id": "\$gap_id"
}
LEASE
        # Print the standard claim output (the fallback parser reads this).
        printf '%s\n' "✓ claimed \$gap_id atomically (stub)"
        printf '    worktree : %s\n' "$FAKE_WORKTREE"
        printf '    branch   : chump/\${gap_lower}-claim\n'
        printf '    session  : \$session_id\n'
        exit 0
        ;;
    gap)
        sub="\$2"
        if [[ "\$sub" == "set" ]]; then
            gap_id="\$3"
            shift 3
            # Walk remaining args; handle --skills-required, --description, --status.
            while [[ \$# -gt 0 ]]; do
                case "\$1" in
                    --skills-required)
                        sqlite3 "$STATE_DB" "UPDATE gaps SET skills_required='\$2' WHERE id='\$gap_id';"
                        shift 2
                        ;;
                    --description)
                        # SQL-escape: replace ' with ''. Keep it simple for the stub.
                        esc="\${2//\\'/\\'\\'}"
                        sqlite3 "$STATE_DB" "UPDATE gaps SET description='\$esc' WHERE id='\$gap_id';"
                        shift 2
                        ;;
                    --status)
                        sqlite3 "$STATE_DB" "UPDATE gaps SET status='\$2' WHERE id='\$gap_id';"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            echo "updated \$gap_id"
            exit 0
        fi
        if [[ "\$sub" == "reserve" ]]; then
            # No-op: pre-seeded gap INFRA-9999 already exists.
            echo "INFRA-9999"
            exit 0
        fi
        # Anything else is fine to no-op.
        exit 0
        ;;
    *)
        # No-op for any other subcommand the dispatcher prompt mentions but
        # doesn't actually run in a tick.
        exit 0
        ;;
esac
STUB
chmod +x "$STUB_BIN/chump"

# ── Stub claude -p ────────────────────────────────────────────────────────────
# Captures full argv so the test can assert the gap ID was injected.
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "[stub-claude] argc=$#" >> "STUB_CLAUDE_LOG_REPLACED"
for arg in "$@"; do
    echo "[stub-claude] arg: $arg" >> "STUB_CLAUDE_LOG_REPLACED"
done
# Dispatcher invokes:
#   claude -p "$prompt" --model "$MODEL" --dangerously-skip-permissions
# The prompt is the second positional arg. Spit it to the log for inspection.
exit 0
STUB
sed -i.bak "s|STUB_CLAUDE_LOG_REPLACED|$STUB_CLAUDE_LOG|g" "$STUB_BIN/claude" && rm -f "$STUB_BIN/claude.bak"
chmod +x "$STUB_BIN/claude"

# ── Make the fake worktree look like a git checkout enough that `cd` works ────
# (Dispatcher does `cd "$worktree"` before `exec claude -p`. We don't need
# a real git tree because stub-claude doesn't care.)
mkdir -p "$FAKE_WORKTREE/.chump"

# ── Phase 1: Sentinel detects RED, files gap (DRY_RUN to skip real chump) ────
echo "[e2e] Phase 1: sentinel RED tick"
# Use DRY_RUN=1 so the sentinel emits ambient events without writing to real
# state.db (we control the gap row via our stub directly). The test asserts
# the EMITTED events match the contract the dispatcher reads.
CHUMP_TRUNK_SENTINEL_DRY_RUN=1 \
CHUMP_AMBIENT_PATH="$AMBIENT" \
CHUMP_TRUNK_SENTINEL_STATE_FILE="$SENTINEL_STATE" \
CHUMP_TRUNK_SENTINEL_RED_FILE_S=0 \
CHUMP_TRUNK_SENTINEL_RED_DISPATCH_S=99999 \
CHUMP_TRUNK_SENTINEL_RED_RECALL_S=99999 \
CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON="$RED_FIXTURE" \
    PATH="$STUB_BIN:$PATH" \
    "$SENTINEL" tick 2>/dev/null \
    || { echo "[e2e] FAIL: sentinel RED tick non-zero"; exit 1; }

grep -q '"kind":"trunk_red_persistent"' "$AMBIENT" \
    || { echo "[e2e] FAIL: no trunk_red_persistent emitted"; cat "$AMBIENT"; exit 1; }
echo "[e2e] (1) sentinel emitted trunk_red_persistent: OK"

# ── Phase 2: Dispatcher tick — pick up the trunk_red signal, claim, dispatch ─
echo "[e2e] Phase 2: dispatcher tick"
CHUMP_FIX_TRUNK_AMBIENT_FILE="$AMBIENT" \
CHUMP_FIX_TRUNK_LOCK_FILE="$DISPATCHER_LOCK" \
CHUMP_FIX_TRUNK_STATE_DB="$STATE_DB" \
CHUMP_FIX_TRUNK_MODEL="sonnet" \
CHUMP_FIX_TRUNK_TRUNK_RED_LOOKBACK_M=30 \
CHUMP_WORKTREE_BASE="$WORK_DIR" \
    PATH="$STUB_BIN:$PATH" \
    "$DISPATCHER" 2>"$WORK_DIR/dispatcher.err" \
    || { echo "[e2e] FAIL: dispatcher non-zero"; cat "$WORK_DIR/dispatcher.err"; exit 1; }

# Assert: dispatcher emitted fix_trunk_dispatched.
grep -q '"kind":"fix_trunk_dispatched"' "$AMBIENT" \
    || { echo "[e2e] FAIL: no fix_trunk_dispatched emitted"; \
         echo "--- ambient.jsonl ---"; cat "$AMBIENT"; \
         echo "--- dispatcher.err ---"; cat "$WORK_DIR/dispatcher.err"; \
         echo "--- chump.log ---"; cat "$STUB_CHUMP_LOG"; \
         exit 1; }
echo "[e2e] (2) dispatcher emitted fix_trunk_dispatched: OK"

# Assert: stub chump was called with `claim INFRA-9999`.
grep -q "claim INFRA-9999" "$STUB_CHUMP_LOG" \
    || { echo "[e2e] FAIL: chump claim INFRA-9999 not invoked"; cat "$STUB_CHUMP_LOG"; exit 1; }
echo "[e2e] (3) stub chump invoked with claim INFRA-9999: OK"

# The dispatcher backgrounds `claude -p` via `(...)&` so the test must wait for
# the subshell to write the stub claude log before asserting. Bounded polling
# avoids race flakes: 5s should be plenty for a stub that exits immediately.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q "INFRA-9999" "$STUB_CLAUDE_LOG" 2>/dev/null; then
        break
    fi
    sleep 0.5
done

# Assert: stub claude was invoked with the gap id in the prompt body.
grep -q "INFRA-9999" "$STUB_CLAUDE_LOG" \
    || { echo "[e2e] FAIL: stub claude not invoked with INFRA-9999 in prompt"; \
         echo "--- claude.log ---"; cat "$STUB_CLAUDE_LOG"; \
         exit 1; }
echo "[e2e] (4) stub claude invoked with INFRA-9999 in prompt: OK"

# Assert: dispatcher lockfile was written with PID + gap_id.
[[ -f "$DISPATCHER_LOCK" ]] \
    || { echo "[e2e] FAIL: dispatcher lockfile not written"; exit 1; }
lock_gap="$(python3 -c "import json; print(json.load(open('$DISPATCHER_LOCK'))['gap_id'])")"
[[ "$lock_gap" == "INFRA-9999" ]] \
    || { echo "[e2e] FAIL: dispatcher lockfile has wrong gap_id ($lock_gap)"; exit 1; }
echo "[e2e] (5) dispatcher lockfile records gap_id=INFRA-9999: OK"

# Assert: dispatcher resolved worktree (no "worktree path not resolved" error).
if grep -q "worktree path not resolved" "$WORK_DIR/dispatcher.err"; then
    echo "[e2e] FAIL: dispatcher logged 'worktree path not resolved' — fix regressed"
    cat "$WORK_DIR/dispatcher.err"
    exit 1
fi
echo "[e2e] (6) dispatcher resolved worktree: OK"

# ── Phase 3: Idempotency — re-run dispatcher tick should skip (parallelism cap) ─
echo "[e2e] Phase 3: dispatcher re-tick should skip via lockfile"
# The stub claude exited immediately, so the recorded PID is dead. Per the
# dispatcher's kill -0 check this reclaims the lockfile. But the gap status
# is still 'open' (stub claude didn't ship), so it WILL re-claim and re-dispatch.
# To test the parallelism cap we need a live PID. Easiest path: write a fake
# lockfile pointing at the test runner's own PID (always alive).
echo "{\"pid\":$$,\"gap_id\":\"INFRA-9999\",\"started_at\":\"2026-05-31T23:00:00Z\"}" > "$DISPATCHER_LOCK"
prev_lines=$(wc -l < "$AMBIENT")
CHUMP_FIX_TRUNK_AMBIENT_FILE="$AMBIENT" \
CHUMP_FIX_TRUNK_LOCK_FILE="$DISPATCHER_LOCK" \
CHUMP_FIX_TRUNK_STATE_DB="$STATE_DB" \
CHUMP_FIX_TRUNK_TRUNK_RED_LOOKBACK_M=30 \
CHUMP_WORKTREE_BASE="$WORK_DIR" \
    PATH="$STUB_BIN:$PATH" \
    "$DISPATCHER" 2>/dev/null \
    || { echo "[e2e] FAIL: dispatcher idempotent tick non-zero"; exit 1; }
new_lines=$(tail -n +"$((prev_lines + 1))" "$AMBIENT")
echo "$new_lines" | grep -q '"kind":"fix_trunk_skipped"' \
    || { echo "[e2e] FAIL: dispatcher did not emit fix_trunk_skipped on re-tick with live prior"; \
         echo "--- new lines ---"; echo "$new_lines"; exit 1; }
echo "[e2e] (7) dispatcher skipped due to live prior PID: OK"

# Clear the lockfile so phase-4 recovery can run cleanly.
rm -f "$DISPATCHER_LOCK"

# ── Phase 4: Recovery — sentinel GREEN tick closes the filed gap ──────────────
echo "[e2e] Phase 4: sentinel recovery RED→GREEN"
# For recovery to fire, the sentinel state file must list the gap in
# filed_gaps[]. The DRY_RUN reserve writes INFRA-DRYRUN-<fp> as the gap id
# (sentinel line 248). So the recovery path would try to close that fake
# id and skip it (line 467: continue on INFRA-DRYRUN-*). To exercise the
# real close, manually pre-seed the state file with the real gap id we
# pre-loaded into STATE_DB.
python3 -c "
import json
s = json.load(open('$SENTINEL_STATE'))
s['filed_gaps'] = ['INFRA-9999']
json.dump(s, open('$SENTINEL_STATE', 'w'))
"

# DRY_RUN=0 so the real `chump gap set --status done` stub runs.
prev_lines=$(wc -l < "$AMBIENT")
CHUMP_AMBIENT_PATH="$AMBIENT" \
CHUMP_TRUNK_SENTINEL_STATE_FILE="$SENTINEL_STATE" \
CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON="$GREEN_FIXTURE" \
    PATH="$STUB_BIN:$PATH" \
    "$SENTINEL" tick 2>/dev/null \
    || { echo "[e2e] FAIL: sentinel GREEN tick non-zero"; exit 1; }
new_lines=$(tail -n +"$((prev_lines + 1))" "$AMBIENT")
echo "$new_lines" | grep -q '"kind":"trunk_recovered"' \
    || { echo "[e2e] FAIL: no trunk_recovered emitted on RED→GREEN"; \
         echo "--- new lines ---"; echo "$new_lines"; \
         exit 1; }
echo "[e2e] (8) sentinel emitted trunk_recovered: OK"

# Assert: stub chump gap set was called to close INFRA-9999.
grep -q "gap set INFRA-9999 --status done" "$STUB_CHUMP_LOG" \
    || { echo "[e2e] FAIL: chump gap set INFRA-9999 --status done not invoked"; \
         echo "--- chump.log ---"; cat "$STUB_CHUMP_LOG"; \
         exit 1; }
echo "[e2e] (9) chump gap set INFRA-9999 --status done invoked: OK"

# Assert: gap row now status=done in STATE_DB.
row_status="$(sqlite3 "$STATE_DB" "SELECT status FROM gaps WHERE id='INFRA-9999';")"
[[ "$row_status" == "done" ]] \
    || { echo "[e2e] FAIL: INFRA-9999 status=$row_status, expected 'done'"; exit 1; }
echo "[e2e] (10) INFRA-9999 row updated to status=done: OK"

echo "[test-trunk-loop-e2e] PASS"
