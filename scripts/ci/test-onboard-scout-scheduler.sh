#!/usr/bin/env bash
# Smoke test for scripts/ops/onboard-scout-scheduler.sh (MISSION-038).
# Asserts:
#   (a) script is executable + --help exits 0
#   (b) empty repos table → reports 0 scheduled, exits 0
#   (c) fixture: 3 repos, 2 stale + 1 fresh → schedules 2 (dry-run)
#   (d) rate cap: 5 stale repos, --rate-per-hr 2 → schedules 2, leaves 3
#   (e) last_scan_at is updated after successful scan (stub for chump onboard)
#   (f) active-lease repo is skipped
#   (g) idempotent re-run within 5 min → schedules 0
#   (h) emits onboard_scan_scheduled + onboard_scan_batch_complete to ambient

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEDULER="$REPO_ROOT/scripts/ops/onboard-scout-scheduler.sh"

WORK_DIR="$(mktemp -d /tmp/onboard-scheduler-test-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

AMBIENT="$WORK_DIR/ambient.jsonl"
touch "$AMBIENT"

export CHUMP_AMBIENT_PATH="$AMBIENT"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create a fresh isolated SQLite state.db with the repos + leases + gaps schema
_init_db() {
    local db="$1"
    sqlite3 "$db" <<'SQL'
CREATE TABLE repos (
    id              TEXT PRIMARY KEY,
    owner           TEXT NOT NULL,
    name            TEXT NOT NULL,
    added_at        INTEGER NOT NULL,
    last_scan_at    INTEGER,
    last_clone_at   INTEGER,
    last_ship_at    INTEGER,
    cascade_tier    TEXT NOT NULL DEFAULT 'dogfood',
    status          TEXT NOT NULL DEFAULT 'active'
);
CREATE INDEX repos_status ON repos(status);
CREATE INDEX repos_last_scan_at ON repos(last_scan_at);
CREATE TABLE gaps (
    id               TEXT PRIMARY KEY,
    skills_required  TEXT NOT NULL DEFAULT ''
);
CREATE TABLE leases (
    session_id  TEXT PRIMARY KEY,
    gap_id      TEXT NOT NULL,
    worktree    TEXT NOT NULL DEFAULT '',
    expires_at  INTEGER NOT NULL
);
CREATE INDEX leases_gap ON leases(gap_id);
SQL
}

# Insert a repo row. $3 = last_scan_at epoch (empty string → NULL).
_insert_repo() {
    local db="$1" id="$2" scan_at="$3" status="${4:-active}"
    local owner="${id%%/*}" name="${id#*/}"
    local scan_val="NULL"
    [[ -n "$scan_at" ]] && scan_val="$scan_at"
    sqlite3 "$db" \
        "INSERT INTO repos(id,owner,name,added_at,last_scan_at,status) VALUES('$id','$owner','$name',$(date +%s),$scan_val,'$status');"
}

# ── (a) executable + --help ───────────────────────────────────────────────────
[[ -x "$SCHEDULER" ]] || { echo "[test] FAIL (a): scheduler not executable"; exit 1; }
echo "[test] (a.1) executable: OK"

DB_A="$WORK_DIR/state_a.db"
_init_db "$DB_A"
"$SCHEDULER" --help >/dev/null 2>&1 || { echo "[test] FAIL (a.2): --help non-zero"; exit 1; }
echo "[test] (a.2) --help: OK"

# ── (b) empty repos table → 0 scheduled, exit 0 ──────────────────────────────
DB_B="$WORK_DIR/state_b.db"
_init_db "$DB_B"
out=$(CHUMP_STATE_DB="$DB_B" CHUMP_ONBOARD_SCHED_DRY_RUN=1 "$SCHEDULER" 2>&1)
# Early-exit path logs "nothing to schedule"; ambient gets batch_complete with scheduled=0
(echo "$out" | grep -qE 'nothing to schedule|scheduled=0') || \
    grep -q '"scheduled":0' "$AMBIENT" || \
    { echo "[test] FAIL (b): expected 0 scheduled; got: $out"; exit 1; }
echo "[test] (b) empty repos table → 0 scheduled: OK"

# ── (c) 2 stale + 1 fresh → schedules 2 (dry-run) ───────────────────────────
DB_C="$WORK_DIR/state_c.db"
_init_db "$DB_C"
STALE_EPOCH=$(( $(date +%s) - 9 * 86400 ))   # 9 days ago → stale
FRESH_EPOCH=$(( $(date +%s) - 1 * 86400 ))    # 1 day ago  → fresh
_insert_repo "$DB_C" "testorg/repo-stale-1" "$STALE_EPOCH"
_insert_repo "$DB_C" "testorg/repo-stale-2" ""              # never scanned → stale
_insert_repo "$DB_C" "testorg/repo-fresh-1" "$FRESH_EPOCH"

out=$(CHUMP_STATE_DB="$DB_C" CHUMP_ONBOARD_SCHED_DRY_RUN=1 \
      CHUMP_ONBOARD_SCHED_STALE_DAYS=7 "$SCHEDULER" 2>&1)
# The done-line looks like: "done — scheduled=2 skipped_lease=0 errors=0 dry_run=1"
echo "$out" | grep -qE 'done.*scheduled=2' \
    || { echo "[test] FAIL (c): expected scheduled=2; got: $out"; exit 1; }
echo "[test] (c) 2 stale + 1 fresh → schedules 2: OK"

