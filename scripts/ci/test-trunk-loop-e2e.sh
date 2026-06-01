#!/usr/bin/env bash
# scripts/ci/test-trunk-loop-e2e.sh — INFRA-2337 + INFRA-2341
#
# End-to-end smoke test for the trunk-health autonomous loop:
#   trunk-sentinel-daemon → fix-trunk-dispatcher → {signal|subprocess}
#
# Exercises the full contract for BOTH dispatch modes (INFRA-2341):
#   1. Sentinel detects RED, files a gap with skills_required=fix_trunk
#      backfilled via `chump gap set` (INFRA-2337: --skills-required is
#      silently dropped by `gap reserve`).
#   2. Sentinel emits trunk_red_persistent into ambient.
#   3. Dispatcher (signal mode, default):
#      - finds the gap, claims it via stub `chump`, derives worktree
#        deterministically (INFRA-2337: lease JSON has no `worktree`
#        field per src/atomic_claim.rs:1680-1708)
#      - writes a CRIT entry with kind=fix_trunk_priority_signal into the
#        URGENT-INBOX
#      - emits ambient kind=fix_trunk_priority_signal
#      - DOES NOT spawn claude -p
#      - inbox-check-urgent.sh surfaces the signal as a system-reminder
#        and emits kind=fix_trunk_session_acknowledged on cursor advance.
#   4. Dispatcher (subprocess mode, opt-in CHUMP_FIX_TRUNK_DISPATCH_MODE=subprocess):
#      - same claim + worktree resolution
#      - spawns stub `claude -p` with the gap_id in the prompt body
#      - emits ambient kind=fix_trunk_dispatched
#   5. Idempotency lockfile works in both modes.
#   6. Recovery: GREEN fixture triggers trunk_recovered + closes the
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
# INFRA-2341 — signal-mode fixtures (URGENT-INBOX + cursor + inbox-check-urgent)
URGENT_INBOX="$LOCK_DIR/URGENT-INBOX.jsonl"
URGENT_INBOX_CURSOR="$LOCK_DIR/URGENT-INBOX.cursor"
INBOX_CHECK="$REPO_ROOT/scripts/coord/inbox-check-urgent.sh"
[[ -x "$INBOX_CHECK" ]] || { echo "[e2e] FAIL: inbox-check-urgent.sh not executable"; exit 1; }

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

# ── Phase 2: Dispatcher tick (signal mode, INFRA-2341 default) ────────────────
echo "[e2e] Phase 2: dispatcher tick (signal mode = INFRA-2341 default)"
# INFRA-2341: with no CHUMP_FIX_TRUNK_DISPATCH_MODE set, the dispatcher
# defaults to signal mode — it should NOT spawn claude -p, but it MUST
# write a CRIT entry to URGENT-INBOX.jsonl + emit fix_trunk_priority_signal.
CHUMP_FIX_TRUNK_AMBIENT_FILE="$AMBIENT" \
CHUMP_FIX_TRUNK_LOCK_FILE="$DISPATCHER_LOCK" \
CHUMP_FIX_TRUNK_STATE_DB="$STATE_DB" \
CHUMP_FIX_TRUNK_MODEL="sonnet" \
CHUMP_FIX_TRUNK_TRUNK_RED_LOOKBACK_M=30 \
CHUMP_FIX_TRUNK_URGENT_INBOX="$URGENT_INBOX" \
CHUMP_WORKTREE_BASE="$WORK_DIR" \
    PATH="$STUB_BIN:$PATH" \
    "$DISPATCHER" 2>"$WORK_DIR/dispatcher.err" \
    || { echo "[e2e] FAIL: dispatcher (signal) non-zero"; cat "$WORK_DIR/dispatcher.err"; exit 1; }

# Assert: dispatcher emitted fix_trunk_priority_signal (signal mode).
grep -q '"kind":"fix_trunk_priority_signal"' "$AMBIENT" \
    || { echo "[e2e] FAIL: no fix_trunk_priority_signal emitted"; \
         echo "--- ambient.jsonl ---"; cat "$AMBIENT"; \
         echo "--- dispatcher.err ---"; cat "$WORK_DIR/dispatcher.err"; \
         exit 1; }
echo "[e2e] (2) dispatcher emitted fix_trunk_priority_signal (signal mode): OK"

