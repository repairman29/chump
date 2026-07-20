#!/usr/bin/env bash
# test-zero-waste-020.sh — ZERO-WASTE-020: retire YAML gap mirrors.
#
# Verifies the retirement actually stuck:
#   1. docs/gaps/ contains no per-gap YAML mirrors (only the tombstone
#      README.md + the unrelated TEMPLATES/ pillar-template dir).
#   2. `chump gap show <ID>` still works (reads state.db, not YAML).
#   3. `chump gap set <ID> --notes ...` mutates state.db and does NOT
#      write a docs/gaps/<ID>.yaml mirror (the regression this whole gap
#      exists to prevent — pre-fix, `gap set`/`gap reserve`/`gap ship
#      --update-yaml`/`decompose` all wrote a per-file mirror whenever
#      docs/gaps/ existed as a directory).
#   4. The gaps-lock pre-commit guard's own trigger condition — staged
#      docs/gaps/*.yaml (added/copied/modified) — cannot fire on a
#      realistic registry-touching commit, because nothing writes YAML
#      there anymore. Reads the live regex out of
#      scripts/git-hooks/pre-commit so this test can't drift out of sync
#      with the guard it's checking.
#
# Run: ./scripts/ci/test-zero-waste-020.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }
info() { echo "  INFO: $1"; }

echo "=== ZERO-WASTE-020: YAML gap mirrors retired ==="
echo

