#!/usr/bin/env bash
# test-gap-sync.sh — INFRA-2053
#
# Verifies bidirectional `chump gap sync` (YAML <-> state.db) across four
# drift classes on a synthetic fixture:
#   1. YAML-only          : YAML exists, no DB row.        Pull inserts.
#   2. DB-only            : DB row exists, no YAML.         Push creates YAML.
#   3. TODO-AC overwrite  : DB has TODO ACs, YAML concrete. Pull recovers.
#   4. Title divergence   : Both exist, titles differ.      Pull updates DB.
#
# Smoke test contract (per dispatch deliverable):
#   - `sync --check` exits non-zero + lists all 4 drift instances.
#   - `sync --pull` makes the DB match YAML for cases 1, 3, 4.
#   - `sync --check` rerun exits 0 (clean) after pull repaints + push fills.
#   - `sync --push` writes the missing YAML for case 2.
#
# Uses a tempdir + temp state.db; never touches the real .chump/state.db
# or docs/gaps/. Disables ambient.jsonl writes via CHUMP_AMBIENT_DISABLE.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

# Locate the chump binary (built in target/debug after cargo check or test).
CHUMP_BIN=""
for cand in \
    "$REPO_ROOT/target/debug/chump" \
    "$REPO_ROOT/target/release/chump" \
    "$HOME/.cargo/bin/chump"; do
    if [[ -x "$cand" ]]; then
        CHUMP_BIN="$cand"
        break
    fi
done
if [[ -z "$CHUMP_BIN" ]]; then
    info "chump binary not found in target/debug, building..."
    (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --bin chump --quiet)
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
fi
info "using chump: $CHUMP_BIN"

TMP="$(mktemp -d -t test-infra-2053.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Set up a fake worktree layout so chump can find docs/gaps/ ────────────
FAKE_ROOT="$TMP/fake-root"
mkdir -p "$FAKE_ROOT/docs/gaps" "$FAKE_ROOT/.chump"
FAKE_DB="$FAKE_ROOT/.chump/state.db"

# Disable ambient emit so the test doesn't write to the real ambient.jsonl
# or any side-channel telemetry.
export CHUMP_AMBIENT_DISABLE=1
# Override the canonical state.db location.
export CHUMP_STATE_DB="$FAKE_DB"

# Bootstrap an empty state.db with the minimal `gaps` table the sync module
# needs. We can't use `chump gap list` to do this because it would trigger
# INFRA-821 auto-seed-if-empty, which imports the *real* repo's docs/gaps/
# into the test DB. So we create the schema directly. Columns mirror the
# canonical schema in chump-gap-store/src/lib.rs `migrate()`; sync only
# touches the gaps table.
sqlite3 "$FAKE_DB" <<'SCHEMA'
CREATE TABLE IF NOT EXISTS gaps (
    id                  TEXT PRIMARY KEY,
    domain              TEXT NOT NULL DEFAULT '',
    title               TEXT NOT NULL DEFAULT '',
    description         TEXT NOT NULL DEFAULT '',
    priority            TEXT NOT NULL DEFAULT '',
    effort              TEXT NOT NULL DEFAULT '',
    status              TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on          TEXT NOT NULL DEFAULT '',
    notes               TEXT NOT NULL DEFAULT '',
    source_doc          TEXT NOT NULL DEFAULT '',
    created_at          INTEGER NOT NULL DEFAULT 0,
    closed_at           INTEGER,
    opened_date         TEXT NOT NULL DEFAULT '',
    closed_date         TEXT NOT NULL DEFAULT '',
    closed_pr           INTEGER,
    skills_required     TEXT NOT NULL DEFAULT '',
    preferred_backend   TEXT NOT NULL DEFAULT '',
    preferred_machine   TEXT NOT NULL DEFAULT '',
    estimated_minutes   TEXT NOT NULL DEFAULT '',
    required_model      TEXT NOT NULL DEFAULT ''
);
SCHEMA

# Sanity: was the DB created?
if [[ ! -f "$FAKE_DB" ]]; then
    fail "state.db was not initialised at $FAKE_DB"
fi
info "state.db initialised: $FAKE_DB"

# ── Seed the four drift cases ───────────────────────────────────────────
# Case 1: YAML-only (no DB row).
cat > "$FAKE_ROOT/docs/gaps/INFRA-9101.yaml" <<'EOF'
- id: INFRA-9101
  domain: INFRA
  title: case1-yaml-only
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - first AC
    - second AC
EOF

