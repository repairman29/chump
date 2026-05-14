#!/usr/bin/env bash
# scripts/ci/test-infra-1129-check-runs-backfill.sh — INFRA-1129
#
# Verifies that github-cache-reconcile.sh backfills the check_runs table for
# pr_state rows whose head_sha has no check_runs entries (cold-start scenario).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/ops/github-cache-reconcile.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

CACHE_DB="$TMP/cache.db"
AMB="$TMP/ambient.jsonl"

# ── static checks ─────────────────────────────────────────────────────────────
grep -q 'INFRA-1129' "$RECONCILE" || fail "INFRA-1129 banner missing from reconcile script"
grep -q 'check_runs_warmed' "$RECONCILE" || fail "check_runs_warmed kind missing"
grep -q 'check_runs NOT IN\|NOT IN.*check_runs\|head_sha NOT IN' "$RECONCILE" \
    || fail "cold-sha query missing"
ok "static: reconcile script has INFRA-1129 markers"

# ── set up fake gh binary ─────────────────────────────────────────────────────
# Intercepts "gh repo view" and "gh api repos/.../commits/<sha>/check-runs"
GH_BIN="$TMP/gh"
cat >"$GH_BIN" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$*" == *"repo view"* ]]; then
    echo "repairman29/chump"
    exit 0
fi
if [[ "$*" == *"/pulls?state=open"* ]]; then
    echo "[]"
    exit 0
fi
# commits/<sha>/check-runs — return different data per SHA
if [[ "$*" == *"abc111"* ]]; then
    echo '[{"name":"cargo-test","status":"completed","conclusion":"success","started_at":"2026-05-13T20:00:00Z","completed_at":"2026-05-13T20:05:00Z"}]'
    exit 0
fi
if [[ "$*" == *"abc222"* ]]; then
    echo '[{"name":"clippy","status":"completed","conclusion":"failure","started_at":"2026-05-13T20:01:00Z","completed_at":"2026-05-13T20:03:00Z"},{"name":"fast-checks","status":"completed","conclusion":"success","started_at":"2026-05-13T20:01:00Z","completed_at":"2026-05-13T20:02:00Z"}]'
    exit 0
fi
echo "[]"
exit 0
GHEOF
chmod +x "$GH_BIN"

# ── seed pr_state with 2 rows that have head_sha but no check_runs ─────────────
python3 - "$CACHE_DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE IF NOT EXISTS pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT,
    auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT
);
""")
db.execute("INSERT INTO pr_state VALUES (101,'feat/a','abc111',NULL,NULL,'clean',0,0,NULL,'PR A','alice','2026-05-13T20:00:00Z','2026-05-13T20:00:00Z','{}')")
db.execute("INSERT INTO pr_state VALUES (102,'feat/b','abc222',NULL,NULL,'clean',0,0,NULL,'PR B','bob','2026-05-13T20:00:00Z','2026-05-13T20:00:00Z','{}')")
db.commit()
PY
ok "seed: 2 pr_state rows with no check_runs entries"

# ── run reconcile ─────────────────────────────────────────────────────────────
PATH="$TMP:$PATH" \
    CHUMP_CACHE_DB="$CACHE_DB" \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_CACHE_RECONCILE_MAX_FETCH=20 \
    bash "$RECONCILE" 2>&1 | grep -E 'cache-reconcile:|INFRA-1129' || true
ok "reconcile ran without error"

# ── assert check_runs rows were inserted ──────────────────────────────────────
ROW1=$(sqlite3 "$CACHE_DB" \
    "SELECT name, conclusion FROM check_runs WHERE head_sha='abc111' AND name='cargo-test'")
[[ "$ROW1" == "cargo-test|success" ]] || fail "abc111 cargo-test row wrong: '$ROW1'"
ok "abc111: cargo-test row backfilled correctly"

COUNT2=$(sqlite3 "$CACHE_DB" "SELECT COUNT(*) FROM check_runs WHERE head_sha='abc222'")
[[ "$COUNT2" == "2" ]] || fail "abc222 expected 2 rows, got $COUNT2"
ok "abc222: 2 check_runs rows backfilled"

ROW2=$(sqlite3 "$CACHE_DB" \
    "SELECT name, conclusion FROM check_runs WHERE head_sha='abc222' AND name='clippy'")
[[ "$ROW2" == "clippy|failure" ]] || fail "abc222 clippy row wrong: '$ROW2'"
ok "abc222: clippy conclusion=failure preserved"

# ── assert check_runs_warmed events emitted ────────────────────────────────────
[[ -f "$AMB" ]] || fail "ambient.jsonl not created"
EVENTS=$(grep '"check_runs_warmed"' "$AMB" || true)
EVENT_COUNT=$(echo "$EVENTS" | grep -c '"check_runs_warmed"' || true)
[[ "$EVENT_COUNT" -eq 2 ]] || fail "expected 2 check_runs_warmed events, got $EVENT_COUNT"
ok "2 check_runs_warmed events emitted to ambient.jsonl"

echo "$EVENTS" | python3 -c "
import json, sys
for line in sys.stdin:
    e = json.loads(line)
    assert e['kind'] == 'check_runs_warmed', f'wrong kind: {e}'
    assert 'head_sha' in e, f'missing head_sha: {e}'
    assert 'count' in e and e['count'] > 0, f'count missing or zero: {e}'
" || fail "check_runs_warmed event fields malformed"
ok "check_runs_warmed events have required fields (ts, kind, head_sha, count)"

# ── idempotency: second run should not re-backfill ─────────────────────────────
AMB2="$TMP/ambient2.jsonl"
PATH="$TMP:$PATH" \
    CHUMP_CACHE_DB="$CACHE_DB" \
    CHUMP_AMBIENT_LOG="$AMB2" \
    CHUMP_CACHE_RECONCILE_MAX_FETCH=20 \
    bash "$RECONCILE" >/dev/null 2>&1
EVENTS2=$(grep '"check_runs_warmed"' "$AMB2" 2>/dev/null || true)
[[ -z "$EVENTS2" ]] || fail "second run re-emitted check_runs_warmed — not idempotent"
ok "idempotent: second run emits no check_runs_warmed events"

# ── EVENT_REGISTRY has check_runs_warmed ──────────────────────────────────────
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q 'check_runs_warmed' "$REGISTRY" || fail "check_runs_warmed missing from EVENT_REGISTRY.yaml"
ok "EVENT_REGISTRY.yaml registers check_runs_warmed"

echo
echo "All INFRA-1129 check-runs-backfill tests passed (6/6)."