# Assert: stub chump was called with `claim INFRA-9999` — claim still happens
# in signal mode; the gap is atomically reserved before signaling the IDE.
grep -q "claim INFRA-9999" "$STUB_CHUMP_LOG" \
    || { echo "[e2e] FAIL: chump claim INFRA-9999 not invoked"; cat "$STUB_CHUMP_LOG"; exit 1; }
echo "[e2e] (3) stub chump invoked with claim INFRA-9999 (signal mode still claims): OK"

# Assert: URGENT-INBOX.jsonl received the signal entry with kind+gap_id.
# python3 json.dumps emits ", " separators by default — match with or without spaces.
[[ -f "$URGENT_INBOX" ]] \
    || { echo "[e2e] FAIL: URGENT-INBOX.jsonl not written by signal mode"; \
         echo "--- dispatcher.err ---"; cat "$WORK_DIR/dispatcher.err"; \
         exit 1; }
grep -Eq '"kind":[[:space:]]*"fix_trunk_priority_signal"' "$URGENT_INBOX" \
    || { echo "[e2e] FAIL: URGENT-INBOX entry missing kind=fix_trunk_priority_signal"; \
         cat "$URGENT_INBOX"; exit 1; }
grep -Eq '"gap_id":[[:space:]]*"INFRA-9999"' "$URGENT_INBOX" \
    || { echo "[e2e] FAIL: URGENT-INBOX entry missing gap_id=INFRA-9999"; \
         cat "$URGENT_INBOX"; exit 1; }
echo "[e2e] (4) URGENT-INBOX.jsonl received fix_trunk_priority_signal for INFRA-9999: OK"

# Assert: stub claude was NOT invoked in signal mode (the whole point of INFRA-2341).
if [[ -s "$STUB_CLAUDE_LOG" ]]; then
    echo "[e2e] FAIL: signal mode spawned claude -p — should be no-op"
    echo "--- claude.log ---"; cat "$STUB_CLAUDE_LOG"
    exit 1
fi
echo "[e2e] (5) signal mode did NOT spawn claude -p: OK"

# Assert: dispatcher lockfile was written with mode=signal + gap_id.
[[ -f "$DISPATCHER_LOCK" ]] \
    || { echo "[e2e] FAIL: dispatcher lockfile not written"; exit 1; }
lock_gap="$(python3 -c "import json; print(json.load(open('$DISPATCHER_LOCK'))['gap_id'])")"
lock_mode="$(python3 -c "import json; print(json.load(open('$DISPATCHER_LOCK')).get('dispatch_mode',''))")"
[[ "$lock_gap" == "INFRA-9999" ]] \
    || { echo "[e2e] FAIL: dispatcher lockfile has wrong gap_id ($lock_gap)"; exit 1; }
[[ "$lock_mode" == "signal" ]] \
    || { echo "[e2e] FAIL: dispatcher lockfile dispatch_mode=$lock_mode, expected 'signal'"; exit 1; }
echo "[e2e] (6) dispatcher lockfile records gap_id=INFRA-9999 mode=signal: OK"

# Assert: dispatcher resolved worktree (no "worktree path not resolved" error).
if grep -q "worktree path not resolved" "$WORK_DIR/dispatcher.err"; then
    echo "[e2e] FAIL: dispatcher logged 'worktree path not resolved' — fix regressed"
    cat "$WORK_DIR/dispatcher.err"
    exit 1
fi
echo "[e2e] (7) dispatcher resolved worktree (signal mode): OK"

# ── Phase 2b: inbox-check-urgent.sh surfaces signal + emits acknowledged ──────
echo "[e2e] Phase 2b: inbox-check-urgent.sh handshake"
prev_lines=$(wc -l < "$AMBIENT")
CHUMP_URGENT_INBOX="$URGENT_INBOX" \
CHUMP_URGENT_INBOX_CURSOR="$URGENT_INBOX_CURSOR" \
CHUMP_AMBIENT_LOG="$AMBIENT" \
    "$INBOX_CHECK" > "$WORK_DIR/inbox-out.txt" 2>"$WORK_DIR/inbox-check.err" \
    || { echo "[e2e] FAIL: inbox-check-urgent non-zero"; cat "$WORK_DIR/inbox-check.err"; exit 1; }

# Assert: system-reminder block surfaced with the fix-trunk priority banner.
grep -q "FIX-TRUNK PRIORITY SIGNAL (INFRA-2341)" "$WORK_DIR/inbox-out.txt" \
    || { echo "[e2e] FAIL: inbox-check-urgent did not surface FIX-TRUNK banner"; \
         cat "$WORK_DIR/inbox-out.txt"; exit 1; }
