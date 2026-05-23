#!/usr/bin/env bash
# scripts/ci/test-posttooluse-inbox-poll.sh — INFRA-1860
#
# Smoke test for the PostToolUse inbox-poll hook that fixes the operator-as-
# messenger antipattern. Structural assertions only (the actual hook firing
# behavior is gated by Claude Code's hook runtime — not testable in CI).

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/coord/inbox-poll.sh"
SETTINGS="$REPO/.claude/settings.json"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. inbox-poll.sh exists + executable + parses ─────────────────────────
[[ -f "$SCRIPT" ]] || fail "$SCRIPT missing"
[[ -x "$SCRIPT" ]] || fail "$SCRIPT not executable"
bash -n "$SCRIPT" || fail "$SCRIPT syntax error"
ok "inbox-poll.sh exists, executable, parses"

# ── 2. Bypass env var honored ─────────────────────────────────────────────
if grep -q 'CHUMP_AUTO_INBOX_POLL' "$SCRIPT"; then
    ok "bypass env CHUMP_AUTO_INBOX_POLL present"
else
    fail "no CHUMP_AUTO_INBOX_POLL bypass env"
fi

# ── 3. Throttle counter mechanism present ─────────────────────────────────
grep -q 'inbox-poll-counter' "$SCRIPT" || fail "no throttle counter"
grep -q 'CHUMP_INBOX_POLL_N' "$SCRIPT" || fail "no configurable throttle N"
ok "throttle (counter + N env) present"

# ── 4. PostToolUse hook wired in settings.json ────────────────────────────
if [[ -f "$SETTINGS" ]]; then
    if grep -q 'inbox-poll.sh' "$SETTINGS"; then
        ok ".claude/settings.json wires inbox-poll.sh"
    else
        fail ".claude/settings.json does NOT reference inbox-poll.sh — hook not wired"
    fi
else
    fail ".claude/settings.json missing"
fi

# ── 5. Audit emit kind registered or allowlisted ─────────────────────────
ALLOWLIST="$REPO/scripts/ci/event-registry-reserved.txt"
REGISTRY="$REPO/docs/observability/EVENT_REGISTRY.yaml"
if grep -q 'inbox_auto_poll_surfaced' "$ALLOWLIST" 2>/dev/null ||
   grep -q 'inbox_auto_poll_surfaced' "$REGISTRY" 2>/dev/null; then
    ok "inbox_auto_poll_surfaced kind registered/allowlisted"
else
    fail "inbox_auto_poll_surfaced kind NOT in registry or allowlist — DOC-026 drift"
fi

# ── 6. Bypass actually short-circuits ─────────────────────────────────────
out_bypass="$(CHUMP_AUTO_INBOX_POLL=0 bash "$SCRIPT" 2>&1 || true)"
if [[ -z "$out_bypass" ]]; then
    ok "CHUMP_AUTO_INBOX_POLL=0 short-circuits silently"
else
    fail "bypass did not short-circuit cleanly; got: $out_bypass"
fi

# ── 7. INFRA-1860 attribution comment ─────────────────────────────────────
grep -q 'INFRA-1860' "$SCRIPT" || fail "no INFRA-1860 attribution"
ok "INFRA-1860 attribution comment present"

echo ""
echo "ALL INFRA-1860 smoke assertions passed."
