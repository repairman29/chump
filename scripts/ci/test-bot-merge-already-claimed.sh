#!/usr/bin/env bash
# scripts/ci/test-bot-merge-already-claimed.sh — INFRA-1901
#
# Reproduces the 2026-05-23 failure class: bot-merge.sh invoked from inside a
# worktree that already holds the gap's canonical lease used to unconditionally
# re-invoke `chump claim`, and 3/4 sub-agents (INFRA-1586, INFRA-1585,
# INFRA-1743) hit its failure path and were forced into manual `gh pr create`
# / `gh pr merge --auto` recovery.
#
# The fix lives inline in the "claim" step of scripts/coord/bot-merge.sh,
# bracketed by BOT_MERGE_CLAIM_BLOCK_START/END anchor comments. Running the
# whole script end-to-end needs a live git remote + `chump`/`gh` state that's
# too heavy for a CI smoke test, so this test extracts the real claim-block
# source between those anchors and evaluates it against synthetic lease
# fixtures + a stub `chump` that fails loudly if `claim` is ever invoked —
# proving the fix, not a reimplementation of it.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
LEASE_LIB="$REPO_ROOT/scripts/lib/lease.sh"

echo "=== INFRA-1901 bot-merge already-claimed test ==="
echo

[[ -f "$BOT_MERGE" ]] || { fail "bot-merge.sh missing"; echo "FAIL"; exit 1; }
[[ -f "$LEASE_LIB" ]] || { fail "lease.sh missing"; echo "FAIL"; exit 1; }

# ── Extract the real claim block between the anchor comments ──────────────────
CLAIM_BLOCK="$(sed -n '/BOT_MERGE_CLAIM_BLOCK_START/,/BOT_MERGE_CLAIM_BLOCK_END/p' "$BOT_MERGE")"
if [[ -n "$CLAIM_BLOCK" ]]; then
    ok "extracted claim block from bot-merge.sh (BOT_MERGE_CLAIM_BLOCK_START/END anchors present)"
else
    fail "could not find BOT_MERGE_CLAIM_BLOCK_START/END anchors in bot-merge.sh"
fi

if echo "$CLAIM_BLOCK" | grep -q '_skip_claim=1'; then
    ok "claim block contains the pwd-in-lease-worktree skip path"
else
    fail "claim block missing the skip-claim detection logic"
fi

if echo "$CLAIM_BLOCK" | grep -q 'CHUMP_BOT_MERGE_SKIP_CLAIM'; then
    ok "claim block honors CHUMP_BOT_MERGE_SKIP_CLAIM debug bypass"
else
    fail "claim block missing CHUMP_BOT_MERGE_SKIP_CLAIM bypass"
fi

if grep -q 'kind: bot_merge_skip_claim_lax' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" 2>/dev/null; then
    ok "EVENT_REGISTRY.yaml registers bot_merge_skip_claim_lax"
else
    fail "EVENT_REGISTRY.yaml missing bot_merge_skip_claim_lax"
fi

# ── Fixture setup ───────────────────────────────────────────────────────────
TMP="$(mktemp -d -t bot-merge-already-claimed.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

WORKTREE="$TMP/chump-infra-1901-test"
mkdir -p "$WORKTREE"
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"

GID="INFRA-19011"
SESSION="claim-infra-19011-pid-epoch"

cat > "$LOCK_DIR/${SESSION}.json" <<EOF
{
  "session_id": "$SESSION",
  "gap_id": "$GID",
  "worktree": "$WORKTREE",
  "expires_at": "2099-01-01T00:00:00Z"
}
EOF

# ── Stub `chump`: fails loudly if `claim` subcommand is ever invoked ────────
BINDIR="$TMP/bin"
mkdir -p "$BINDIR"
MARKER="$TMP/claim-was-called"
cat > "$BINDIR/chump" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "claim" ]]; then
    touch "$MARKER"
    echo "STUB: chump claim invoked (should have been skipped)" >&2
    exit 1
fi
if [[ "\${1:-}" == "ambient" ]]; then
    echo "\$*" >> "$TMP/ambient-calls.log"
    exit 0
fi
exit 0
STUB
chmod +x "$BINDIR/chump"

# ── Evaluate the real claim block against the fixture ───────────────────────
run_claim_block() {
    local pwd_dir="$1"
    (
        set -uo pipefail
        cd "$pwd_dir" || exit 2
        PATH="$BINDIR:$PATH"
        # shellcheck disable=SC1090
        source "$LEASE_LIB"
        MAIN_REPO="$TMP"
        REPO_ROOT="$pwd_dir"
        GAP_IDS=("$GID")
        DRY_RUN=0
        SPECULATIVE=0
        _claim_extra=""
        CHUMP_BOT_MERGE_SKIP_CLAIM="${CHUMP_BOT_MERGE_SKIP_CLAIM:-0}"
        info() { :; }
        red()  { echo "RED: $*" >&2; }
        _bm_step_start() { :; }
        _bm_step_done()  { :; }
        eval "$CLAIM_BLOCK"
        echo "SKIP_CLAIM=$_skip_claim CLAIM_RC=$_claim_rc"
    )
}