grep -q "INFRA-9999" "$WORK_DIR/inbox-out.txt" \
    || { echo "[e2e] FAIL: inbox-check-urgent did not include gap_id in surface"; \
         cat "$WORK_DIR/inbox-out.txt"; exit 1; }
echo "[e2e] (8) inbox-check-urgent.sh surfaced FIX-TRUNK banner with INFRA-9999: OK"

# Assert: ambient gained kind=fix_trunk_session_acknowledged on cursor advance.
new_lines=$(tail -n +"$((prev_lines + 1))" "$AMBIENT")
echo "$new_lines" | grep -q '"kind":"fix_trunk_session_acknowledged"' \
    || { echo "[e2e] FAIL: no fix_trunk_session_acknowledged emitted by inbox-check-urgent"; \
         echo "--- new ambient ---"; echo "$new_lines"; exit 1; }
echo "$new_lines" | grep -q '"gap_id":"INFRA-9999"' \
    || { echo "[e2e] FAIL: ack event missing gap_id=INFRA-9999"; \
         echo "--- new ambient ---"; echo "$new_lines"; exit 1; }
echo "[e2e] (9) inbox-check-urgent.sh emitted fix_trunk_session_acknowledged: OK"

# Assert: cursor advanced — second invocation must produce zero output (no re-surface).
prev_lines=$(wc -l < "$AMBIENT")
CHUMP_URGENT_INBOX="$URGENT_INBOX" \
CHUMP_URGENT_INBOX_CURSOR="$URGENT_INBOX_CURSOR" \
CHUMP_AMBIENT_LOG="$AMBIENT" \
    "$INBOX_CHECK" > "$WORK_DIR/inbox-out2.txt" 2>/dev/null
[[ ! -s "$WORK_DIR/inbox-out2.txt" ]] \
    || { echo "[e2e] FAIL: second inbox-check invocation re-surfaced signal (cursor not advanced)"; \
         cat "$WORK_DIR/inbox-out2.txt"; exit 1; }
new_lines=$(tail -n +"$((prev_lines + 1))" "$AMBIENT")
echo "$new_lines" | grep -q '"kind":"fix_trunk_session_acknowledged"' && {
    echo "[e2e] FAIL: ack event re-emitted on second pass"
    echo "--- new ambient ---"; echo "$new_lines"; exit 1; } || true
echo "[e2e] (10) cursor advanced — no re-surface, no re-ack: OK"

# ── Phase 2c: Dispatcher tick (subprocess mode, INFRA-2341 opt-in) ────────────
echo "[e2e] Phase 2c: dispatcher tick (subprocess mode = legacy headless path)"
# Reset state: clear the previous lock so subprocess mode can re-claim.
rm -f "$DISPATCHER_LOCK"
: > "$STUB_CLAUDE_LOG"   # ensure clean ledger for the subprocess assertion
CHUMP_FIX_TRUNK_DISPATCH_MODE="subprocess" \
CHUMP_FIX_TRUNK_AMBIENT_FILE="$AMBIENT" \
CHUMP_FIX_TRUNK_LOCK_FILE="$DISPATCHER_LOCK" \
CHUMP_FIX_TRUNK_STATE_DB="$STATE_DB" \
CHUMP_FIX_TRUNK_MODEL="sonnet" \
CHUMP_FIX_TRUNK_TRUNK_RED_LOOKBACK_M=30 \
CHUMP_FIX_TRUNK_URGENT_INBOX="$URGENT_INBOX" \
CHUMP_WORKTREE_BASE="$WORK_DIR" \
    PATH="$STUB_BIN:$PATH" \
    "$DISPATCHER" 2>"$WORK_DIR/dispatcher-sub.err" \
    || { echo "[e2e] FAIL: dispatcher (subprocess) non-zero"; cat "$WORK_DIR/dispatcher-sub.err"; exit 1; }

# Assert: subprocess mode emitted fix_trunk_dispatched (legacy event).
grep -q '"kind":"fix_trunk_dispatched"' "$AMBIENT" \
    || { echo "[e2e] FAIL: subprocess mode did not emit fix_trunk_dispatched"; \
         echo "--- ambient.jsonl ---"; cat "$AMBIENT"; \
         echo "--- dispatcher-sub.err ---"; cat "$WORK_DIR/dispatcher-sub.err"; \
         exit 1; }
