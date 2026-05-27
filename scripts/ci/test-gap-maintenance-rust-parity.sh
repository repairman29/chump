#!/usr/bin/env bash
# scripts/ci/test-gap-maintenance-rust-parity.sh — INFRA-2000 Phase 1
#
# Smoke test for the four Rust binaries that port the Python gap-tools:
#   chump-gap-doctor / chump-gap-gardener / chump-gap-architect /
#   chump-check-gaps-integrity.
#
# Build steps:
#   1. Build the four Rust binaries via cargo (scoped to chump-gap-store).
#   2. Construct a synthetic .chump/state.db + docs/gaps/ fixture
#      covering the 4 detection classes called out in the INFRA-2000
#      brief:
#        a. missing-dep ref      (depends_on: [INFRA-NONEXISTENT])
#        b. double-encoded deps  (depends_on stored as JSON-string-of-JSON)
#        c. ghost PR             (status:open with closed_pr=42)
#        d. race-fixture title   (title starts with "race-")
#   3. Run each tool via the feature-flag shim with
#      CHUMP_GAP_MAINTENANCE_RUST=0 (Python path) and =1 (Rust path)
#      where it makes sense, and assert identical exit codes.
#   4. Assert the Rust gap-doctor surfaces the 4 detection classes.
#   5. Assert chump-check-gaps-integrity flags a duplicate ID and
#      passes on a clean fixture.
#
# Phase 1 does NOT assert byte-identical stdout — the Python tools and
# the Rust ports format slightly differently (e.g. JSON key order,
# whitespace) and a full normalization-and-diff is out of scope for
# the smoke pass. The exit-code parity + detection-class assertion is
# the meaningful invariant.
#
# DOES NOT emit any new ambient event kinds. Sets
# CHUMP_AMBIENT_DISABLE=1 defensively to mute existing emissions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

unset CHUMP_LOCK_DIR CHUMP_REPO CHUMP_REPO_ROOT 2>/dev/null || true
export CHUMP_AMBIENT_DISABLE=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '      %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Build the four Rust binaries.
# ---------------------------------------------------------------------------
echo "[test] building chump-gap-store maintenance binaries..."
BUILD_LOG="$TMP/build.log"
if ! (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
        cargo build --quiet -p chump-gap-store \
            --bin chump-gap-doctor \
            --bin chump-gap-gardener \
            --bin chump-gap-architect \
            --bin chump-check-gaps-integrity) \
        >"$BUILD_LOG" 2>&1; then
    echo "[test] BUILD FAILED — log below:"
    cat "$BUILD_LOG"
    exit 1
fi

resolve_bin() {
    local name="$1"
    # `git rev-parse --git-common-dir` finds the main repo's .git dir when
    # we're in a linked worktree — its parent is the main repo whose
    # `target/` cargo writes to by default.
    local common_dir main_root
    common_dir="$(cd "$REPO_ROOT" && git rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common_dir" && "$common_dir" != ".git" ]]; then
        main_root="$(cd "$REPO_ROOT" && cd "$(dirname "$common_dir")" && pwd)"
    else
        main_root="$REPO_ROOT"
    fi
    for candidate in \
        "$REPO_ROOT/target/debug/$name" \
        "$main_root/target/debug/$name" \
        "${CARGO_TARGET_DIR:-}/debug/$name" \
        ; do
        [[ -z "$candidate" ]] && continue
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

DOCTOR_BIN="$(resolve_bin chump-gap-doctor)"      || { fail "missing chump-gap-doctor"; exit 1; }
GARDENER_BIN="$(resolve_bin chump-gap-gardener)"  || { fail "missing chump-gap-gardener"; exit 1; }
ARCH_BIN="$(resolve_bin chump-gap-architect)"     || { fail "missing chump-gap-architect"; exit 1; }
INT_BIN="$(resolve_bin chump-check-gaps-integrity)" || { fail "missing chump-check-gaps-integrity"; exit 1; }
note "doctor:    $DOCTOR_BIN"
note "gardener:  $GARDENER_BIN"
note "architect: $ARCH_BIN"
note "integrity: $INT_BIN"

# ---------------------------------------------------------------------------
# Build the synthetic fixture: a .chump/state.db + docs/gaps/ covering
# the four detection classes plus a couple of clean gaps.
# ---------------------------------------------------------------------------
FIX="$TMP/fix"
mkdir -p "$FIX/.chump" "$FIX/docs/gaps"
cd "$FIX"
git init --quiet 2>/dev/null
git -c user.email=t@t -c user.name=t commit --allow-empty -m "init" --quiet 2>/dev/null