# ── Test 1: pwd == lease worktree exactly → skip claim ─────────────────────
OUT="$(run_claim_block "$WORKTREE" 2>&1)"
if [[ -f "$MARKER" ]]; then
    fail "chump claim was invoked when pwd == lease worktree (should be skipped)"
else
    ok "chump claim NOT invoked when pwd == lease worktree"
fi
if echo "$OUT" | grep -q 'SKIP_CLAIM=1'; then
    ok "claim block set _skip_claim=1 for exact worktree match"
else
    fail "claim block did not set _skip_claim=1 (got: $OUT)"
fi

# ── Test 2: pwd is a subdir of the lease worktree → still skip claim ───────
rm -f "$MARKER"
SUBDIR="$WORKTREE/src/deep/path"
mkdir -p "$SUBDIR"
OUT="$(run_claim_block "$SUBDIR" 2>&1)"
if [[ -f "$MARKER" ]]; then
    fail "chump claim was invoked from a subdir of the claimed worktree"
else
    ok "chump claim NOT invoked from a subdir of the claimed worktree"
fi
if echo "$OUT" | grep -q 'SKIP_CLAIM=1'; then
    ok "claim block skips re-claim from a nested subdirectory (AC#1/AC#2)"
else
    fail "claim block did not skip from a nested subdirectory (got: $OUT)"
fi

# ── Test 3: CHUMP_BOT_MERGE_SKIP_CLAIM=1 restores unconditional re-claim ───
rm -f "$MARKER"
OUT="$(CHUMP_BOT_MERGE_SKIP_CLAIM=1 run_claim_block "$WORKTREE" 2>&1)"
if [[ -f "$MARKER" ]]; then
    ok "CHUMP_BOT_MERGE_SKIP_CLAIM=1 bypass restores the unconditional chump claim call (AC#5)"
else
    fail "CHUMP_BOT_MERGE_SKIP_CLAIM=1 bypass did not invoke chump claim"
fi
if [[ -f "$TMP/ambient-calls.log" ]] && grep -q 'bot_merge_skip_claim_lax' "$TMP/ambient-calls.log"; then
    ok "bypass emits kind=bot_merge_skip_claim_lax (AC#5)"
else
    fail "bypass did not emit kind=bot_merge_skip_claim_lax"
fi

# ── Test 4: state.db-only lease (no JSON sidecar) still resolves ───────────
if command -v sqlite3 >/dev/null 2>&1; then
    rm -f "$MARKER" "$LOCK_DIR/${SESSION}.json"
    SDB="$TMP/state.db"
    sqlite3 "$SDB" "CREATE TABLE leases (session_id TEXT PRIMARY KEY, gap_id TEXT NOT NULL, worktree TEXT NOT NULL DEFAULT '', expires_at INTEGER NOT NULL);"
    sqlite3 "$SDB" "INSERT INTO leases (session_id, gap_id, worktree, expires_at) VALUES ('$SESSION', '$GID', '$WORKTREE', 9999999999);"
    cp "$SDB" "$TMP/.chump/state.db" 2>/dev/null || { mkdir -p "$TMP/.chump"; cp "$SDB" "$TMP/.chump/state.db"; }
    OUT="$(run_claim_block "$WORKTREE" 2>&1)"
    if [[ -f "$MARKER" ]]; then
        fail "chump claim invoked when only a state.db lease exists (AC#3)"
    else
        ok "chump claim NOT invoked with a state.db-only lease (no JSON sidecar, AC#3)"
    fi
else
    ok "sqlite3 absent — skipping state.db-only lease test"
fi

# ── Test 5: unrelated pwd (not inside lease worktree) → normal claim path ──
rm -f "$MARKER"
cat > "$LOCK_DIR/${SESSION}.json" <<EOF
{
  "session_id": "$SESSION",
  "gap_id": "$GID",
  "worktree": "$WORKTREE",
  "expires_at": "2099-01-01T00:00:00Z"
}
EOF
OTHER_DIR="$TMP/unrelated-dir"
mkdir -p "$OTHER_DIR"
OUT="$(run_claim_block "$OTHER_DIR" 2>&1)"
if [[ -f "$MARKER" ]]; then
    ok "chump claim IS invoked when pwd is NOT inside the claimed worktree (no false-positive skip)"
else
    fail "chump claim was skipped even though pwd is unrelated to the lease worktree"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
