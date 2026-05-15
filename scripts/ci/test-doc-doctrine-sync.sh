#!/usr/bin/env bash
# test-doc-doctrine-sync.sh — DOC-031
#
# CI lint: verify that canonical coordination doctrine rules are not siloed in
# only one of the three agent instruction files:
#   - AGENTS.md          (cross-tool canonical source)
#   - CLAUDE.md          (Claude-Code-specific overlay referencing AGENTS.md)
#   - docs/process/CHUMP_DISPATCH_RULES.md  (injected into every dispatched agent)
#
# Rules:
#   R1. AGENTS.md is the canonical source — it must contain each rule phrase
#       that appears as a "hard rule" in DISPATCH_RULES.md.
#   R2. CLAUDE.md must contain a cross-reference to AGENTS.md (not be a silo).
#   R3. DISPATCH_RULES.md must contain a cross-reference to AGENTS.md (not a silo).
#   R4. Each canonical anchor phrase must appear in AGENTS.md.
#
# Adding a new coordination rule? Put it in AGENTS.md first, then reference it
# from CLAUDE.md and DISPATCH_RULES.md. Do NOT add it only to one file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AGENTS="$REPO_ROOT/AGENTS.md"
CLAUDE="$REPO_ROOT/CLAUDE.md"
DISPATCH="$REPO_ROOT/docs/process/CHUMP_DISPATCH_RULES.md"

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== DOC-031 doctrine-sync lint ==="

# ── R2: CLAUDE.md references AGENTS.md ───────────────────────────────────────
echo "--- R2: CLAUDE.md references AGENTS.md ---"
if grep -q 'AGENTS\.md' "$CLAUDE" 2>/dev/null; then
    ok "CLAUDE.md contains reference to AGENTS.md"
else
    fail "CLAUDE.md has no reference to AGENTS.md — it may be a silo"
fi
# Specifically check for the canonical-source declaration.
if grep -qiE 'Canonical.*AGENTS\.md|AGENTS\.md.*canonical' "$CLAUDE" 2>/dev/null; then
    ok "CLAUDE.md declares AGENTS.md as canonical source"
else
    fail "CLAUDE.md missing canonical-source declaration for AGENTS.md"
fi

# ── R3: DISPATCH_RULES.md references AGENTS.md ───────────────────────────────
echo "--- R3: DISPATCH_RULES.md references AGENTS.md ---"
if grep -q 'AGENTS\.md' "$DISPATCH" 2>/dev/null; then
    ok "DISPATCH_RULES.md contains reference to AGENTS.md"
else
    fail "DISPATCH_RULES.md has no reference to AGENTS.md — it may be a silo"
fi

# ── R1+R4: Canonical anchor phrases must appear in AGENTS.md ─────────────────
# Each anchor below is a distinct coordination rule. If a rule appears in
# DISPATCH_RULES.md or CLAUDE.md, it MUST also appear in AGENTS.md.
# Format: "anchor_phrase:::human description"
ANCHORS=(
    "Never push.*main:::Never-push-to-main rule"
    "chump-commit:::chump-commit.sh commit wrapper"
    "Never leave a lease:::lease cleanup rule"
    "bot-merge:::bot-merge.sh ship pipeline"
    "gap-preflight:::preflight check before claiming"
    "cargo fmt:::cargo fmt before committing Rust"
    "gap ship:::chump gap ship command"
)

echo "--- R4: canonical anchors present in AGENTS.md ---"
for entry in "${ANCHORS[@]}"; do
    anchor="${entry%%:::*}"
    desc="${entry##*:::}"
    if grep -qE "$anchor" "$AGENTS" 2>/dev/null; then
        ok "AGENTS.md has: $desc"
    else
        fail "AGENTS.md MISSING anchor for: $desc (pattern: $anchor)"
    fi
done

# ── R1: Rules in DISPATCH_RULES.md are grounded in AGENTS.md ─────────────────
# Extract bullet-point hard rules from DISPATCH_RULES.md and check each
# has at least one key word from its first 8 words present in AGENTS.md.
echo "--- R1: DISPATCH_RULES.md hard rules grounded in AGENTS.md ---"
in_hard_rules=0
while IFS= read -r line; do
    if [[ "$line" == "## Hard rules"* ]]; then
        in_hard_rules=1; continue
    fi
    if [[ $in_hard_rules -eq 1 && "$line" == "##"* ]]; then
        in_hard_rules=0
    fi
    if [[ $in_hard_rules -eq 1 && "$line" == "- **"* ]]; then
        # Extract the bold rule name (between ** ** markers)
        rule_name=$(echo "$line" | sed -E 's/^- \*\*([^*]+)\*\*.*/\1/' | tr '[:upper:]' '[:lower:]')
        # Use first meaningful word (skip "never", "always", "run") as search term
        key_word=$(echo "$rule_name" | grep -oE '[a-z][a-z-]+' | grep -vE '^(never|always|run|the|a|an|do|not|with|to|any|in|on|for)' | head -1)
        if [[ -z "$key_word" ]]; then continue; fi
        if grep -qi "$key_word" "$AGENTS" 2>/dev/null; then
            ok "DISPATCH hard rule grounded in AGENTS.md: '$rule_name' (via '$key_word')"
        else
            fail "DISPATCH hard rule NOT found in AGENTS.md: '$rule_name' (searched: '$key_word')"
        fi
    fi
done < "$DISPATCH"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    echo ""
    echo "Fix: add missing rules to AGENTS.md (the canonical source), then"
    echo "reference them from CLAUDE.md and DISPATCH_RULES.md."
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS — doctrine synchronized across AGENTS.md, CLAUDE.md, DISPATCH_RULES.md"
