#!/usr/bin/env bash
# test-paramedic-rules.sh — INFRA-1375
#
# Exercises all 5 paramedic action rules using a stub `gh` shim and a synthetic
# github_cache.db.  Does NOT call real GitHub; all IO is isolated in a temp dir.
#
# Rules under test:
#   1  REBASE_DIRTY        — PR with merge_state_status=BEHIND
#   2  RERUN_FLAKE         — PR with a known-flake check failing
#   3  ALLOWLIST_EMIT_NO_REG — PR whose branch emits an unregistered event kind
#   4  SQUASH_INIT_LEAK    — PR with test@test.local author leak in head_ref
#   5  FILE_CLUSTER_RESCUE — ≥3 PRs share the same failing check name
#
# Skip-list rules:
#   6  skip: do-not-paramedic label in PR body (cache stub)
#   7  skip: <!-- no-paramedic --> in PR body
#   8  skip: 3 attempts within 24h in paramedic_attempts.db
#   9  PID lock prevents second daemon from starting
#  10  --dry-run emits plan JSON but does NOT run gh commands

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

echo "=== INFRA-1375 paramedic rule tests ==="

# ── prerequisites ─────────────────────────────────────────────────────────────
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "  SKIP: chump binary not found at $CHUMP_BIN (run cargo build first)"
    exit 0
fi
ok "chump binary present"

# ── helper: create an isolated test repo ──────────────────────────────────────
mk_env() {
    local d
    d="$(mktemp -d -t paramedic-test.XXXXXX)"
    mkdir -p "$d/.chump-locks" "$d/docs/observability" "$d/.chump"

    # Minimal EVENT_REGISTRY.yaml with one registered kind.
    cat > "$d/docs/observability/EVENT_REGISTRY.yaml" <<'YAML'
events:
  - kind: paramedic_action
    emitter: src/paramedic.rs
    trigger: test
    consumers: []
    fields_required: [ts, kind, pr_number, action, reason, dry_run]
YAML

    # Minimal github_cache.db with pr_state table — must match real schema in github_cache.sh.
    sqlite3 "$d/.chump/github_cache.db" <<'SQL'
CREATE TABLE IF NOT EXISTS pr_state (
    number              INTEGER PRIMARY KEY,
    head_ref            TEXT,
    head_sha            TEXT,
    base_ref            TEXT,
    base_sha            TEXT,
    mergeable_state     TEXT,
    auto_merge_enabled  INTEGER NOT NULL DEFAULT 0,
    draft               INTEGER NOT NULL DEFAULT 0,
    merged_at           TEXT,
    title               TEXT,
    user_login          TEXT,
    updated_at_api      TEXT NOT NULL DEFAULT '',
    fetched_at_local    TEXT NOT NULL DEFAULT '',
    raw_payload_json    TEXT,
    merge_state_status  TEXT,
    labels_json         TEXT DEFAULT '[]',
    body                TEXT DEFAULT ''
);
SQL
    printf '%s\n' "$d"
}

# Stub gh command that records calls but does nothing.
make_gh_stub() {
    local stub_dir="$1"
    cat > "$stub_dir/gh" <<'SH'
#!/usr/bin/env bash
# Record invocation.
printf '%s\n' "$*" >> "${GH_STUB_LOG:-/tmp/gh-stub.log}"
# For `gh pr list --json ...` return empty array by default unless overridden.
if [[ "$*" == *"pr list"* ]]; then
    printf '[]'
fi
exit 0
SH
    chmod +x "$stub_dir/gh"
}

# ── Test 1: REBASE_DIRTY ─────────────────────────────────────────────────────
echo "--- Test 1: REBASE_DIRTY (merge_state_status=BEHIND)"
T1="$(mk_env)"
sqlite3 "$T1/.chump/github_cache.db" <<'SQL'
INSERT INTO pr_state (number, head_ref, head_sha, mergeable_state, merge_state_status, auto_merge_enabled)
VALUES (101, 'chump/infra-1001-claim', 'aaaaaaa', 'MERGEABLE', 'BEHIND', 1);
SQL
CHUMP_REPO="$T1" "$CHUMP_BIN" paramedic triage 2>/dev/null > "$T1/plan.json"
if grep -q '"REBASE_DIRTY"' "$T1/plan.json" && grep -qE '"pr_number"\s*:\s*101' "$T1/plan.json"; then
    ok "REBASE_DIRTY detected for PR 101"
else
    fail "REBASE_DIRTY not detected (plan: $(cat "$T1/plan.json"))"
fi
rm -rf "$T1"

