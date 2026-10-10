#!/usr/bin/env bash
# test-agents-md-injection.sh — RESILIENT-1166 (RESILIENT-259 slice)
#
# Claude Code auto-loads CLAUDE.md as project instructions before a `claude -p`
# spawn; opencode/codex have no equivalent auto-load, so worker.sh must
# concatenate AGENTS.md's full text into the briefing for those harnesses.
# This proves: (1) non-claude-p modes get the real file content injected,
# (2) claude-p stays untouched (empty injection — AC2), (3) a dry-run against
# a mock non-Claude harness + fixture AGENTS.md produces a combined prompt
# file that contains the fixture content (AC3).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CMD_LIB="$REPO_ROOT/scripts/dispatch/harness-cmd.sh"

echo "=== RESILIENT-1166 AGENTS.md injection smoke ==="
echo

tmp_wt="$(mktemp -d)"
trap 'rm -rf "$tmp_wt"' EXIT
marker="AGENTS_MD_FIXTURE_MARKER_$$"
printf '# AGENTS.md fixture\n%s\n' "$marker" > "$tmp_wt/AGENTS.md"

# ── 1. non-claude-p mode injects the real AGENTS.md content ─────────────────
echo "[non-claude harness]"
out_opencode="$(
    set -u
    # shellcheck source=/dev/null
    source "$CMD_LIB"
    hard_rules_inject "opencode-prompt" "$tmp_wt" "$REPO_ROOT"
)"
if grep -q "$marker" <<<"$out_opencode"; then
    ok "opencode-prompt injection contains fixture AGENTS.md content"
else
    fail "opencode-prompt injection missing fixture AGENTS.md content"
fi
grep -q 'AGENTS.md' <<<"$out_opencode" && ok "injection block names AGENTS.md" || fail "injection block missing doc name header"

out_codex="$(
    set -u
    # shellcheck source=/dev/null
    source "$CMD_LIB"
    hard_rules_inject "codex-prompt" "$tmp_wt" "$REPO_ROOT"
)"
grep -q "$marker" <<<"$out_codex" && ok "codex-prompt injection contains fixture AGENTS.md content" \
                                   || fail "codex-prompt injection missing fixture AGENTS.md content"

# ── 2. claude-p stays a no-op (AC2 — existing behavior unchanged) ───────────
echo "[claude-p harness]"
out_claude="$(
    set -u
    # shellcheck source=/dev/null
    source "$CMD_LIB"
    hard_rules_inject "claude-p" "$tmp_wt" "$REPO_ROOT"
)"
if [[ -z "$out_claude" ]]; then
    ok "claude-p injection is empty (CLAUDE.md auto-loads, no concat needed)"
else
    fail "claude-p injection is non-empty — would change existing Claude behavior"
fi

# ── 3. dry-run: mock non-Claude harness combined-prompt file (AC3) ──────────
echo "[combined-file dry-run]"
combined_file="$tmp_wt/combined_prompt.txt"
(
    # shellcheck source=/dev/null
    source "$CMD_LIB"
    printf 'Ship gap MOCK-1 in this repository.\n'
    hard_rules_inject "opencode-prompt" "$tmp_wt" "$REPO_ROOT"
) > "$combined_file"
if grep -q "$marker" "$combined_file"; then
    ok "dry-run combined prompt file includes AGENTS.md content"
else
    fail "dry-run combined prompt file missing AGENTS.md content"
fi

# ── 4. wiring: worker.sh actually calls hard_rules_inject ───────────────────
echo "[wiring]"
if grep -q 'hard_rules_inject' "$REPO_ROOT/scripts/dispatch/worker.sh"; then
    ok "worker.sh calls hard_rules_inject"
else
    fail "worker.sh does not call hard_rules_inject — injection not wired"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