# ── Test 1: docs/gaps/ has no per-gap YAML mirrors ────────────────────────
echo "--- Test 1: docs/gaps/ contains no *.yaml mirrors ---"
_yaml_count=$(find "$REPO_ROOT/docs/gaps" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
if [[ "${_yaml_count:-1}" -eq 0 ]]; then
    ok "Test 1: 0 YAML files under docs/gaps/"
else
    fail "Test 1: ${_yaml_count} YAML file(s) still under docs/gaps/ (mirrors not fully retired)"
fi
if [[ -f "$REPO_ROOT/docs/gaps/README.md" ]]; then
    ok "Test 1b: docs/gaps/README.md tombstone present"
else
    fail "Test 1b: docs/gaps/README.md tombstone missing"
fi

# ── Locate / build the chump binary ────────────────────────────────────────
CHUMP_BIN=""
for cand in \
    "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" \
    "$REPO_ROOT/target/debug/chump" \
    "$HOME/.cargo/bin/chump"; do
    if [[ -x "$cand" ]]; then
        CHUMP_BIN="$cand"
        break
    fi
done
if [[ -z "$CHUMP_BIN" ]]; then
    info "chump binary not found, building..."
    (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --bin chump --quiet)
    CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
fi
info "using chump: $CHUMP_BIN"

# ── Fixture: hermetic repo root + isolated state.db (never touches the
#    real .chump/state.db or docs/gaps/) ────────────────────────────────────
TMP="$(mktemp -d -t test-zero-waste-020.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FIXTURE_REPO="$TMP/fixture-repo"
mkdir -p "$FIXTURE_REPO/docs/gaps" "$FIXTURE_REPO/.chump" "$FIXTURE_REPO/.chump-locks"
cp "$REPO_ROOT/docs/gaps/README.md" "$FIXTURE_REPO/docs/gaps/README.md"
FIXTURE_DB="$FIXTURE_REPO/.chump/state.db"

sqlite3 "$FIXTURE_DB" <<'SCHEMA'
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
INSERT INTO gaps (id, domain, title, description, priority, effort, status, acceptance_criteria)
VALUES ('ZW020-FIXTURE-1', 'ZERO-WASTE', 'fixture gap for test-zero-waste-020', 'fixture', 'P2', 'xs', 'open', '["fixture AC"]');
SCHEMA

export CHUMP_AMBIENT_DISABLE=1
export CHUMP_STATE_DB="$FIXTURE_DB"
export CHUMP_REPO="$FIXTURE_REPO"
export CHUMP_HOME="$FIXTURE_REPO"

# ── Test 2: `chump gap show` works against state.db ────────────────────────
echo "--- Test 2: chump gap show <ID> works ---"
_show_out=$("$CHUMP_BIN" gap show ZW020-FIXTURE-1 2>&1)
_show_rc=$?
if [[ $_show_rc -eq 0 ]] && echo "$_show_out" | grep -q "ZW020-FIXTURE-1"; then
    ok "Test 2: chump gap show ZW020-FIXTURE-1 succeeded"
else
    fail "Test 2: chump gap show failed (rc=$_show_rc): $_show_out"
fi

# ── Test 3: `chump gap set --notes` mutates DB, writes no YAML ─────────────
echo "--- Test 3: chump gap set --notes works without writing YAML ---"
_set_out=$("$CHUMP_BIN" gap set ZW020-FIXTURE-1 --notes "zero-waste-020 regression check" 2>&1)
_set_rc=$?
_yaml_after=$(find "$FIXTURE_REPO/docs/gaps" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
_notes_in_db=$(sqlite3 "$FIXTURE_DB" "SELECT notes FROM gaps WHERE id='ZW020-FIXTURE-1';")
if [[ $_set_rc -eq 0 ]]; then
    ok "Test 3a: chump gap set exited 0"
else
    fail "Test 3a: chump gap set failed (rc=$_set_rc): $_set_out"
fi
if [[ "$_notes_in_db" == "zero-waste-020 regression check" ]]; then
    ok "Test 3b: state.db notes field updated"
else
    fail "Test 3b: state.db notes not updated (got: '${_notes_in_db}')"
fi
if [[ "${_yaml_after:-1}" -eq 0 ]]; then
    ok "Test 3c: no docs/gaps/*.yaml written by gap set (0 files)"
else
    fail "Test 3c: gap set wrote ${_yaml_after} YAML file(s) under docs/gaps/ — mirror write path not fully retired"
fi

unset CHUMP_STATE_DB CHUMP_REPO CHUMP_HOME CHUMP_AMBIENT_DISABLE

# ── Test 4: gaps-lock guard's own trigger can't fire on a registry-touching
#    commit, because nothing stages docs/gaps/*.yaml anymore. Extracts the
#    live regex from the hook so this test tracks the real guard, not a
#    hand-copied pattern that could drift. ─────────────────────────────────
echo "--- Test 4: gaps-lock guard trigger does not fire post-retirement ---"
_guard_pattern=$(grep -oE "diff-filter=ACM \| grep -qE '[^']+'" "$REPO_ROOT/scripts/git-hooks/pre-commit" | head -1 | grep -oE "'[^']+'" | tr -d "'")
if [[ -z "$_guard_pattern" ]]; then
    fail "Test 4: could not extract gaps-lock trigger regex from scripts/git-hooks/pre-commit (guard logic may have moved)"
else
    info "extracted trigger regex: $_guard_pattern"
    SANDBOX="$TMP/sandbox-repo"
    mkdir -p "$SANDBOX/docs/gaps" "$SANDBOX/.chump"
    (
        cd "$SANDBOX" || exit 1
        git init -q
        git config user.email test@example.com
        git config user.name "Test"
        cp "$REPO_ROOT/docs/gaps/README.md" docs/gaps/README.md
        echo "-- fixture dump --" > .chump/state.sql
        git add -A
    )
    # Simulate a realistic registry-touching commit: state.sql (the tracked
    # dump) + the tombstone README, gap-ID-prefixed subject. Assert the
    # guard's own ACM+.yaml-suffix trigger does not match any staged path.
    _staged=$(cd "$SANDBOX" && git diff --cached --name-only --diff-filter=ACM)
    if echo "$_staged" | grep -qE "$_guard_pattern"; then
        fail "Test 4: gaps-lock trigger matched a staged path in a registry-touching commit with no YAML: $(echo "$_staged" | grep -E "$_guard_pattern")"
    else
        ok "Test 4: gaps-lock trigger did not match any staged path (guard stays inert)"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