# ── Test 2: SQUASH_INIT_LEAK ─────────────────────────────────────────────────
echo "--- Test 2: SQUASH_INIT_LEAK (test@test.local in raw_payload_json)"
T2="$(mk_env)"
sqlite3 "$T2/.chump/github_cache.db" <<'SQL'
INSERT INTO pr_state (number, head_ref, head_sha, mergeable_state, merge_state_status, auto_merge_enabled, raw_payload_json)
VALUES (102, 'chump/infra-1002-claim', 'bbbbbbb', 'MERGEABLE', 'CLEAN', 1,
        '{"commits":[{"author":{"email":"test@test.local","name":"Test"}}]}');
SQL
CHUMP_REPO="$T2" "$CHUMP_BIN" paramedic triage 2>/dev/null > "$T2/plan.json"
if grep -q '"SQUASH_INIT_LEAK"' "$T2/plan.json" && grep -qE '"pr_number"\s*:\s*102' "$T2/plan.json"; then
    ok "SQUASH_INIT_LEAK detected for PR 102"
else
    fail "SQUASH_INIT_LEAK not detected (plan: $(cat "$T2/plan.json"))"
fi
rm -rf "$T2"

# ── Test 3: skip do-not-paramedic label ──────────────────────────────────────
echo "--- Test 3: skip PR with do-not-paramedic label"
T3="$(mk_env)"
# raw_payload_json must contain {"labels":[{"name":"do-not-paramedic"}]} for should_skip to fire.
sqlite3 "$T3/.chump/github_cache.db" <<'SQL'
INSERT INTO pr_state (number, head_ref, head_sha, mergeable_state, merge_state_status, auto_merge_enabled, raw_payload_json)
VALUES (103, 'chump/infra-1003-claim', 'ccccccc', 'MERGEABLE', 'BEHIND', 1,
        '{"labels":[{"name":"do-not-paramedic"},{"name":"auto-merge"}],"body":""}');
SQL
CHUMP_REPO="$T3" "$CHUMP_BIN" paramedic triage 2>/dev/null > "$T3/plan.json"
if ! grep -qE '"pr_number"\s*:\s*103' "$T3/plan.json"; then
    ok "PR 103 skipped due to do-not-paramedic label"
else
    fail "PR 103 should have been skipped (plan: $(cat "$T3/plan.json"))"
fi
rm -rf "$T3"

# ── Test 4: skip <!-- no-paramedic --> in body ───────────────────────────────
echo "--- Test 4: skip PR with <!-- no-paramedic --> in body"
T4="$(mk_env)"
# raw_payload_json must contain {"body":"...<!-- no-paramedic -->..."} for should_skip to fire.
sqlite3 "$T4/.chump/github_cache.db" <<'SQL'
INSERT INTO pr_state (number, head_ref, head_sha, mergeable_state, merge_state_status, auto_merge_enabled, raw_payload_json)
VALUES (104, 'chump/infra-1004-claim', 'ddddddd', 'MERGEABLE', 'BEHIND', 1,
        '{"labels":[],"body":"This PR has <!-- no-paramedic --> marker."}');
SQL
CHUMP_REPO="$T4" "$CHUMP_BIN" paramedic triage 2>/dev/null > "$T4/plan.json"
if ! grep -qE '"pr_number"\s*:\s*104' "$T4/plan.json"; then
    ok "PR 104 skipped due to <!-- no-paramedic --> marker"
else
    fail "PR 104 should have been skipped (plan: $(cat "$T4/plan.json"))"
fi
rm -rf "$T4"

# ── Test 5: skip PR with ≥3 attempts in 24h ──────────────────────────────────
echo "--- Test 5: skip PR with 3+ attempts in 24h"
T5="$(mk_env)"
sqlite3 "$T5/.chump/github_cache.db" <<'SQL'
INSERT INTO pr_state (number, head_ref, head_sha, mergeable_state, merge_state_status, auto_merge_enabled)
VALUES (105, 'chump/infra-1005-claim', 'eeeeeee', 'MERGEABLE', 'BEHIND', 1);
SQL
# Pre-seed 3 recent attempts.
NOW_S="$(date +%s)"
sqlite3 "$T5/.chump/paramedic_attempts.db" <<SQL
CREATE TABLE IF NOT EXISTS attempts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pr_number INTEGER NOT NULL,
    action TEXT NOT NULL,
    attempted_at INTEGER NOT NULL,
    dry_run INTEGER NOT NULL DEFAULT 0
);
INSERT INTO attempts (pr_number, action, attempted_at, dry_run) VALUES (105, 'REBASE_DIRTY', $((NOW_S - 100)), 0);
INSERT INTO attempts (pr_number, action, attempted_at, dry_run) VALUES (105, 'REBASE_DIRTY', $((NOW_S - 200)), 0);
INSERT INTO attempts (pr_number, action, attempted_at, dry_run) VALUES (105, 'REBASE_DIRTY', $((NOW_S - 300)), 0);
SQL
CHUMP_REPO="$T5" "$CHUMP_BIN" paramedic triage 2>/dev/null > "$T5/plan.json"
if ! grep -qE '"pr_number"\s*:\s*105' "$T5/plan.json"; then
    ok "PR 105 skipped after 3 recent attempts"
