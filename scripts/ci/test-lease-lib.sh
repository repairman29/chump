#!/usr/bin/env bash
# test-lease-lib.sh — INFRA-1212
#
# Exercises scripts/lib/lease.sh against synthetic .chump-locks/*.json
# fixtures. Confirms the shared parser produces the same results that the
# 8 ad-hoc reaper parsers were computing.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/lease.sh"

echo "=== INFRA-1212 scripts/lib/lease.sh tests ==="
[[ -f "$LIB" ]] || { fail "lib missing: $LIB"; echo "FAIL"; exit 1; }
ok "lib present at $LIB"

# shellcheck disable=SC1090
source "$LIB"

TMP="$(mktemp -d -t lease-lib.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
export CHUMP_LOCK_DIR="$LOCK_DIR"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
iso_in_past() { date -u -v-${1}S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 seconds ago" +%Y-%m-%dT%H:%M:%SZ; }
iso_in_future() { date -u -v+${1}S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+$1 seconds" +%Y-%m-%dT%H:%M:%SZ; }

# Fixture 1: fresh active lease
fresh="$LOCK_DIR/fresh-session.json"
cat > "$fresh" <<EOF
{
  "session_id": "claim-infra-123-pid-epoch",
  "paths": [],
  "taken_at": "$(iso_in_past 60)",
  "expires_at": "$(iso_in_future 14400)",
  "heartbeat_at": "$(now_iso)",
  "purpose": "gap:INFRA-123",
  "gap_id": "INFRA-123",
  "worktree": "chump-infra-123"
}
EOF

# Fixture 2: stale heartbeat
stale="$LOCK_DIR/stale-session.json"
cat > "$stale" <<EOF
{
  "session_id": "claim-infra-456-pid-epoch",
  "paths": [],
  "taken_at": "$(iso_in_past 5400)",
  "expires_at": "$(iso_in_future 7200)",
  "heartbeat_at": "$(iso_in_past 1800)",
  "purpose": "gap:INFRA-456",
  "gap_id": "INFRA-456"
}
EOF

# Fixture 3: expired
expired="$LOCK_DIR/expired-session.json"
cat > "$expired" <<EOF
{
  "session_id": "claim-infra-789-pid-epoch",
  "taken_at": "$(iso_in_past 21600)",
  "expires_at": "$(iso_in_past 3600)",
  "heartbeat_at": "$(iso_in_past 7200)",
  "gap_id": "INFRA-789"
}
EOF

# ── lease_dir ────────────────────────────────────────────────────────────────
got="$(lease_dir --repo "$TMP")"
if [[ "$got" == "$LOCK_DIR" ]]; then ok "lease_dir --repo resolves correctly"; else fail "lease_dir got=$got want=$LOCK_DIR"; fi

# ── lease_iter ───────────────────────────────────────────────────────────────
got_count="$(lease_iter --repo "$TMP" | wc -l | tr -d ' ')"
if [[ "$got_count" -eq 3 ]]; then ok "lease_iter yields 3 fixtures"; else fail "lease_iter count=$got_count want=3"; fi

# ── lease_field ──────────────────────────────────────────────────────────────
got="$(lease_field "$fresh" session_id)"
[[ "$got" == "claim-infra-123-pid-epoch" ]] && ok "lease_field session_id" || fail "lease_field session_id got=$got"

got="$(lease_field "$fresh" gap_id)"
[[ "$got" == "INFRA-123" ]] && ok "lease_field gap_id" || fail "lease_field gap_id got=$got"

got="$(lease_field "$fresh" worktree)"
[[ "$got" == "chump-infra-123" ]] && ok "lease_field worktree" || fail "lease_field worktree got=$got"

got="$(lease_session_id "$fresh")"
[[ "$got" == "claim-infra-123-pid-epoch" ]] && ok "lease_session_id shortcut" || fail "lease_session_id got=$got"

# Missing field returns empty
got="$(lease_field "$expired" worktree)"
[[ -z "$got" ]] && ok "lease_field missing returns empty" || fail "missing field got='$got'"

# ── lease_heartbeat_age_s ────────────────────────────────────────────────────
age="$(lease_heartbeat_age_s "$fresh")"
if [[ "$age" -ge 0 && "$age" -le 10 ]]; then ok "fresh heartbeat age ~0s (got ${age}s)"; else fail "fresh heartbeat age=${age}s"; fi

age="$(lease_heartbeat_age_s "$stale")"
if [[ "$age" -ge 1700 && "$age" -le 1900 ]]; then ok "stale heartbeat age ~1800s (got ${age}s)"; else fail "stale heartbeat age=${age}s"; fi

# ── lease_is_fresh ───────────────────────────────────────────────────────────
lease_is_fresh "$fresh" && ok "lease_is_fresh: fresh lease ✓" || fail "fresh lease not detected fresh"
lease_is_fresh "$stale" && fail "stale lease incorrectly fresh" || ok "lease_is_fresh: stale lease ✗ (correct)"

# Custom grace
lease_is_fresh "$stale" 3600 && ok "lease_is_fresh grace=3600 accepts stale" || fail "grace=3600 should accept 1800s stale"

# ── lease_is_expired ─────────────────────────────────────────────────────────
lease_is_expired "$expired" && ok "lease_is_expired: expired ✓" || fail "expired lease not detected"
lease_is_expired "$fresh" && fail "fresh lease incorrectly expired" || ok "lease_is_expired: fresh ✗ (correct)"

# ── round-trip via grep-only path (force-disable jq) ─────────────────────────
# Re-test field extraction with a forced jq-absent path. We can't unset jq,
# so we wrap the function to bypass it.
if command -v jq >/dev/null 2>&1; then
    _orig_field=$(declare -f lease_field)
    # Re-source lease.sh with a PATH that excludes jq
    PATH_BAK="$PATH"
    JQDIR="$(dirname "$(command -v jq)")"
    PATH="$(echo "$PATH" | tr ':' '\n' | grep -vFx "$JQDIR" | tr '\n' ':' | sed 's/:$//')"
    export PATH
    # Re-source with the guard reset
    unset __CHUMP_LIB_LEASE_LOADED
    # shellcheck disable=SC1090
    source "$LIB"
    got="$(lease_field "$fresh" session_id)"
    [[ "$got" == "claim-infra-123-pid-epoch" ]] && ok "lease_field grep-fallback (no jq)" || fail "grep-fallback got=$got"
    PATH="$PATH_BAK"
    export PATH
fi

# ── INFRA-2744: state.db lease reader (lease_session_from_statedb) ────────────
# The canonical lease store is the state.db `leases` table — interactive
# `chump claim` writes the lease there ONLY (no .chump-locks/*.json sidecar).
# Resolving "who holds gap X" must therefore fall back to state.db, else
# bot-merge re-claim refuses the operator's own claim. Mirrors the live schema.
if command -v sqlite3 >/dev/null 2>&1; then
    SDB="$TMP/state.db"
    sqlite3 "$SDB" "CREATE TABLE leases (session_id TEXT PRIMARY KEY, gap_id TEXT NOT NULL, worktree TEXT NOT NULL DEFAULT '', expires_at INTEGER NOT NULL); CREATE INDEX leases_gap ON leases(gap_id);"
    sqlite3 "$SDB" "INSERT INTO leases (session_id, gap_id, worktree, expires_at) VALUES ('claim-infra-2744-test-99','INFRA-2744','/tmp/wt',9999999999);"
    # Lease present in state.db + NO JSON sidecar -> resolves the session.
    got="$(lease_session_from_statedb INFRA-2744 "$SDB")"
    [[ "$got" == "claim-infra-2744-test-99" ]] \
        && ok "lease_session_from_statedb resolves session from state.db (no JSON needed)" \
        || fail "lease_session_from_statedb got='$got' (expected claim-infra-2744-test-99)"
    # Absent gap -> empty (no false positive).
    got="$(lease_session_from_statedb NOPE-0000 "$SDB")"
    [[ -z "$got" ]] && ok "lease_session_from_statedb empty for absent gap" \
        || fail "lease_session_from_statedb absent-gap got='$got' (expected empty)"
    # SQL-unsafe gap id rejected before any query; table must survive.
    got="$(lease_session_from_statedb "x'; DROP TABLE leases;--" "$SDB")"
    [[ -z "$got" ]] && ok "lease_session_from_statedb rejects SQL-unsafe gap id" \
        || fail "lease_session_from_statedb unsafe-id got='$got' (expected empty)"
    sqlite3 "$SDB" "SELECT 1 FROM leases LIMIT 1;" >/dev/null 2>&1 \
        && ok "leases table intact after unsafe gap id (no SQL injection)" \
        || fail "leases table harmed by unsafe gap id (injection!)"

    # ── INFRA-1901: lease_worktree_from_statedb ──────────────────────────────
    got="$(lease_worktree_from_statedb INFRA-2744 "$SDB")"
    [[ "$got" == "/tmp/wt" ]] \
        && ok "lease_worktree_from_statedb resolves worktree from state.db" \
        || fail "lease_worktree_from_statedb got='$got' (expected /tmp/wt)"
    got="$(lease_worktree_from_statedb NOPE-0000 "$SDB")"
    [[ -z "$got" ]] && ok "lease_worktree_from_statedb empty for absent gap" \
        || fail "lease_worktree_from_statedb absent-gap got='$got' (expected empty)"
    got="$(lease_worktree_from_statedb "x'; DROP TABLE leases;--" "$SDB")"
    [[ -z "$got" ]] && ok "lease_worktree_from_statedb rejects SQL-unsafe gap id" \
        || fail "lease_worktree_from_statedb unsafe-id got='$got' (expected empty)"
else
    ok "sqlite3 absent — skipping INFRA-2744 state.db lease reader tests"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
