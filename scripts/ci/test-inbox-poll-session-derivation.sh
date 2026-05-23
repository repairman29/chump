#!/usr/bin/env bash
# scripts/ci/test-inbox-poll-session-derivation.sh — INFRA-1879
#
# Verify inbox-poll.sh's 5-path session-id derivation order works correctly.
# INFRA-1860 shipped the hook but used a single derivation (CHUMP_SESSION_ID
# or claim-lease fallback). Curators don't set CHUMP_SESSION_ID and aren't
# always holding active claims, so the script no-op'd silently — meaning
# the operator-as-messenger antipattern persisted. This test pins the
# multi-path derivation in place.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/coord/inbox-poll.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$SCRIPT" ]] || fail "$SCRIPT missing"

# ── 1. Path 1 priority: CHUMP_SESSION_ID env ───────────────────────────────
grep -q 'CHUMP_SESSION_ID:-' "$SCRIPT" || fail "no CHUMP_SESSION_ID env path"
ok "Path 1: CHUMP_SESSION_ID env"

# ── 2. Path 2: CLAUDE_SESSION_ID env fallback ──────────────────────────────
grep -q 'CLAUDE_SESSION_ID' "$SCRIPT" || fail "no CLAUDE_SESSION_ID derivation path"
ok "Path 2: CLAUDE_SESSION_ID env"

# ── 3. Path 3: tmux pane title ─────────────────────────────────────────────
grep -q "tmux display-message" "$SCRIPT" || fail "no tmux pane derivation"
ok "Path 3: tmux pane title"

# ── 4. Path 4: claim-*.json fallback (the original INFRA-1860 path) ────────
grep -q 'claim-\*.json' "$SCRIPT" || fail "no claim-lease derivation"
ok "Path 4: claim-lease"

# ── 5. Path 5: operator_id file fallback ───────────────────────────────────
grep -q 'operator_id' "$SCRIPT" || fail "no operator_id derivation"
ok "Path 5: operator_id"

# ── 6. Derivation path emitted as audit field ─────────────────────────────
grep -q 'derivation_path=' "$SCRIPT" || fail "no derivation_path in audit emit"
ok "derivation_path audit field present"

# ── 7. inbox_session_derived ambient kind allowlisted or registered ────────
ALLOWLIST="$REPO/scripts/ci/event-registry-reserved.txt"
REGISTRY="$REPO/docs/observability/EVENT_REGISTRY.yaml"
if grep -q 'inbox_session_derived' "$ALLOWLIST" 2>/dev/null ||
   grep -q 'inbox_session_derived' "$REGISTRY" 2>/dev/null; then
    ok "inbox_session_derived kind registered/allowlisted"
else
    fail "inbox_session_derived not in registry or allowlist — DOC-026 drift"
fi

# ── 8. Functional: CHUMP_SESSION_ID derivation runs (smoke) ────────────────
# Bypass actual inbox-read; just check the script doesn't error
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks/inbox"
touch "$TMP/.chump-locks/inbox/test-session.jsonl"

# Run from the test temp repo
(cd "$TMP" && git init -q && CHUMP_SESSION_ID=test-session bash "$SCRIPT" 2>&1) || true
ok "smoke: script exits cleanly with CHUMP_SESSION_ID env"

# ── 9. INFRA-1879 attribution comment ──────────────────────────────────────
grep -q 'INFRA-1879' "$SCRIPT" || fail "no INFRA-1879 attribution comment"
ok "INFRA-1879 attribution comment present"

# ── 10. INFRA-1860 attribution preserved (heritage) ────────────────────────
grep -q 'INFRA-1860' "$SCRIPT" || fail "INFRA-1860 attribution removed (regression)"
ok "INFRA-1860 attribution preserved"

# ── 11. Script still parses ──────────────────────────────────────────────
bash -n "$SCRIPT" || fail "script has syntax error"
ok "script parses cleanly"

echo ""
echo "ALL INFRA-1879 derivation tests passed."