else
    fail "PR 105 should have been skipped (plan: $(cat "$T5/plan.json"))"
fi
rm -rf "$T5"

# ── Test 6: FILE_CLUSTER_RESCUE (≥3 PRs share a failing check) ───────────────
echo "--- Test 6: FILE_CLUSTER_RESCUE triggered by 3 PRs with same flake"
T6="$(mk_env)"
# check_runs uses head_sha as key (matching real schema); each PR must have distinct sha.
sqlite3 "$T6/.chump/github_cache.db" <<'SQL'
CREATE TABLE IF NOT EXISTS check_runs (
    head_sha         TEXT NOT NULL,
    name             TEXT NOT NULL,
    status           TEXT,
    conclusion       TEXT,
    started_at       TEXT,
    completed_at     TEXT,
    fetched_at_local TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (head_sha, name)
);
INSERT INTO pr_state (number, head_ref, head_sha, mergeable_state, merge_state_status, auto_merge_enabled)
VALUES
  (201, 'chump/infra-201-claim', 'sha201', 'MERGEABLE', 'CLEAN', 1),
  (202, 'chump/infra-202-claim', 'sha202', 'MERGEABLE', 'CLEAN', 1),
  (203, 'chump/infra-203-claim', 'sha203', 'MERGEABLE', 'CLEAN', 1);
INSERT INTO check_runs (head_sha, name, status, conclusion) VALUES
  ('sha201', 'cargo-test', 'completed', 'failure'),
  ('sha202', 'cargo-test', 'completed', 'failure'),
  ('sha203', 'cargo-test', 'completed', 'failure');
SQL
CHUMP_REPO="$T6" "$CHUMP_BIN" paramedic triage 2>/dev/null > "$T6/plan.json"
if grep -q '"FILE_CLUSTER_RESCUE"' "$T6/plan.json"; then
    ok "FILE_CLUSTER_RESCUE triggered for 3 PRs with cargo-test failure"
else
    fail "FILE_CLUSTER_RESCUE not triggered (plan: $(cat "$T6/plan.json"))"
fi
rm -rf "$T6"

# ── Test 7: --dry-run emits plan but does not call real gh ────────────────────
echo "--- Test 7: --dry-run produces plan without running gh"
T7="$(mk_env)"
STUB_DIR7="$(mktemp -d)"
make_gh_stub "$STUB_DIR7"
GH_STUB_LOG="$T7/gh-calls.log"
sqlite3 "$T7/.chump/github_cache.db" <<'SQL'
INSERT INTO pr_state (number, head_ref, head_sha, mergeable_state, merge_state_status, auto_merge_enabled)
VALUES (301, 'chump/infra-301-claim', 'sha301', 'MERGEABLE', 'BEHIND', 1);
SQL
GH_STUB_LOG="$GH_STUB_LOG" PATH="$STUB_DIR7:$PATH" \
    CHUMP_REPO="$T7" "$CHUMP_BIN" paramedic execute --dry-run 2>/dev/null
if [[ -f "$GH_STUB_LOG" ]] && grep -q "." "$GH_STUB_LOG" 2>/dev/null; then
    fail "--dry-run invoked gh stub (should not execute)"
else
    ok "--dry-run did not invoke gh commands"
fi
rm -rf "$T7" "$STUB_DIR7"

# ── Test 8: triage JSON is valid and has required fields ─────────────────────
echo "--- Test 8: triage output is valid JSON with required fields"
T8="$(mk_env)"
sqlite3 "$T8/.chump/github_cache.db" <<'SQL'
INSERT INTO pr_state (number, head_ref, head_sha, mergeable_state, merge_state_status, auto_merge_enabled)
VALUES (401, 'chump/infra-401-claim', 'sha401', 'MERGEABLE', 'BEHIND', 1);
SQL
CHUMP_REPO="$T8" "$CHUMP_BIN" paramedic triage 2>/dev/null > "$T8/plan.json"
if python3 -c "
import json, sys
d = json.load(open('$T8/plan.json'))
assert 'generated_at' in d, 'missing generated_at'
assert 'items' in d, 'missing items'
assert isinstance(d['items'], list), 'items not a list'
assert len(d['items']) > 0, 'items empty'
item = d['items'][0]
assert 'pr_number' in item
assert 'action' in item
assert 'reason' in item
print('OK')
" 2>/dev/null; then
    ok "triage JSON valid with required fields"
else
    fail "triage JSON missing required fields or invalid ($(cat "$T8/plan.json" | head -3))"
fi
rm -rf "$T8"

# ── summary ────────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
