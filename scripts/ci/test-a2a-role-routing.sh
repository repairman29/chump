#!/usr/bin/env bash
# scripts/ci/test-a2a-role-routing.sh — INFRA-1945 (A2A world-class slice B)
#
# Smoke test: broadcast.sh --to role:<name> role-typed routing.
#
# Tests:
#   (a) Registry populated with 2 sessions of different roles; --to role:X
#       resolves to the alive X session, writes to ITS inbox, and emits
#       ambient kind=a2a_role_resolved {role, resolved_session}.
#   (b) A stale (>30min) registry entry is NOT selected as the resolution.
#   (c) No alive role match + --strict → non-zero exit, no inbox write.
#   (d) No alive role match, no --strict → exit 0, dead-letter
#       (kind=a2a_role_resolve_failed emitted, no inbox write).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"
[[ -x "$BROADCAST" ]] || { echo "[FAIL] broadcast.sh not executable at $BROADCAST" >&2; exit 1; }

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX/.chump-locks/inbox"
git -C "$TMP" init -q "$SANDBOX"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

AMBIENT="$SANDBOX/.chump-locks/ambient.jsonl"
REGISTRY="$SANDBOX/.chump-locks/fleet-registry.jsonl"

run_broadcast() {
    (
        cd "$SANDBOX"
        CHUMP_SESSION_ID="ci-test-sender-$$" \
            "$BROADCAST" "$@"
    )
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── (a) two alive sessions of different roles; role:shepherd resolves ────────
cat > "$REGISTRY" <<EOF
{"ts":"$(now_iso)","session":"curator-opus-shepherd-2026-08-13","role":"shepherd","harness":"claude-code","current_work":"idle"}
{"ts":"$(now_iso)","session":"curator-opus-target-2026-08-13","role":"target","harness":"claude-code","current_work":"idle"}
EOF

run_broadcast --to role:shepherd WARN "route-to-shepherd smoke test" >/dev/null 2>&1

SHEPHERD_INBOX="$SANDBOX/.chump-locks/inbox/curator-opus-shepherd-2026-08-13.jsonl"
TARGET_INBOX="$SANDBOX/.chump-locks/inbox/curator-opus-target-2026-08-13.jsonl"

[[ -f "$SHEPHERD_INBOX" ]] || fail "(a) shepherd inbox not created: $SHEPHERD_INBOX"
grep -q "route-to-shepherd smoke test" "$SHEPHERD_INBOX" \
    || fail "(a) shepherd inbox missing the routed message"
ok "(a) role:shepherd delivered to curator-opus-shepherd-2026-08-13's inbox"

[[ -f "$TARGET_INBOX" ]] && fail "(a) target inbox should NOT have received the shepherd-routed message"
ok "(a) target inbox untouched (role routing is exclusive)"

RESOLVED_LINE="$(grep '"kind":"a2a_role_resolved"' "$AMBIENT" | tail -1)"
[[ -n "$RESOLVED_LINE" ]] || fail "(a) no a2a_role_resolved event in ambient: $(cat "$AMBIENT")"
echo "$RESOLVED_LINE" | grep -q '"role":"shepherd"' \
    || fail "(a) a2a_role_resolved missing role=shepherd: $RESOLVED_LINE"
echo "$RESOLVED_LINE" | grep -q '"resolved_session":"curator-opus-shepherd-2026-08-13"' \
    || fail "(a) a2a_role_resolved missing resolved_session: $RESOLVED_LINE"
ok "(a) a2a_role_resolved{role,resolved_session} present in ambient"

# ── (b) stale registry entry (>30min old) is ignored ─────────────────────────
rm -f "$AMBIENT" "$SANDBOX/.chump-locks/inbox"/*.jsonl
STALE_TS="2020-01-01T00:00:00Z"
cat > "$REGISTRY" <<EOF
{"ts":"$STALE_TS","session":"curator-opus-shepherd-STALE","role":"shepherd","harness":"claude-code","current_work":"idle"}
EOF

if run_broadcast --to role:shepherd WARN "should dead-letter" >/dev/null 2>&1; then
    :
fi
STALE_INBOX="$SANDBOX/.chump-locks/inbox/curator-opus-shepherd-STALE.jsonl"
[[ -f "$STALE_INBOX" ]] && fail "(b) stale registry entry must not be selected: $STALE_INBOX exists"
ok "(b) stale (>30min) registry entry correctly ignored"

# ── (c) no alive match + --strict → non-zero exit, no inbox write ────────────
rm -f "$AMBIENT"
> "$REGISTRY"
if run_broadcast --to role:nonexistent --strict WARN "should fail" >/dev/null 2>&1; then
    fail "(c) --strict with no alive role match should exit non-zero"
fi
ok "(c) --strict with no alive role match exits non-zero"

# ── (d) no alive match, no --strict → exit 0, dead-letter ────────────────────
rm -f "$AMBIENT"
run_broadcast --to role:nonexistent WARN "dead-letter smoke" >/dev/null 2>&1 \
    || fail "(d) non-strict no-match should exit 0"
DEAD_LINE="$(grep '"kind":"a2a_role_resolve_failed"' "$AMBIENT" | tail -1)"
[[ -n "$DEAD_LINE" ]] || fail "(d) no a2a_role_resolve_failed event in ambient: $(cat "$AMBIENT")"
echo "$DEAD_LINE" | grep -q '"role":"nonexistent"' \
    || fail "(d) a2a_role_resolve_failed missing role=nonexistent: $DEAD_LINE"
ok "(d) non-strict no-match dead-letters via kind=a2a_role_resolve_failed"

echo ""
echo "All tests passed."