# ── (d) rate cap: 5 stale, --rate-per-hr 2 → schedules 2 ─────────────────────
DB_D="$WORK_DIR/state_d.db"
_init_db "$DB_D"
for i in 1 2 3 4 5; do
    _insert_repo "$DB_D" "testorg/stale-$i" ""
done
out=$(CHUMP_STATE_DB="$DB_D" CHUMP_ONBOARD_SCHED_DRY_RUN=1 \
      "$SCHEDULER" --rate-per-hr 2 2>&1)
echo "$out" | grep -qE 'done.*scheduled=2' \
    || { echo "[test] FAIL (d): expected scheduled=2 with rate cap; got: $out"; exit 1; }
echo "[test] (d) rate cap → schedules 2 of 5: OK"

# ── (e) last_scan_at updated after successful scan (stub chump onboard) ───────
DB_E="$WORK_DIR/state_e.db"
_init_db "$DB_E"
_insert_repo "$DB_E" "testorg/repo-scan-test" ""

# Create a stub directory in PATH that intercepts "chump onboard" and "chump repos set"
STUB_BIN="$WORK_DIR/bin_e"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/chump" <<'STUB'
#!/usr/bin/env bash
# Stub: chump onboard <repo> → succeed; chump repos set <repo> --last-scan-at N → write to marker
case "$1" in
    onboard)
        echo "[stub] onboard $2"
        exit 0
        ;;
    repos)
        # "repos set <id> --last-scan-at <epoch>"
        echo "[stub] repos set args: $*"
        echo "$*" >> "${STUB_MARKER_FILE:-/dev/null}"
        exit 0
        ;;
    *)
        echo "[stub] unknown: $*" >&2
        exit 1
        ;;
esac
STUB
chmod +x "$STUB_BIN/chump"

MARKER="$WORK_DIR/repos_set_calls.txt"
touch "$MARKER"

out=$(CHUMP_STATE_DB="$DB_E" STUB_MARKER_FILE="$MARKER" \
      PATH="$STUB_BIN:$PATH" "$SCHEDULER" 2>&1)

# Verify last_scan_at was updated (repos set called with --last-scan-at)
grep -q "\-\-last-scan-at" "$MARKER" \
    || { echo "[test] FAIL (e): expected 'repos set --last-scan-at' call; got: $(cat "$MARKER"); output: $out"; exit 1; }
echo "[test] (e) last_scan_at updated after scan: OK"

# ── (f) active-lease repo is skipped ─────────────────────────────────────────
DB_F="$WORK_DIR/state_f.db"
_init_db "$DB_F"
_insert_repo "$DB_F" "testorg/leased-repo" ""
_insert_repo "$DB_F" "testorg/free-repo"   ""

# Insert a gap referencing the leased repo and an unexpired lease
FUTURE=$(( $(date +%s) + 3600 ))
sqlite3 "$DB_F" \
    "INSERT INTO gaps(id,skills_required) VALUES('INFRA-FAKE-001','external_repo:testorg/leased-repo');"
sqlite3 "$DB_F" \
    "INSERT INTO leases(session_id,gap_id,worktree,expires_at) VALUES('test-session-001','INFRA-FAKE-001','',${FUTURE});"

out=$(CHUMP_STATE_DB="$DB_F" CHUMP_ONBOARD_SCHED_DRY_RUN=1 "$SCHEDULER" 2>&1)
# The done-line: "done — scheduled=1 skipped_lease=1 errors=0 dry_run=1"
echo "$out" | grep -qE 'done.*skipped_lease=1' \
    || { echo "[test] FAIL (f): expected skipped_lease=1; got: $out"; exit 1; }
echo "$out" | grep -qE 'done.*scheduled=1' \
    || { echo "[test] FAIL (f): expected scheduled=1; got: $out"; exit 1; }
echo "[test] (f) active-lease repo skipped: OK"

# ── (g) idempotent re-run within 5 min → schedules 0 ────────────────────────
DB_G="$WORK_DIR/state_g.db"
_init_db "$DB_G"
# Set last_scan_at to 3 minutes ago (well within the 7-day stale window but
# simulates "just scanned": not stale at all — fresh)
JUST_NOW=$(( $(date +%s) - 180 ))
_insert_repo "$DB_G" "testorg/idempotent-repo" "$JUST_NOW"

out=$(CHUMP_STATE_DB="$DB_G" CHUMP_ONBOARD_SCHED_DRY_RUN=1 \
      CHUMP_ONBOARD_SCHED_STALE_DAYS=7 "$SCHEDULER" 2>&1)
# Fresh repo → early-exit "nothing to schedule" OR done-line scheduled=0
(echo "$out" | grep -qE 'nothing to schedule|done.*scheduled=0') \
    || { echo "[test] FAIL (g): idempotent re-run should schedule 0; got: $out"; exit 1; }
echo "[test] (g) idempotent re-run within 5 min → 0 scheduled: OK"

# ── (h) ambient events emitted ────────────────────────────────────────────────
# Reuse DB_C which already ran a dry-run that produced scheduled=2.
# ambient.jsonl is shared across all sub-tests.
grep -q '"kind":"onboard_scan_scheduled"' "$AMBIENT" \
    || { echo "[test] FAIL (h): no onboard_scan_scheduled emitted"; exit 1; }
grep -q '"kind":"onboard_scan_batch_complete"' "$AMBIENT" \
    || { echo "[test] FAIL (h): no onboard_scan_batch_complete emitted"; exit 1; }
echo "[test] (h) ambient events: onboard_scan_scheduled + onboard_scan_batch_complete: OK"

echo "[test-onboard-scout-scheduler] PASS"
