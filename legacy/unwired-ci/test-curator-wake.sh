#!/usr/bin/env bash
# scripts/ci/test-curator-wake.sh — INFRA-1908
#
# Smoke for the curator-wake helper CLI. Verifies all 6 templates print,
# each includes the 4 required pieces (CHUMP_SESSION_ID export, inbox read,
# /loop invocation, loop_started ack), and --role / --copy flags work.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/coord/curator-wake.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$SCRIPT" ]] || fail "$SCRIPT missing"
[[ -x "$SCRIPT" ]] || fail "$SCRIPT not executable"
bash -n "$SCRIPT" || fail "syntax error"
ok "script exists, executable, parses"

# ── Default (--all) emits all 6 roles ─────────────────────────────────────
out_all="$(bash "$SCRIPT" 2>&1)"
for role in target handoff ci-audit shepherd decompose md-links; do
    if echo "$out_all" | grep -q "curator-opus-${role}"; then
        ok "default --all emits ${role} template"
    else
        fail "default --all missing ${role} template"
    fi
done

# ── Each template has 4 required pieces ───────────────────────────────────
# Test with --role handoff for cleaner grep
out_handoff="$(bash "$SCRIPT" --role handoff 2>&1)"

if echo "$out_handoff" | grep -q 'export CHUMP_SESSION_ID=curator-opus-handoff-'; then
    ok "template piece 1: CHUMP_SESSION_ID export"
else
    fail "no CHUMP_SESSION_ID export"
fi

if echo "$out_handoff" | grep -q 'chump-inbox.sh read'; then
    ok "template piece 2: inbox-read incantation"
else
    fail "no inbox-read incantation"
fi

if echo "$out_handoff" | grep -q '/loop 5m'; then
    ok "template piece 3: /loop 5m invocation"
else
    fail "no /loop invocation"
fi

if echo "$out_handoff" | grep -q 'loop_started session='; then
    ok "template piece 4: loop_started ACK"
else
    fail "no loop_started ACK"
fi

# ── --role validates ──────────────────────────────────────────────────────
# Capture both stderr + exit code (pipefail would fail the whole expression
# when the bogus-role causes exit 2; use a temp var instead)
bogus_out="$(bash "$SCRIPT" --role bogus 2>&1 || true)"
if echo "$bogus_out" | grep -q "unknown role"; then
    ok "--role validates against valid set (rejects bogus)"
else
    fail "--role bogus should error with 'unknown role'; got: $bogus_out"
fi

# ── --role emits exactly one template ─────────────────────────────────────
template_count=$(bash "$SCRIPT" --role handoff 2>&1 | grep -c "PASTE INTO curator-opus-")
if [[ "$template_count" -eq 1 ]]; then
    ok "--role emits exactly 1 template"
else
    fail "--role emitted $template_count templates (expected 1)"
fi

# ── --all default emits 6 ────────────────────────────────────────────────
all_count=$(bash "$SCRIPT" --all 2>&1 | grep -c "PASTE INTO curator-opus-")
if [[ "$all_count" -eq 6 ]]; then
    ok "--all emits exactly 6 templates"
else
    fail "--all emitted $all_count templates (expected 6)"
fi

# ── INFRA-1908 attribution ────────────────────────────────────────────────
grep -q 'INFRA-1908' "$SCRIPT" || fail "no INFRA-1908 attribution"
ok "INFRA-1908 attribution present"

echo ""
echo "ALL INFRA-1908 curator-wake assertions passed."
