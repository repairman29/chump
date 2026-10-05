#!/usr/bin/env bash
# scripts/ci/test-a2a-role-routing.sh — INFRA-1945
#
# Smoke test: broadcast.sh role-typed routing (slice B of INFRA-1862).
# Verifies:
#   (a) --to role:<name> resolves against a fresh fleet-registry.jsonl
#       entry and the message lands in the resolved session's inbox
#   (b) kind=a2a_role_resolved {role, resolved_session} is emitted
#   (c) with two sessions of different roles registered, routing picks
#       the one matching the requested role (not just "first in file")
#   (d) --to role:<unknown-role> with no alive match falls back to the
#       dead-letter queue (and does not error) by default
#   (e) --to role:<unknown-role> --strict exits non-zero instead

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

LOCK_DIR="$SANDBOX/.chump-locks"
AMBIENT="$LOCK_DIR/ambient.jsonl"
REGISTRY="$LOCK_DIR/fleet-registry.jsonl"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$REGISTRY" <<EOF
{"session_id":"curator-opus-shepherd-2026-05-23","role":"shepherd","ts":"$NOW"}
{"session_id":"curator-opus-ci-audit-2026-05-23","role":"ci-audit","ts":"$NOW"}
EOF

run_broadcast() {
    ( cd "$SANDBOX" && CHUMP_SESSION_ID="wizard" "$BROADCAST" "$@" ) 2>&1
}

# ── (a)+(b)+(c) role:shepherd resolves to the shepherd session, not ci-audit ─
run_broadcast --to role:shepherd --corr role-corr-1 WARN "assignment for shepherd" >/dev/null

SHEPHERD_INBOX="$LOCK_DIR/inbox/curator-opus-shepherd-2026-05-23.jsonl"
[[ -f "$SHEPHERD_INBOX" ]] || fail "(a) shepherd's inbox was not written: $SHEPHERD_INBOX"
grep -q "role-corr-1" "$SHEPHERD_INBOX" || fail "(a) shepherd's inbox missing role-corr-1 message"
ok "(a) --to role:shepherd routes to the registered shepherd session's inbox"

CI_AUDIT_INBOX="$LOCK_DIR/inbox/curator-opus-ci-audit-2026-05-23.jsonl"
[[ -f "$CI_AUDIT_INBOX" ]] && grep -q "role-corr-1" "$CI_AUDIT_INBOX" \
    && fail "(c) role-corr-1 leaked into ci-audit's inbox (should only reach shepherd)"
ok "(c) role resolution picks the matching role, not every registered session"

RESOLVED_LINE="$(grep '"kind":"a2a_role_resolved"' "$AMBIENT" | grep "role-corr-1\|shepherd" | tail -1 || true)"
[[ -n "$RESOLVED_LINE" ]] || fail "(b) no a2a_role_resolved event in ambient: $(cat "$AMBIENT")"
echo "$RESOLVED_LINE" | grep -q '"role":"shepherd"' || fail "(b) a2a_role_resolved missing role=shepherd: $RESOLVED_LINE"
echo "$RESOLVED_LINE" | grep -q '"resolved_session":"curator-opus-shepherd-2026-05-23"' \
    || fail "(b) a2a_role_resolved missing resolved_session: $RESOLVED_LINE"
ok "(b) kind=a2a_role_resolved emitted with role + resolved_session"

# ── (d) unknown role falls back to dead-letter, does not error ───────────────
run_broadcast --to role:nonexistent-role --corr role-corr-2 WARN "nobody home" >/dev/null
DEAD_LETTER="$LOCK_DIR/inbox/dead-letter.jsonl"
[[ -f "$DEAD_LETTER" ]] || fail "(d) dead-letter.jsonl not written for unresolvable role"
grep -q "nonexistent-role" "$DEAD_LETTER" || fail "(d) dead-letter.jsonl missing nonexistent-role entry: $(cat "$DEAD_LETTER")"
grep -q '"kind":"a2a_role_resolve_failed"' "$AMBIENT" || fail "(d) no a2a_role_resolve_failed event emitted"
ok "(d) unresolvable role falls back to dead-letter queue + emits a2a_role_resolve_failed"

# ── (e) --strict errors instead of falling back ──────────────────────────────
set +e
run_broadcast --strict --to role:nonexistent-role --corr role-corr-3 WARN "strict mode" >/dev/null 2>&1
STRICT_RC=$?
set -e
[[ "$STRICT_RC" -ne 0 ]] || fail "(e) --strict should exit non-zero for an unresolvable role"
ok "(e) --strict exits non-zero instead of falling back to dead-letter"

echo ""
echo "All tests passed."
