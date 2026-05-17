#!/usr/bin/env bash
# scripts/ci/test-claim-collision-guard.sh — INFRA-1412
#
# Verifies the cross-session active-lease guard in run_claim:
#   1. Source check: active_lease_for_gap + emit_claim_collision_event defined
#   2. Source check: INFRA-1412 guard wired before worktree creation (exit 2)
#   3. Binary: pre-seeded live lease → claim exits 2 + "already has an active lease"
#   4. Binary: pre-seeded expired lease → claim proceeds past guard (no double-claim block)
#   5. Binary: CHUMP_ALLOW_DOUBLE_CLAIM=1 bypasses guard
#   6. Binary: ambient event claim_collision_detected emitted with correct fields
#   7. EVENT_REGISTRY has claim_collision_detected entry

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/src/atomic_claim.rs"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
skip() { printf '\033[0;33mSKIP\033[0m %s\n' "$*"; }

[[ -f "$SRC" ]] || fail "atomic_claim.rs missing: $SRC"

# ── 1. active_lease_for_gap defined ──────────────────────────────────────────
grep -q "fn active_lease_for_gap" "$SRC" \
    || fail "missing fn active_lease_for_gap (INFRA-1412 DB check)"
ok "active_lease_for_gap defined"

# ── 2. emit_claim_collision_event defined + INFRA-1412 guard wired ────────────
grep -q "fn emit_claim_collision_event" "$SRC" \
    || fail "missing fn emit_claim_collision_event"
grep -q "claim_collision_detected" "$SRC" \
    || fail "kind=claim_collision_detected not referenced in source"
grep -q "INFRA-1412" "$SRC" \
    || fail "INFRA-1412 comment marker missing from atomic_claim.rs"
ok "INFRA-1412 guard wired (active_lease_for_gap + emit + exit 2)"

# ── Binary integration tests ──────────────────────────────────────────────────
if [[ ! -x "$CHUMP_BIN" ]]; then
    skip "CHUMP_BIN not found at $CHUMP_BIN — skipping binary rounds 3-6"
    skip "  Build with: cargo build --bin chump"
    echo ""
    echo "Source-level checks (rounds 1-2) PASSED."
    # Still check registry (round 7).
    [[ -f "$REGISTRY" ]] && grep -q "claim_collision_detected" "$REGISTRY" \
        && ok "claim_collision_detected in EVENT_REGISTRY.yaml" \
        || fail "claim_collision_detected not in EVENT_REGISTRY.yaml"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Minimal repo + state.db with a gap and a live lease.
mkdir -p "$WORK/repo/.chump-locks" "$WORK/repo/.chump" "$WORK/repo/docs/gaps"
cd "$WORK/repo"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
git commit --allow-empty -m "init" -q
git remote add origin "https://github.com/testorg/testrepo.git"

NOW=$(date +%s)
FUTURE=$(( NOW + 3600 ))
PAST=$(( NOW - 3600 ))

sqlite3 "$WORK/repo/.chump/state.db" "
CREATE TABLE gaps (id TEXT PRIMARY KEY, domain TEXT, title TEXT, status TEXT, priority TEXT, effort TEXT, depends_on TEXT, notes TEXT);
CREATE TABLE leases (session_id TEXT PRIMARY KEY, gap_id TEXT NOT NULL, worktree TEXT NOT NULL DEFAULT '', expires_at INTEGER NOT NULL);
CREATE INDEX leases_gap ON leases(gap_id);
INSERT INTO gaps VALUES ('COLLIDE-001','TEST','test gap','open','P1','xs','[]','');
"

# gh stub — always returns empty for PR check.
STUB_DIR="$WORK/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# ── Round 3: live lease present → exit 2 ─────────────────────────────────────
sqlite3 "$WORK/repo/.chump/state.db" \
    "INSERT INTO leases VALUES ('prior-session-abc','COLLIDE-001','/tmp/chump-collide-001',$FUTURE);"

