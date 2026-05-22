#!/usr/bin/env bash
# scripts/ci/test-public-doc-privacy.sh — DOC-050
#
# Scans docs/strategy/*.md (and other public-docs paths) for content patterns
# that violate docs/process/RESEARCH_INTEGRITY.md:28-29:
#
#   "Do not state magnitudes, model names, or per-eval IDs in public docs,
#    PRs, or external communications."
#
# Patterns flagged:
#   - Specific empirical magnitudes (+/-0.NN style deltas, n=NN sample sizes)
#   - Specific model names + version (haiku-4, opus-4, sonnet-4, claude-3, qwen2.5, llama-3, etc.)
#   - Per-eval gap IDs (COG-NN, EVAL-NN) — these belong in the private companion repo
#
# Bypass: a doc file may declare itself research-private exempt by including
# the literal marker '<!-- research-privacy-exempt: <reason> -->' on a single
# line. Audit-logged.
#
# Exit: 0 = clean, 1 = at least one violation found

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Paths to scan. Add more if other public-doc subtrees are introduced.
SCAN_PATHS=(
    "$REPO_ROOT/docs/strategy"
    "$REPO_ROOT/docs/product"
)

# Pattern definitions. Each line is "PATTERN_NAME|EXTENDED_REGEX|EXAMPLE_FLAGGED".
# RESEARCH_INTEGRITY.md:28-29 specifies the three categories: magnitudes,
# model-names, per-eval-IDs.
declare -a PATTERNS=(
    'specific_pp_delta|[+-]0\.[0-9]+ ?(pp|percentage point|absolute rate)|+0.14 pp'
    'sample_size|\b[nN] ?= ?[0-9]+\b|n=100'
    'wilson_ci_specific|±0\.[0-9]+|±0.22'
    'model_haiku|\bhaiku-[0-9]+(-[0-9]+)?\b|haiku-4-5'
    'model_opus|\bopus-[0-9]+(-[0-9]+)?\b|opus-4-5'
    'model_sonnet|\bsonnet-[0-9]+(-[0-9]+)?\b|sonnet-4-5'
    'model_claude_versioned|\bclaude-[0-9]+(\.[0-9]+)?(-[a-z]+)?\b|claude-3-opus'
    'model_qwen|\bqwen[0-9]+(\.[0-9]+)?(:[0-9]+b?)?\b|qwen2.5:14b'
    'model_llama|\bllama-?[0-9]+(\.[0-9]+)?\b|llama-3'
    'per_eval_cog|\bCOG-[0-9]+\b|COG-014'
    'per_eval_eval|\bEVAL-[0-9]+\b|EVAL-010'
)

violations=0
files_scanned=0

for scan_root in "${SCAN_PATHS[@]}"; do
    [[ -d "$scan_root" ]] || continue
    while IFS= read -r -d '' md; do
        files_scanned=$((files_scanned + 1))
        # Bypass: per-file exemption marker
        if grep -q -- '<!-- research-privacy-exempt:' "$md" 2>/dev/null; then
            continue
        fi
        for spec in "${PATTERNS[@]}"; do
            IFS='|' read -r name regex example <<< "$spec"
            if hits="$(grep -nE -- "$regex" "$md" 2>/dev/null)"; then
                rel="${md#"$REPO_ROOT/"}"
                while IFS= read -r line; do
                    echo "VIOLATION $name in $rel: $line"
                    violations=$((violations + 1))
                done <<< "$hits"
            fi
        done
    done < <(find "$scan_root" -type f -name '*.md' -print0)
done

if [[ $files_scanned -eq 0 ]]; then
    echo "FAIL DOC-050: no markdown files found in scan paths (regression in repo layout?)"
    exit 1
fi

if [[ $violations -gt 0 ]]; then
    echo ""
    echo "FAIL DOC-050: $violations RESEARCH_INTEGRITY.md violation(s) in $files_scanned scanned file(s)"
    echo "  Reference: docs/process/RESEARCH_INTEGRITY.md:28-29"
    echo "  Fix: move specifics to the private companion repo (chump-proprietary), or"
    echo "       add '<!-- research-privacy-exempt: <reason> -->' to the file if intentional"
    exit 1
fi

echo "OK DOC-050: $files_scanned public docs scanned, 0 RESEARCH_INTEGRITY violations"