# Case 2: DB-only (no YAML on disk).
sqlite3 "$FAKE_DB" "INSERT INTO gaps(id, domain, title, status, priority, effort, acceptance_criteria, depends_on, created_at) VALUES ('INFRA-9102', 'INFRA', 'case2-db-only', 'open', 'P1', 's', '[\"only-in-db\"]', '[]', 100);"

# Case 3: TODO-AC overwrite — DB has TODO ACs, YAML has concrete ACs.
sqlite3 "$FAKE_DB" "INSERT INTO gaps(id, domain, title, status, priority, effort, acceptance_criteria, depends_on, created_at) VALUES ('INFRA-9103', 'INFRA', 'case3-todo-ac', 'open', 'P1', 's', '[\"TODO: define acceptance criteria\"]', '[]', 100);"
cat > "$FAKE_ROOT/docs/gaps/INFRA-9103.yaml" <<'EOF'
- id: INFRA-9103
  domain: INFRA
  title: case3-todo-ac
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - concrete recovered AC 1
    - concrete recovered AC 2
EOF

# Case 4: Title divergence — both exist, titles differ.
sqlite3 "$FAKE_DB" "INSERT INTO gaps(id, domain, title, status, priority, effort, acceptance_criteria, depends_on, created_at) VALUES ('INFRA-9104', 'INFRA', 'case4-DB-WAS-HERE', 'open', 'P1', 's', '[\"the AC\"]', '[]', 100);"
cat > "$FAKE_ROOT/docs/gaps/INFRA-9104.yaml" <<'EOF'
- id: INFRA-9104
  domain: INFRA
  title: case4-YAML-NOW-WINS
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - the AC
EOF

# ── 1. `sync --check` reports 4 drift entries, exits non-zero ───────────
info "step 1: chump gap sync --check (expect 4 drift entries, non-zero exit)"
set +e
CHECK_OUT="$("$CHUMP_BIN" gap sync --check --state-db "$FAKE_DB" --gaps-dir "$FAKE_ROOT/docs/gaps" --json 2>&1)"
CHECK_RC=$?
set -e

if [[ $CHECK_RC -eq 0 ]]; then
    fail "expected non-zero exit on drift, got 0. Output:\n$CHECK_OUT"
fi
echo "$CHECK_OUT" | grep -q 'INFRA-9101' || fail "case1 missing from check output"
echo "$CHECK_OUT" | grep -q 'INFRA-9102' || fail "case2 missing from check output"
echo "$CHECK_OUT" | grep -q 'INFRA-9103' || fail "case3 missing from check output"
echo "$CHECK_OUT" | grep -q 'INFRA-9104' || fail "case4 missing from check output"
echo "$CHECK_OUT" | grep -q 'yaml-only' || fail "case1 expected kind 'yaml-only' missing"
echo "$CHECK_OUT" | grep -q 'db-only' || fail "case2 expected kind 'db-only' missing"
echo "$CHECK_OUT" | grep -q 'divergent' || fail "divergent kind missing (case3+case4)"
pass "check reported all 4 drift cases + non-zero exit ($CHECK_RC)"

# ── 2. `sync --pull` updates DB for cases 1, 3, 4 ───────────────────────
info "step 2: chump gap sync --pull (expect DB updates)"
set +e
PULL_OUT="$("$CHUMP_BIN" gap sync --pull --state-db "$FAKE_DB" --gaps-dir "$FAKE_ROOT/docs/gaps" --json 2>&1)"
PULL_RC=$?
set -e
[[ $PULL_RC -eq 0 ]] || fail "pull exited non-zero: $PULL_RC. Output:\n$PULL_OUT"
echo "$PULL_OUT" | grep -q '"inserted":1' || fail "pull should insert exactly 1 row (case1). Output:\n$PULL_OUT"
echo "$PULL_OUT" | grep -q '"updated":2' || fail "pull should update exactly 2 rows (case3, case4). Output:\n$PULL_OUT"
pass "pull reported 1 insert + 2 updates"

# Verify case1 inserted into DB.
INSERTED_TITLE=$(sqlite3 "$FAKE_DB" "SELECT title FROM gaps WHERE id='INFRA-9101';")
[[ "$INSERTED_TITLE" == "case1-yaml-only" ]] \
    || fail "case1 title in DB: expected 'case1-yaml-only', got '$INSERTED_TITLE'"
pass "case1 row inserted into DB"

# Verify case3 AC was overwritten from TODO to the concrete YAML version.
CASE3_AC=$(sqlite3 "$FAKE_DB" "SELECT acceptance_criteria FROM gaps WHERE id='INFRA-9103';")
if echo "$CASE3_AC" | grep -q 'TODO'; then
    fail "case3 AC still has TODO: $CASE3_AC"