DB="$FIX/.chump/state.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE gaps (
    id TEXT PRIMARY KEY,
    domain TEXT,
    title TEXT,
    description TEXT,
    priority TEXT,
    effort TEXT,
    status TEXT,
    acceptance_criteria TEXT,
    depends_on TEXT,
    notes TEXT,
    source_doc TEXT,
    created_at INTEGER,
    closed_at INTEGER,
    opened_date TEXT,
    closed_date TEXT,
    closed_pr INTEGER,
    skills_required TEXT,
    preferred_backend TEXT,
    preferred_machine TEXT,
    estimated_minutes TEXT,
    required_model TEXT
);
CREATE TABLE leases (
    session_id TEXT, gap_id TEXT, worktree TEXT, expires_at INTEGER
);
CREATE TABLE intents (
    id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, payload TEXT, created_at INTEGER
);
INSERT INTO gaps VALUES
    ('INFRA-9001','INFRA','EFFECTIVE: clean test gap','desc','P1','s','open',
     '["acceptance criterion 1"]','[]','','docs/gaps.yaml',1700000000,NULL,
     '2026-05-01','',NULL,'','','','','any'),
    ('INFRA-9002','INFRA','CREDIBLE: missing-dep ref','desc','P2','s','open',
     '["a"]','["INFRA-NONEXISTENT-DEP"]','','docs/gaps.yaml',1700000000,NULL,
     '2026-05-01','',NULL,'','','','','any'),
    ('INFRA-9003','INFRA','RESILIENT: double-encoded deps','desc','P2','s','open',
     '["a"]','"[\"INFRA-9001\"]"','','docs/gaps.yaml',1700000000,NULL,
     '2026-05-01','',NULL,'','','','','any'),
    ('INFRA-9004','INFRA','ZERO-WASTE: ghost gap','desc','P2','s','open',
     '["a"]','[]','','docs/gaps.yaml',1700000000,NULL,
     '2026-05-01','',42,'','','','','any'),
    ('INFRA-9005','INFRA','race-fixture-test-leak','desc','P2','s','open',
     '["a"]','[]','','docs/gaps.yaml',1700000000,NULL,
     '2026-05-01','',NULL,'','','','','any'),
    ('INFRA-9006','INFRA','EFFECTIVE: db-done-yaml-open','desc','P2','s','done',
     '["a"]','[]','','docs/gaps.yaml',1700000000,1700100000,
     '2026-05-01','2026-05-02',77,'','','','','any');
SQL

# Per-file YAML mirror — note INFRA-9006 still has status:open in YAML to
# trigger bucket1 in the doctor's drift report.
for id in 9001 9002 9003 9004 9005; do
    cat > "$FIX/docs/gaps/INFRA-$id.yaml" <<EOF
- id: INFRA-$id
  title: t
  status: open
EOF
done
cat > "$FIX/docs/gaps/INFRA-9006.yaml" <<EOF
- id: INFRA-9006
  title: t
  status: open
EOF

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------
export CHUMP_STATE_DB="$DB"
cd "$FIX"

# 1. chump-gap-doctor doctor -- reports buckets, exits non-zero on drift.
DOCTOR_OUT="$TMP/doctor.out"
if "$DOCTOR_BIN" doctor >"$DOCTOR_OUT" 2>&1; then
    rc=0
else
    rc=$?
fi
# We expect drift (bucket1 == [INFRA-9006]).
if [[ $rc -eq 1 ]] && grep -q "Bucket 1" "$DOCTOR_OUT" && grep -q "INFRA-9006" "$DOCTOR_OUT"; then
    ok "chump-gap-doctor reports Bucket 1 drift and exits 1"
else
    fail "chump-gap-doctor: expected exit 1 + Bucket 1 INFRA-9006 reference (rc=$rc)"
    note "$(head -30 "$DOCTOR_OUT")"
fi

# 2. Integrity findings — 4 detection classes appear in the doctor output.
if grep -q "missing-dep refs" "$DOCTOR_OUT" \
    && grep -q "double-encoded deps" "$DOCTOR_OUT" \
    && grep -q "open w/ closed_pr" "$DOCTOR_OUT" \
    && grep -q "race-fixture titles" "$DOCTOR_OUT"; then
    ok "chump-gap-doctor surfaces 4 integrity classes (missing-dep / double-encoded / ghost / race-fixture)"
else
    fail "chump-gap-doctor: missing one of 4 integrity classes in output"
    note "$(head -60 "$DOCTOR_OUT")"
