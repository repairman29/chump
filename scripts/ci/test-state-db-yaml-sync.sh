#!/usr/bin/env bash
# test-state-db-yaml-sync.sh — INFRA-1495
#
# Verifies scripts/coord/state-db-yaml-sync.sh:
#   - seeds state.db with N gaps (mixed open/done/superseded), removes the
#     YAML mirror for M of the open ones
#   - --dry-run reports exactly M orphans, writes nothing
#   - --apply writes exactly M YAML files, one per open orphan
#   - done/superseded gaps never get a YAML mirror written, even when their
#     YAML is also missing (CREDIBLE-012)
#
# Uses a tempdir + temp state.db + temp docs/gaps dir; never touches the
# real .chump/state.db or docs/gaps/. Ambient writes are disabled.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

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

TMP="$(mktemp -d -t test-infra-1495.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FAKE_ROOT="$TMP/fake-root"
mkdir -p "$FAKE_ROOT/docs/gaps" "$FAKE_ROOT/.chump"
FAKE_DB="$FAKE_ROOT/.chump/state.db"

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
[[ -f "$FAKE_DB" ]] || fail "state.db was not initialised at $FAKE_DB"
info "state.db initialised: $FAKE_DB"

# ── Seed N=5 gaps: 3 open (2 orphan, 1 has YAML already), 1 done, 1 superseded ──
sqlite3 "$FAKE_DB" "INSERT INTO gaps(id, domain, title, status, priority, effort, acceptance_criteria, depends_on, created_at) VALUES
('INFRA-9201','INFRA','open-orphan-1','open','P2','s','[\"ac\"]','[]',100),
('INFRA-9202','INFRA','open-orphan-2','open','P2','s','[\"ac\"]','[]',100),
('INFRA-9203','INFRA','open-has-yaml','open','P2','s','[\"ac\"]','[]',100),
('INFRA-9204','INFRA','done-no-yaml','done','P2','s','[\"ac\"]','[]',100),
('INFRA-9205','INFRA','superseded-no-yaml','superseded','P2','s','[\"ac\"]','[]',100);
"

# INFRA-9203 already has a YAML mirror — must not be touched/counted.
cat > "$FAKE_ROOT/docs/gaps/INFRA-9203.yaml" <<'EOF'
- id: INFRA-9203
  domain: INFRA
  title: open-has-yaml
  status: open
  priority: P2
  effort: s
EOF

export CHUMP_AMBIENT_DISABLE=1
export CHUMP_STATE_DB="$FAKE_DB"
export CHUMP_BIN="$CHUMP_BIN"
export STATE_DB_YAML_SYNC_GAPS_DIR="$FAKE_ROOT/docs/gaps"
export STATE_DB_YAML_SYNC_SKIP_COMMIT=1

SYNC_SCRIPT="$REPO_ROOT/scripts/coord/state-db-yaml-sync.sh"
[[ -x "$SYNC_SCRIPT" ]] || fail "$SYNC_SCRIPT missing or not executable"

# ── 1. --dry-run reports exactly 2 orphans (INFRA-9201, INFRA-9202); writes nothing ──
info "step 1: state-db-yaml-sync.sh --dry-run (expect 2 orphans, M=2)"
DRY_OUT="$("$SYNC_SCRIPT" --dry-run)"
echo "$DRY_OUT" | grep -q '2 orphan' || fail "dry-run should report 2 orphans. Output:\n$DRY_OUT"
echo "$DRY_OUT" | grep -q 'INFRA-9201' || fail "INFRA-9201 missing from dry-run output"
echo "$DRY_OUT" | grep -q 'INFRA-9202' || fail "INFRA-9202 missing from dry-run output"
echo "$DRY_OUT" | grep -q 'INFRA-9203' && fail "INFRA-9203 (already has YAML) should not appear as orphan"
echo "$DRY_OUT" | grep -q 'INFRA-9204' && fail "INFRA-9204 (done) should never appear as orphan"
echo "$DRY_OUT" | grep -q 'INFRA-9205' && fail "INFRA-9205 (superseded) should never appear as orphan"
[[ -f "$FAKE_ROOT/docs/gaps/INFRA-9201.yaml" ]] && fail "dry-run must not write INFRA-9201.yaml"
[[ -f "$FAKE_ROOT/docs/gaps/INFRA-9202.yaml" ]] && fail "dry-run must not write INFRA-9202.yaml"
pass "dry-run found exactly 2 orphans and wrote nothing"

# ── 2. --apply writes exactly 2 YAML files, leaves done/superseded untouched ──
info "step 2: state-db-yaml-sync.sh --apply (expect 2 YAML files written)"
APPLY_OUT="$("$SYNC_SCRIPT" --apply)"
echo "$APPLY_OUT" | grep -q '2 orphan' || fail "apply should also report 2 orphans. Output:\n$APPLY_OUT"
[[ -f "$FAKE_ROOT/docs/gaps/INFRA-9201.yaml" ]] || fail "apply did not write INFRA-9201.yaml"
[[ -f "$FAKE_ROOT/docs/gaps/INFRA-9202.yaml" ]] || fail "apply did not write INFRA-9202.yaml"
grep -q 'id: INFRA-9201' "$FAKE_ROOT/docs/gaps/INFRA-9201.yaml" || fail "INFRA-9201.yaml missing expected id field"
[[ -f "$FAKE_ROOT/docs/gaps/INFRA-9204.yaml" ]] && fail "CREDIBLE-012 violation: YAML written for done gap INFRA-9204"
[[ -f "$FAKE_ROOT/docs/gaps/INFRA-9205.yaml" ]] && fail "CREDIBLE-012 violation: YAML written for superseded gap INFRA-9205"
pass "apply wrote exactly 2 YAML mirrors; done/superseded gaps untouched"

# ── 3. Rerunning --dry-run now reports 0 orphans (converged) ────────────
info "step 3: state-db-yaml-sync.sh --dry-run after apply (expect 0 orphans)"
CONVERGED_OUT="$("$SYNC_SCRIPT" --dry-run)"
echo "$CONVERGED_OUT" | grep -q '0 orphan' || fail "expected convergence to 0 orphans. Output:\n$CONVERGED_OUT"
pass "sweep converges to 0 orphans after backfill"

echo
echo "=== INFRA-1495 state-db-yaml-sync test: all checks passed ==="