fi
echo "$CASE3_AC" | grep -q 'concrete recovered AC' \
    || fail "case3 AC missing concrete content: $CASE3_AC"
pass "case3 TODO-AC recovered from YAML"

# Verify case4 title was updated.
CASE4_TITLE=$(sqlite3 "$FAKE_DB" "SELECT title FROM gaps WHERE id='INFRA-9104';")
[[ "$CASE4_TITLE" == "case4-YAML-NOW-WINS" ]] \
    || fail "case4 title in DB: expected 'case4-YAML-NOW-WINS', got '$CASE4_TITLE'"
pass "case4 title updated from YAML"

# ── 3. `sync --check` now reports only case2 (still no YAML) ────────────
info "step 3: chump gap sync --check after pull (expect only case2 drift)"
set +e
CHECK_OUT2="$("$CHUMP_BIN" gap sync --check --state-db "$FAKE_DB" --gaps-dir "$FAKE_ROOT/docs/gaps" --json 2>&1)"
CHECK_RC2=$?
set -e
[[ $CHECK_RC2 -ne 0 ]] || fail "expected non-zero (case2 still missing); got 0"
echo "$CHECK_OUT2" | grep -q 'INFRA-9102' || fail "case2 should still be in drift report"
echo "$CHECK_OUT2" | grep -q 'INFRA-9101' && fail "case1 should be clean now"
echo "$CHECK_OUT2" | grep -q 'INFRA-9103' && fail "case3 should be clean now"
echo "$CHECK_OUT2" | grep -q 'INFRA-9104' && fail "case4 should be clean now"
pass "post-pull check: only case2 remains as drift"

# ── 4. `sync --push` writes the missing YAML for case2 ──────────────────
info "step 4: chump gap sync --push (expect case2 YAML created)"
set +e
PUSH_OUT="$("$CHUMP_BIN" gap sync --push --state-db "$FAKE_DB" --gaps-dir "$FAKE_ROOT/docs/gaps" --json 2>&1)"
PUSH_RC=$?
set -e
[[ $PUSH_RC -eq 0 ]] || fail "push exited non-zero: $PUSH_RC. Output:\n$PUSH_OUT"
[[ -f "$FAKE_ROOT/docs/gaps/INFRA-9102.yaml" ]] \
    || fail "case2 YAML not created at $FAKE_ROOT/docs/gaps/INFRA-9102.yaml"
grep -q 'case2-db-only' "$FAKE_ROOT/docs/gaps/INFRA-9102.yaml" \
    || fail "case2 YAML missing title"
grep -q 'only-in-db' "$FAKE_ROOT/docs/gaps/INFRA-9102.yaml" \
    || fail "case2 YAML missing AC"
pass "case2 YAML written by push"

# ── 5. Final `sync --check` reports clean ───────────────────────────────
info "step 5: chump gap sync --check after push (expect clean)"
set +e
CHECK_OUT3="$("$CHUMP_BIN" gap sync --check --state-db "$FAKE_DB" --gaps-dir "$FAKE_ROOT/docs/gaps" 2>&1)"
CHECK_RC3=$?
set -e
[[ $CHECK_RC3 -eq 0 ]] \
    || fail "expected clean post-push; got exit $CHECK_RC3. Output:\n$CHECK_OUT3"
echo "$CHECK_OUT3" | grep -q 'clean' || fail "expected 'clean' in output: $CHECK_OUT3"
pass "post-push check: tree is clean"

# ── 6. dry-run --pull does not mutate ───────────────────────────────────
info "step 6: dry-run pull does not mutate"
# Re-seed a divergence to test dry-run.
sqlite3 "$FAKE_DB" "UPDATE gaps SET title='dry-run-stale' WHERE id='INFRA-9101';"
PRE_DRY_TITLE=$(sqlite3 "$FAKE_DB" "SELECT title FROM gaps WHERE id='INFRA-9101';")
[[ "$PRE_DRY_TITLE" == "dry-run-stale" ]] || fail "seeding for dry-run failed"
"$CHUMP_BIN" gap sync --pull --dry-run --state-db "$FAKE_DB" --gaps-dir "$FAKE_ROOT/docs/gaps" >/dev/null 2>&1
POST_DRY_TITLE=$(sqlite3 "$FAKE_DB" "SELECT title FROM gaps WHERE id='INFRA-9101';")
[[ "$POST_DRY_TITLE" == "dry-run-stale" ]] \
    || fail "dry-run pull mutated DB (title now '$POST_DRY_TITLE')"
pass "dry-run --pull left DB untouched"

printf '\n[ALL PASS] test-gap-sync.sh\n'