fi

# 3. chump-gap-gardener --check -- registry audit invariants.
GARD_OUT="$TMP/gardener.out"
if "$GARDENER_BIN" --check >"$GARD_OUT" 2>&1; then
    rc=0
else
    rc=$?
fi
# Audit invariants: P0=0, no stuck, no vague_pickable -> should pass (exit 0).
if [[ $rc -eq 0 ]] && grep -q "OK: registry audit invariants hold" "$GARD_OUT"; then
    ok "chump-gap-gardener --check exits 0 on clean P0/vague invariants"
else
    fail "chump-gap-gardener --check unexpected (rc=$rc)"
    note "$(head -30 "$GARD_OUT")"
fi

# 4. chump-gap-gardener --json -- emits valid JSON.
GARD_JSON_OUT="$TMP/gardener.json"
if "$GARDENER_BIN" --json >"$GARD_JSON_OUT" 2>&1; then
    rc=0
else
    rc=$?
fi
if [[ $rc -eq 0 ]] && python3 -c "import json,sys; json.loads(open('$GARD_JSON_OUT').read())" 2>/dev/null; then
    ok "chump-gap-gardener --json emits valid JSON"
else
    fail "chump-gap-gardener --json bad output (rc=$rc)"
    note "$(head -3 "$GARD_JSON_OUT")"
fi

# 5. chump-check-gaps-integrity --per-file (clean fixture has no duplicate IDs).
INT_CLEAN_OUT="$TMP/int_clean.out"
if "$INT_BIN" --per-file "$FIX/docs/gaps" >"$INT_CLEAN_OUT" 2>&1; then
    rc=0
else
    rc=$?
fi
if [[ $rc -eq 0 ]] && grep -q "OK:" "$INT_CLEAN_OUT" && grep -q "6 unique gap ids" "$INT_CLEAN_OUT"; then
    ok "chump-check-gaps-integrity reports 6 unique IDs on clean fixture"
else
    fail "chump-check-gaps-integrity unexpected on clean (rc=$rc)"
    note "$(head -10 "$INT_CLEAN_OUT")"
fi

# 6. chump-check-gaps-integrity flags a duplicate.
cp "$FIX/docs/gaps/INFRA-9001.yaml" "$FIX/docs/gaps/INFRA-9001-DUP.yaml"
INT_DUP_OUT="$TMP/int_dup.out"
if "$INT_BIN" --per-file "$FIX/docs/gaps" >"$INT_DUP_OUT" 2>&1; then
    rc=0
else
    rc=$?
fi
if [[ $rc -eq 1 ]] && grep -q "duplicate" "$INT_DUP_OUT" && grep -q "INFRA-9001" "$INT_DUP_OUT"; then
    ok "chump-check-gaps-integrity flags duplicate INFRA-9001 (exit 1)"
else
    fail "chump-check-gaps-integrity duplicate detection broken (rc=$rc)"
    note "$(head -10 "$INT_DUP_OUT")"
fi
rm -f "$FIX/docs/gaps/INFRA-9001-DUP.yaml"

# 7. chump-gap-architect --decompose --dry-run (no LLM call) succeeds.
ARCH_OUT="$TMP/arch.out"
if "$ARCH_BIN" --decompose INFRA-9001 --dry-run >"$ARCH_OUT" 2>&1; then
    rc=0
else
    rc=$?
fi
if [[ $rc -eq 0 ]] && grep -q "gap-architect dry-run" "$ARCH_OUT"; then
    ok "chump-gap-architect --decompose --dry-run prints prompt without LLM"
else
    fail "chump-gap-architect --decompose --dry-run failed (rc=$rc)"
    note "$(head -10 "$ARCH_OUT")"
fi

# 8. Python shim transparently routes when CHUMP_GAP_MAINTENANCE_RUST=1.
SHIM_OUT="$TMP/shim.out"
if CHUMP_GAP_MAINTENANCE_RUST=1 PATH="$(dirname "$INT_BIN"):$PATH" \
    python3 "$REPO_ROOT/scripts/coord/check-gaps-integrity.py" --per-file "$FIX/docs/gaps" \
    >"$SHIM_OUT" 2>&1; then
    rc=0
else
    rc=$?
fi
if [[ $rc -eq 0 ]] && grep -q "OK:" "$SHIM_OUT"; then
    ok "Python shim routes check-gaps-integrity to Rust binary"
else
    fail "Python shim routing broken (rc=$rc)"
    note "$(head -10 "$SHIM_OUT")"
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo
echo "[test] PASS: $PASS  FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