echo "[e2e] (11) subprocess mode emitted fix_trunk_dispatched: OK"

# Assert: stub claude was invoked (in background) — bounded polling for the
# subshell to write the stub log.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q "INFRA-9999" "$STUB_CLAUDE_LOG" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
grep -q "INFRA-9999" "$STUB_CLAUDE_LOG" \
    || { echo "[e2e] FAIL: subprocess mode did not spawn claude -p with INFRA-9999"; \
         echo "--- claude.log ---"; cat "$STUB_CLAUDE_LOG"; \
         exit 1; }
echo "[e2e] (12) subprocess mode spawned claude -p with INFRA-9999 in prompt: OK"

# Assert: subprocess lockfile records dispatch_mode=subprocess.
sub_lock_mode="$(python3 -c "import json; print(json.load(open('$DISPATCHER_LOCK')).get('dispatch_mode',''))")"
[[ "$sub_lock_mode" == "subprocess" ]] \
    || { echo "[e2e] FAIL: subprocess lockfile dispatch_mode=$sub_lock_mode, expected 'subprocess'"; exit 1; }
echo "[e2e] (13) subprocess lockfile records dispatch_mode=subprocess: OK"

# ── Phase 3: Idempotency — re-run dispatcher tick should skip (parallelism cap) ─
echo "[e2e] Phase 3: dispatcher re-tick should skip via lockfile"
# The stub claude exited immediately, so the recorded PID is dead. Per the
# dispatcher's kill -0 check this reclaims the lockfile. But the gap status
# is still 'open' (stub claude didn't ship), so it WILL re-claim and re-dispatch.
# To test the parallelism cap we need a live PID. Easiest path: write a fake
# lockfile pointing at the test runner's own PID (always alive).
echo "{\"pid\":$$,\"gap_id\":\"INFRA-9999\",\"started_at\":\"2026-05-31T23:00:00Z\",\"dispatch_mode\":\"signal\"}" > "$DISPATCHER_LOCK"
prev_lines=$(wc -l < "$AMBIENT")
CHUMP_FIX_TRUNK_AMBIENT_FILE="$AMBIENT" \
CHUMP_FIX_TRUNK_LOCK_FILE="$DISPATCHER_LOCK" \
CHUMP_FIX_TRUNK_STATE_DB="$STATE_DB" \
CHUMP_FIX_TRUNK_TRUNK_RED_LOOKBACK_M=30 \
CHUMP_FIX_TRUNK_URGENT_INBOX="$URGENT_INBOX" \
CHUMP_WORKTREE_BASE="$WORK_DIR" \
    PATH="$STUB_BIN:$PATH" \
    "$DISPATCHER" 2>/dev/null \
    || { echo "[e2e] FAIL: dispatcher idempotent tick non-zero"; exit 1; }
new_lines=$(tail -n +"$((prev_lines + 1))" "$AMBIENT")
echo "$new_lines" | grep -q '"kind":"fix_trunk_skipped"' \
    || { echo "[e2e] FAIL: dispatcher did not emit fix_trunk_skipped on re-tick with live prior"; \
         echo "--- new lines ---"; echo "$new_lines"; exit 1; }
echo "[e2e] (14) dispatcher skipped due to live prior PID: OK"

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
echo "[e2e] (15) sentinel emitted trunk_recovered: OK"

# Assert: stub chump gap set was called to close INFRA-9999.
grep -q "gap set INFRA-9999 --status done" "$STUB_CHUMP_LOG" \
    || { echo "[e2e] FAIL: chump gap set INFRA-9999 --status done not invoked"; \
         echo "--- chump.log ---"; cat "$STUB_CHUMP_LOG"; \
         exit 1; }
echo "[e2e] (16) chump gap set INFRA-9999 --status done invoked: OK"

# Assert: gap row now status=done in STATE_DB.
row_status="$(sqlite3 "$STATE_DB" "SELECT status FROM gaps WHERE id='INFRA-9999';")"
[[ "$row_status" == "done" ]] \
    || { echo "[e2e] FAIL: INFRA-9999 status=$row_status, expected 'done'"; exit 1; }
echo "[e2e] (17) INFRA-9999 row updated to status=done: OK"

echo "[test-trunk-loop-e2e] PASS"
