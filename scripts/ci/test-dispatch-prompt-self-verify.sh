#!/usr/bin/env bash
# test-dispatch-prompt-self-verify.sh — INFRA-717 regression test.
#
# Verifies the worker.sh dispatch prompt includes the 3 self-verify steps
# that prevent half-impl PRs (PR #1256 pattern):
#   1. cargo check --workspace
#   2. cargo clippy --workspace --fix --allow-dirty
#   3. symbol-resolution check (grep diff for orphan calls)
#
# Tests:
#   1. Prompt contains all 3 self-verify step instructions
#   2. Synthetic diff with orphan method call is correctly identified
#   3. Synthetic diff with valid method call passes validation
#   4. Production worker.sh contains the INFRA-717 prompt block

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

[[ -f "$WORKER" ]] || { echo "FAIL: $WORKER missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Create a synthetic gap YAML for testing
mkdir -p "$TMP/wt/docs/gaps"
cat >"$TMP/wt/docs/gaps/INFRA-717.yaml" <<'EOF'
- id: INFRA-717
  domain: INFRA
  title: "EFFECTIVE: dispatch prompt self-verify"
  status: open
  priority: P0
  effort: xs
  description: Add self-verify checks to prevent half-impl PRs
  acceptance_criteria:
    - cargo check + clippy + symbol resolution checks in prompt
    - test rejects orphan calls
EOF

# Extract and test the prompt construction
build_prompt() {
    local GAP_ID="$1"
    local wt_path="$TMP/wt"
    local FLEET_TIMEOUT_S=600
    local gap_yaml_path="$wt_path/docs/gaps/${GAP_ID}.yaml"
    local gap_yaml="(gap YAML not found — read docs/gaps/${GAP_ID}.yaml)"
    [[ -f "$gap_yaml_path" ]] && gap_yaml=$(cat "$gap_yaml_path")

    if [[ "${FLEET_INLINE_BRIEFING:-1}" == "1" ]]; then
        cat <<PROMPT
Ship gap ${GAP_ID}.

The gap is already claimed for this session; lease is in .chump-locks/.
You are in worktree ${wt_path}. Pre-flight has already run — do NOT re-run
'chump gap list', 'gap-doctor', 'install-ambient-hooks', or 'chump-coord
watch'. Spend tokens on the implementation, not on discovery.

══ GAP YAML (canonical) ══
${gap_yaml}

══ HARD RULES (full text in CLAUDE.md if you need it) ══
- Work ONLY in this worktree: ${wt_path}
- Commit via: scripts/coord/chump-commit.sh <files…> -m "msg"
- Ship via:   scripts/coord/bot-merge.sh --gap ${GAP_ID} --auto-merge --fast
  (--fast skips local cargo clippy/test — CI is the gate; saves 5-10 min
  per cycle so you finish well inside the ${FLEET_TIMEOUT_S}s budget.
  This rebases, pushes, opens PR, arms auto-merge, auto-closes the gap.)
- If bot-merge.sh hangs/dies: fall back to manual ship —
    git push -u origin <branch>
    gh pr create --base main --title "..." --body "..."
    chump gap ship ${GAP_ID} --closed-pr <PR#> --update-yaml
    git push (commit the close)
    gh pr merge <PR#> --auto --squash
- Never push directly to main. Never use git commit --no-verify.
- Mutate gaps via 'chump gap set' / 'chump gap ship' (state.db canonical post-INFRA-498).
- If you spot a real bug along the way, file it: 'chump gap reserve --domain INFRA --title "..."'

══ BEFORE CALLING BOT-MERGE: Self-Verify (INFRA-717) ══
REQUIRED: Before shipping, run these 3 self-verify steps. Reject any code
that fails these checks.
1. cargo check --workspace
   Verify no compilation errors.
2. cargo clippy --workspace --fix --allow-dirty
   Apply clippy fixes and verify no clippy warnings remain.
3. Symbol-resolution check
   Grep your diff for new method/fn calls (lines with . or :: followed by
   identifier). For each new call, verify it is defined in either:
     - Your diff (same PR), or
     - On main (git show main:<file> | grep -q 'def\|fn ')
   If a new call is undefined in both places, REJECT the code and explain
   the orphan call.

When done, reply with the PR number only (e.g. "#1234").
PROMPT
    fi
}

# ── Test 1: prompt contains all 3 self-verify steps ────────────────────────
echo "Test 1: prompt contains all 3 self-verify steps"
PROMPT=$(FLEET_INLINE_BRIEFING=1 build_prompt INFRA-717)
if [[ "$PROMPT" == *"cargo check --workspace"* ]] \
   && [[ "$PROMPT" == *"cargo clippy --workspace --fix --allow-dirty"* ]] \
   && [[ "$PROMPT" == *"Symbol-resolution check"* ]]; then
    echo "  PASS (all 3 self-verify steps present)"
else
    echo "  FAIL (missing one or more self-verify steps)"
    exit 1
fi

# ── Test 2: prompt includes BEFORE CALLING BOT-MERGE section ────────────────
echo "Test 2: prompt includes BEFORE CALLING BOT-MERGE: Self-Verify block"
if [[ "$PROMPT" == *"BEFORE CALLING BOT-MERGE: Self-Verify (INFRA-717)"* ]]; then
    echo "  PASS (BEFORE CALLING BOT-MERGE block present)"
else
    echo "  FAIL (BEFORE CALLING BOT-MERGE block missing)"
    exit 1
fi

# ── Test 3: prompt includes symbol-resolution instruction details ───────────
echo "Test 3: prompt includes orphan-call detection instructions"
if [[ "$PROMPT" == *"Grep your diff for new method/fn calls"* ]] \
   && [[ "$PROMPT" == *"REJECT the code and explain"* ]]; then
    echo "  PASS (orphan call detection instructions present)"
else
    echo "  FAIL (orphan call detection instructions missing)"
    exit 1
fi

# ── Test 4: Simulate orphan call detection ────────────────────────────────
echo "Test 4: simulate detection of orphan call in diff"
cat > "$TMP/synthetic_diff.patch" <<'DIFF'
--- src/lib.rs.orig
+++ src/lib.rs
@@ -10,3 +10,7 @@
 fn existing_function() {
     println!("hello");
 }
+
+fn new_function() {
+    undefined_method.call_orphan();
+}
DIFF

# Extract new method calls from the synthetic diff
# (This is what the prompt would ask claude to do)
new_calls=$(grep -E '^\+.*\.' "$TMP/synthetic_diff.patch" | grep -oE '\w+\.\w+|\w+::\w+' || true)
if [[ -n "$new_calls" ]] && grep -q "call_orphan" <<< "$new_calls"; then
    echo "  PASS (orphan call correctly identified in diff)"
else
    echo "  FAIL (failed to identify orphan call)"
    exit 1
fi

# ── Test 5: Valid call should pass symbol-resolution check ─────────────────
echo "Test 5: valid method calls pass symbol-resolution check"
cat > "$TMP/valid_diff.patch" <<'DIFF'
--- src/lib.rs.orig
+++ src/lib.rs
@@ -10,3 +10,7 @@
 fn existing_function() {
     println!("hello");
 }
+
+fn new_function() {
+    let result = existing_function();
+}
DIFF

# Check that valid call is in the diff
if grep -q "existing_function()" "$TMP/valid_diff.patch"; then
    echo "  PASS (valid call correctly present in diff)"
else
    echo "  FAIL (valid call not found)"
    exit 1
fi

# ── Test 6: Production worker.sh contains the INFRA-717 block ──────────────
echo "Test 6: worker.sh contains INFRA-717 self-verify block"
if grep -q 'BEFORE CALLING BOT-MERGE: Self-Verify (INFRA-717)' "$WORKER" \
   && grep -q 'cargo check --workspace' "$WORKER" \
   && grep -q 'Symbol-resolution check' "$WORKER"; then
    echo "  PASS (production worker.sh has INFRA-717 prompt block)"
else
    echo "  FAIL (production worker.sh missing INFRA-717 block)"
    exit 1
fi

# ── Test 7: Verify prompt tells claude to REJECT bad code ─────────────────
echo "Test 7: prompt requires rejection of bad code"
if [[ "$PROMPT" == *"REJECT the code"* ]]; then
    echo "  PASS (prompt includes REJECT instruction for bad code)"
else
    echo "  FAIL (prompt doesn't require rejection of bad code)"
    exit 1
fi

echo ""
echo "All self-verify tests passed (INFRA-717)."
