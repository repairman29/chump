#!/usr/bin/env bash
# scripts/ci/test-content-bots-manifests.sh — INFRA-1690
#
# Foundation smoke test for the Content Bots Suite (META-066). Asserts the
# 4 bot prompt manifests + bots.yaml registry + README all exist and
# satisfy the documented contract.
#
# This is the foundation — no dispatcher / pipeline / fleet wiring yet.
# All bots default-disabled so this manifest landing produces zero behavior
# change. The test asserts that invariant + the manifest schema.
#
# Exit: 0 = contracts intact, 1 = at least one assertion failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOTS_DIR="$REPO_ROOT/docs/agents/content-bots"

failures=0

assert_file() {
    local f="$1" desc="$2"
    if [[ ! -f "$f" ]]; then
        echo "FAIL: missing $desc → ${f#"$REPO_ROOT/"}"
        failures=$((failures + 1))
        return 1
    fi
    if [[ ! -s "$f" ]]; then
        echo "FAIL: empty $desc → ${f#"$REPO_ROOT/"}"
        failures=$((failures + 1))
        return 1
    fi
    return 0
}

assert_grep() {
    local f="$1" pattern="$2" desc="$3"
    if ! grep -qE -- "$pattern" "$f" 2>/dev/null; then
        echo "FAIL: $desc"
        echo "       file: ${f#"$REPO_ROOT/"}"
        echo "       pattern: $pattern"
        failures=$((failures + 1))
        return 1
    fi
    return 0
}

# ── 1. All 4 bot prompt manifests exist + non-empty ──────────────────────────
assert_file "$BOTS_DIR/pmm.md"         "PMM Bot manifest"
assert_file "$BOTS_DIR/docubot.md"     "DocuBot manifest"
assert_file "$BOTS_DIR/evangelist.md"  "Evangelist Bot manifest"
assert_file "$BOTS_DIR/copybot.md"     "CopyBot manifest"

# ── 2. Each manifest has the canonical structure (System Prompt + Tasks + Voice/Guardrails) ──
for bot in pmm docubot evangelist copybot; do
    f="$BOTS_DIR/$bot.md"
    [[ -f "$f" ]] || continue
    assert_grep "$f" '^## System Prompt'    "$bot.md missing 'System Prompt' section"
    assert_grep "$f" '^## (Your )?Tasks'    "$bot.md missing 'Tasks' section"
    assert_grep "$f" '(Voice Guardrails|Guardrails|Formatting Rules)' "$bot.md missing voice/guardrails/formatting section"
    assert_grep "$f" '\*\*Bot ID:\*\* `'"$bot"'`' "$bot.md missing canonical Bot ID header"
done

# ── 3. bots.yaml exists + has all 4 bot_ids + all default_enabled=false ──────
BOTS_YAML="$BOTS_DIR/bots.yaml"
assert_file "$BOTS_YAML" "bots.yaml registry"

for bot in pmm docubot evangelist copybot; do
    assert_grep "$BOTS_YAML" "bot_id: $bot" "bots.yaml missing entry for $bot"
done

# Count of default_enabled: false → must equal 4 (foundation invariant)
disabled_count="$(grep -cE '^\s*default_enabled:\s*false' "$BOTS_YAML" 2>/dev/null || echo 0)"
if [[ "${disabled_count:-0}" -ne 4 ]]; then
    echo "FAIL: bots.yaml expected 4 'default_enabled: false' entries, found $disabled_count"
    failures=$((failures + 1))
fi

# No bot should have default_enabled: true at this stage
if grep -qE '^\s*default_enabled:\s*true' "$BOTS_YAML" 2>/dev/null; then
    echo "FAIL: bots.yaml has at least one default_enabled: true — foundation must be off-by-default"
    failures=$((failures + 1))
fi

# Pipeline integrity: copybot must list pmm + docubot + evangelist as predecessors.
# Use awk window from "bot_id: copybot" forward (copybot is the terminus, last in file)
# and require the predecessors line within that window.
if ! awk '/bot_id: copybot/{p=1} p' "$BOTS_YAML" 2>/dev/null \
        | grep -qE 'pipeline_predecessors:\s*\[\s*pmm.*docubot.*evangelist\s*\]'; then
    echo "FAIL: bots.yaml copybot must list pipeline_predecessors: [pmm, docubot, evangelist]"
    failures=$((failures + 1))
fi

# ── 4. README references all 4 bot files ─────────────────────────────────────
README="$BOTS_DIR/README.md"
assert_file "$README" "Content Bots Suite README"
for bot in pmm docubot evangelist copybot; do
    assert_grep "$README" "$bot\\.md" "README missing link to $bot.md"
done

# ── 5. README references the productization umbrella META-066 ────────────────
assert_grep "$README" 'META-066' "README missing META-066 cross-reference"

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1690: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1690: Content Bots Suite foundation intact"
echo "  4 bot manifests, bots.yaml registry valid, README cross-links resolved, all default-disabled"
