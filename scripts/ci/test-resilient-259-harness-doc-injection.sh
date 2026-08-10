#!/usr/bin/env bash
# test-resilient-259-harness-doc-injection.sh — RESILIENT-259
#
# Operating practices belong in AGENTS.md (canonical, harness-agnostic), not
# CLAUDE.md (Claude-Code-only overlay per its own header). Pre-fix, worker.sh
# unconditionally told every harness — including opencode/codex, which never
# read CLAUDE.md — to look there for the "full HARD RULES text." This test
# fails on the pre-fix code (hard_rules_doc_name absent, or worker.sh still
# hardcoding "CLAUDE.md" for non-claude spawn modes) and passes post-fix.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CMD_LIB="$REPO_ROOT/scripts/dispatch/harness-cmd.sh"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
AGENTS_MD="$REPO_ROOT/AGENTS.md"

echo "=== RESILIENT-259 harness doc-injection ==="
echo

# ── 1. hard_rules_doc_name exists and is correct per harness ─────────────
if [[ -f "$CMD_LIB" ]] && grep -q 'hard_rules_doc_name' "$CMD_LIB"; then
    ok "harness-cmd.sh defines hard_rules_doc_name"
else
    fail "hard_rules_doc_name missing from harness-cmd.sh"
fi

# shellcheck source=/dev/null
source "$CMD_LIB"

for pair in "claude-p:CLAUDE.md" "opencode-prompt:AGENTS.md" "codex-prompt:AGENTS.md" "manual-result-file:AGENTS.md"; do
    mode="${pair%%:*}"
    want="${pair##*:}"
    got="$(hard_rules_doc_name "$mode")"
    if [[ "$got" == "$want" ]]; then
        ok "hard_rules_doc_name($mode) == $want"
    else
        fail "hard_rules_doc_name($mode) == $got, want $want"
    fi
done

# ── 2. worker.sh actually calls the function in both prompt sites,
#      instead of hardcoding CLAUDE.md unconditionally ─────────────────
if grep -q 'hard_rules_doc_name "\${HARNESS_SPAWN_MODE' "$WORKER"; then
    ok "worker.sh (inline-briefing prompt) uses hard_rules_doc_name"
else
    fail "worker.sh inline-briefing prompt does not call hard_rules_doc_name"
fi

if grep -q '_read_first="AGENTS.md"' "$WORKER" && grep -q '_read_first="CLAUDE.md and AGENTS.md"' "$WORKER"; then
    ok "worker.sh (fallback prompt) branches doc reference by harness"
else
    fail "worker.sh fallback prompt still hardcodes CLAUDE.md for every harness"
fi

# No leftover unconditional "Read CLAUDE.md and AGENTS.md first" — the
# fallback prompt now interpolates ${_read_first} instead of a literal.
if grep -q 'Read \${_read_first} first' "$WORKER"; then
    ok "fallback prompt interpolates the harness-appropriate doc, not a literal"
else
    fail "fallback prompt no longer interpolates \${_read_first}"
fi

# ── 3. AGENTS.md carries the harness-agnostic practices this gap promotes ──
if grep -qi 'mine the almanac' "$AGENTS_MD"; then
    ok "AGENTS.md documents mining the almanac before build/holler"
else
    fail "AGENTS.md missing the mine-the-almanac directive"
fi

if grep -q 'chump voice' "$AGENTS_MD"; then
    ok "AGENTS.md documents chump voice for friction signals"
else
    fail "AGENTS.md missing the chump voice friction-reporting pointer"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