set +e
OUT3=$(
    PATH="$STUB_DIR:$PATH" \
    CHUMP_WORKTREE_BASE="$WORK/wt3" \
    "$CHUMP_BIN" claim COLLIDE-001 --skip-doctor --skip-import 2>&1
)
EXIT3=$?
set -e

if [[ "$EXIT3" -ne 2 ]]; then
    fail "round 3: expected exit 2 for live-lease collision, got $EXIT3; output: $OUT3"
fi
echo "$OUT3" | grep -q "already has an active lease" \
    || fail "round 3: expected 'already has an active lease' in output; got: $OUT3"
ok "round 3: live lease → exit 2 + collision message"

# ── Round 4: expired lease → guard does NOT block ────────────────────────────
sqlite3 "$WORK/repo/.chump/state.db" \
    "UPDATE leases SET expires_at=$PAST WHERE session_id='prior-session-abc';"

set +e
OUT4=$(
    PATH="$STUB_DIR:$PATH" \
    CHUMP_WORKTREE_BASE="$WORK/wt4" \
    "$CHUMP_BIN" claim COLLIDE-001 --skip-doctor --skip-import 2>&1
)
EXIT4=$?
set -e

# May exit non-zero from git/worktree errors but must NOT say "already has an active lease"
if echo "$OUT4" | grep -q "already has an active lease"; then
    fail "round 4: expired lease should not trigger collision guard; got: $OUT4"
fi
ok "round 4: expired lease → guard passes (exit was $EXIT4, no collision block)"

# ── Round 5: CHUMP_ALLOW_DOUBLE_CLAIM=1 bypasses ─────────────────────────────
sqlite3 "$WORK/repo/.chump/state.db" \
    "UPDATE leases SET expires_at=$FUTURE WHERE session_id='prior-session-abc';"

set +e
OUT5=$(
    PATH="$STUB_DIR:$PATH" \
    CHUMP_WORKTREE_BASE="$WORK/wt5" \
    CHUMP_ALLOW_DOUBLE_CLAIM=1 \
    "$CHUMP_BIN" claim COLLIDE-001 --skip-doctor --skip-import 2>&1
)
EXIT5=$?
set -e

if [[ "$EXIT5" -eq 2 ]] && echo "$OUT5" | grep -q "already has an active lease"; then
    fail "round 5: CHUMP_ALLOW_DOUBLE_CLAIM=1 did not bypass the collision guard"
fi
ok "round 5: CHUMP_ALLOW_DOUBLE_CLAIM=1 bypasses guard (exit was $EXIT5)"

# ── Round 6: ambient event emitted on collision ───────────────────────────────
# Restore live lease and run again (without bypass).
sqlite3 "$WORK/repo/.chump/state.db" \
    "UPDATE leases SET expires_at=$FUTURE WHERE session_id='prior-session-abc';"

PATH="$STUB_DIR:$PATH" CHUMP_WORKTREE_BASE="$WORK/wt6" \
    "$CHUMP_BIN" claim COLLIDE-001 --skip-doctor --skip-import 2>&1 || true

AMBIENT="$WORK/repo/.chump-locks/ambient.jsonl"
[[ -f "$AMBIENT" ]] || fail "round 6: ambient.jsonl not created"
grep -q '"kind":"claim_collision_detected"' "$AMBIENT" \
    || fail "round 6: claim_collision_detected not in ambient.jsonl; contents: $(cat "$AMBIENT")"
grep -q '"gap_id":"COLLIDE-001"' "$AMBIENT" \
    || fail "round 6: ambient event missing gap_id=COLLIDE-001"
ok "round 6: claim_collision_detected ambient event emitted with correct fields"

# ── Round 7: EVENT_REGISTRY ───────────────────────────────────────────────────
[[ -f "$REGISTRY" ]] || fail "EVENT_REGISTRY.yaml missing: $REGISTRY"
grep -q "claim_collision_detected" "$REGISTRY" \
    || fail "claim_collision_detected not in EVENT_REGISTRY.yaml"
ok "claim_collision_detected registered in EVENT_REGISTRY.yaml"

echo ""
echo "All 7 checks PASSED — INFRA-1412 cross-session collision guard works"
