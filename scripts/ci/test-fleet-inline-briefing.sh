#!/usr/bin/env bash
# test-fleet-inline-briefing.sh — INFRA-371 regression test.
#
# Verifies the worker.sh inline-gap-briefing path:
#   1. With FLEET_INLINE_BRIEFING=1 (default), the prompt embeds the gap
#      YAML and the hard-rules summary, and does NOT contain the legacy
#      "Read CLAUDE.md and AGENTS.md first" string.
#   2. With FLEET_INLINE_BRIEFING=0, the prompt reverts to the pre-fix
#      terse form (back-compat).
#   3. Missing gap YAML → fallback hint embedded, no crash.
#
# We extract the prompt-construction block from worker.sh into a self-
# contained shell snippet so we can exercise it without spawning claude
# or tmux. The snippet mirrors the production lines in scripts/dispatch/worker.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

[[ -f "$WORKER" ]] || { echo "FAIL: $WORKER missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub gap YAML (real one would be at $wt_path/docs/gaps/INFRA-999.yaml).
mkdir -p "$TMP/wt/docs/gaps"
cat >"$TMP/wt/docs/gaps/INFRA-999.yaml" <<'EOF'
- id: INFRA-999
  domain: INFRA
  title: synthetic test gap
  status: open
  priority: P1
  effort: xs
  description: |
    A synthetic gap for the inline-briefing smoke test.
  acceptance_criteria:
    - smoke-test passes
EOF

# Build a prompt the same way worker.sh does, in a subshell with the same
# env semantics. Source worker.sh would execute the loop — we don't want
# that, so we mirror just the prompt-construction lines.
build_prompt() {
    local GAP_ID="$1"
    local wt_path="$TMP/wt"
    local gap_yaml_path="$wt_path/docs/gaps/${GAP_ID}.yaml"
    local gap_yaml="(gap YAML not found — read docs/gaps/${GAP_ID}.yaml)"
    [[ -f "$gap_yaml_path" ]] && gap_yaml=$(cat "$gap_yaml_path")
    if [[ "${FLEET_INLINE_BRIEFING:-1}" == "1" ]]; then
        printf 'Ship gap %s.\n\nThe gap is already claimed for this session; lease is in .chump-locks/.\nYou are in worktree %s. Pre-flight has already run — do NOT re-run\n'\''chump gap list'\'', '\''gap-doctor'\'', '\''install-ambient-hooks'\'', or '\''chump-coord\nwatch'\''. Spend tokens on the implementation, not on discovery.\n\n══ GAP YAML (canonical) ══\n%s\n\n══ HARD RULES (full text in CLAUDE.md if you need it) ══\n[snip — same as production]\n\nWhen done, reply with the PR number only.\n' "$GAP_ID" "$wt_path" "$gap_yaml"
    else
        printf 'Ship gap %s in this repository. Read CLAUDE.md and AGENTS.md first. The gap is already claimed for this session; the lease is in .chump-locks/. Implement the gap per its description, commit via scripts/coord/chump-commit.sh, and ship via scripts/coord/bot-merge.sh --gap %s --auto-merge. Reply with the PR number only.\n' "$GAP_ID" "$GAP_ID"
    fi
}

# ── Test 1: default (inline-briefing) embeds the YAML + hard rules ───────────
echo "Test 1: FLEET_INLINE_BRIEFING=1 (default) — inline gap YAML"
PROMPT=$(FLEET_INLINE_BRIEFING=1 build_prompt INFRA-999)
if [[ "$PROMPT" == *"GAP YAML (canonical)"* ]] \
   && [[ "$PROMPT" == *"synthetic test gap"* ]] \
   && [[ "$PROMPT" == *"HARD RULES"* ]] \
   && [[ "$PROMPT" != *"Read CLAUDE.md and AGENTS.md first"* ]]; then
    echo "  PASS (briefing inline; legacy 'Read CLAUDE.md and AGENTS.md first' absent)"
else
    echo "  FAIL"
    echo "$PROMPT" | sed 's/^/    /' | head -10
    exit 1
fi

# ── Test 2: FLEET_INLINE_BRIEFING=0 reverts to legacy terse prompt ──────────
echo "Test 2: FLEET_INLINE_BRIEFING=0 — back-compat to legacy prompt"
PROMPT=$(FLEET_INLINE_BRIEFING=0 build_prompt INFRA-999)
if [[ "$PROMPT" == *"Read CLAUDE.md and AGENTS.md first"* ]] \
   && [[ "$PROMPT" != *"GAP YAML"* ]]; then
    echo "  PASS (legacy prompt restored)"
else
    echo "  FAIL"
    echo "$PROMPT" | sed 's/^/    /' | head -10
    exit 1
fi

# ── Test 3: missing gap YAML → fallback hint embedded, no crash ─────────────
echo "Test 3: missing gap YAML → fallback hint, no crash"
PROMPT=$(FLEET_INLINE_BRIEFING=1 build_prompt INFRA-MISSING)
if [[ "$PROMPT" == *"gap YAML not found"* ]] && [[ "$PROMPT" == *"INFRA-MISSING"* ]]; then
    echo "  PASS (graceful fallback when YAML missing)"
else
    echo "  FAIL"
    echo "$PROMPT" | sed 's/^/    /' | head -5
    exit 1
fi

# ── Test 4: production worker.sh contains the inline-briefing block ─────────
echo "Test 4: worker.sh contains the FLEET_INLINE_BRIEFING block"
if grep -q 'FLEET_INLINE_BRIEFING' "$WORKER" \
   && grep -q '══ GAP YAML' "$WORKER" \
   && grep -q '══ HARD RULES' "$WORKER"; then
    echo "  PASS (production worker.sh has the new prompt-construction block)"
else
    echo "  FAIL: worker.sh is missing the inline-briefing block"
    exit 1
fi

# ── Test 5: run-fleet.sh sets the cost-saving defaults ──────────────────────
echo "Test 5: run-fleet.sh exports the token-burn defaults"
RUN_FLEET="$REPO_ROOT/scripts/dispatch/run-fleet.sh"
if grep -q 'FLEET_TIMEOUT_S:-600' "$RUN_FLEET" \
   && grep -q 'FLEET_INLINE_BRIEFING:-1' "$RUN_FLEET" \
   && grep -q 'CHUMP_AMBIENT_INSTALL_SKIP:-1' "$RUN_FLEET" \
   && grep -q 'CHUMP_LESSONS_AT_SPAWN_N:-0' "$RUN_FLEET"; then
    echo "  PASS (all 4 token-burn defaults set in run-fleet.sh)"
else
    echo "  FAIL: missing one or more token-burn defaults in run-fleet.sh"
    exit 1
fi

echo ""
echo "All inline-briefing tests passed."
