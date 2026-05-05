#!/usr/bin/env bash
# cog-041-semantic-vs-recency.sh — EVAL-098
#
# Mechanical comparison of CHUMP_LESSONS_SEMANTIC=0 (recency × frequency)
# vs CHUMP_LESSONS_SEMANTIC=1 (TF-IDF cosine, COG-041) on 20 closed
# gaps. Reports Jaccard overlap of returned lesson sets.
#
# Methodology locked in docs/eval/preregistered/EVAL-098.md.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP="${CHUMP_BIN:-$REPO_ROOT/target/release/chump}"
[[ -x "$CHUMP" ]] || { echo "FATAL: $CHUMP not built; cargo build --release --bin chump first"; exit 2; }

DATE=$(date +%Y-%m-%d)
OUT="${EVAL_OUT:-$REPO_ROOT/docs/eval/COG-041-semantic-vs-recency-$DATE.md}"

# --- Pick 20 gaps per the prereg stratification ---------------------------
PICK_QUERY='
SELECT id FROM gaps
WHERE status = "done"
  AND length(title) >= 20
  AND (closed_date < date("now","-1 day") OR closed_date IS NULL)
ORDER BY
  CASE
    WHEN domain="INFRA" THEN 0
    WHEN domain="COG" THEN 1
    WHEN domain IN ("EVAL","RESEARCH") THEN 2
    ELSE 3
  END,
  id DESC
LIMIT 40
'
ALL_IDS=$(sqlite3 "$REPO_ROOT/.chump/state.db" "$PICK_QUERY")
# `|| true` so an empty stratum (e.g. no recent done COG-* gaps) doesn't
# kill the harness under set -euo pipefail.
INFRA_IDS=$(echo "$ALL_IDS" | { grep -E '^INFRA-' || true; } | head -10)
COG_IDS=$(echo "$ALL_IDS" | { grep -E '^COG-' || true; } | head -5)
EVAL_IDS=$(echo "$ALL_IDS" | { grep -E '^(EVAL-|RESEARCH-)' || true; } | head -5)
PICKED=$(printf '%s\n%s\n%s\n' "$INFRA_IDS" "$COG_IDS" "$EVAL_IDS" | sed '/^$/d' | head -20)
N=$(echo "$PICKED" | wc -l | tr -d ' ')

if [[ "$N" -lt 5 ]]; then
    echo "FATAL: not enough closed gaps to sample ($N picked, need ≥5)"; exit 2
fi

# --- Helper: extract lesson directives from a briefing -------------------
# The briefing prints "## Top relevant reflections (chump_improvement_targets)"
# followed by zero or more lines like "- [High] <directive> — _<domain>_".
extract_lessons() {
    awk '
        /^## Top relevant reflections/ { in_block=1; next }
        in_block && /^## / && !/^## Top/ { in_block=0 }
        in_block && /^- \[/ {
            # Strip leading "- [Priority] " and trailing " — _<domain>_"
            sub(/^- \[[^]]*\] */, "")
            sub(/ — _[^_]*_$/, "")
            print
        }
    '
}

# --- Jaccard over two newline-delimited sorted-uniq sets -----------------
jaccard() {
    local a="$1" b="$2"
    if [[ -z "$a" && -z "$b" ]]; then echo "1.0"; return; fi
    if [[ -z "$a" || -z "$b" ]]; then echo "0.0"; return; fi
    local ua ub inter union
    ua=$(printf '%s\n' "$a" | sort -u)
    ub=$(printf '%s\n' "$b" | sort -u)
    inter=$(comm -12 <(echo "$ua") <(echo "$ub") | wc -l | tr -d ' ')
    union=$(printf '%s\n%s\n' "$ua" "$ub" | sort -u | wc -l | tr -d ' ')
    if [[ "$union" -eq 0 ]]; then echo "1.0"; return; fi
    awk -v i="$inter" -v u="$union" 'BEGIN { printf "%.3f", i/u }'
}

# --- Run the comparison ---------------------------------------------------
mkdir -p "$(dirname "$OUT")"
{
    echo "# EVAL-098: COG-041 semantic vs recency-frequency lesson rankings"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Methodology: docs/eval/preregistered/EVAL-098.md"
    echo
    echo "## Sampled gaps (n=$N)"
    echo
    echo '```'
    echo "$PICKED" | nl -ba
    echo '```'
    echo
    echo "## Per-gap Jaccard overlap"
    echo
    echo "| Gap | \|A∩B\| | \|A∪B\| | Jaccard | B-only top | A-only top |"
    echo "|-----|--------|--------|---------|------------|------------|"
} > "$OUT"

below_06=0
sum_j="0.0"
empty_b=0

while IFS= read -r gap_id; do
    [[ -z "$gap_id" ]] && continue
    a=$(CHUMP_LESSONS_SEMANTIC=0 "$CHUMP" --briefing "$gap_id" 2>/dev/null | extract_lessons)
    b=$(CHUMP_LESSONS_SEMANTIC=1 "$CHUMP" --briefing "$gap_id" 2>/dev/null | extract_lessons)
    if [[ -z "$b" ]]; then
        empty_b=$((empty_b + 1))
    fi
    a_set=$(printf '%s\n' "$a" | sort -u | sed '/^$/d')
    b_set=$(printf '%s\n' "$b" | sort -u | sed '/^$/d')
    inter_n=$(comm -12 <(echo "$a_set") <(echo "$b_set") 2>/dev/null | wc -l | tr -d ' ')
    union_n=$(printf '%s\n%s\n' "$a_set" "$b_set" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')
    j=$(jaccard "$a_set" "$b_set")
    sum_j=$(awk -v s="$sum_j" -v j="$j" 'BEGIN { printf "%.4f", s+j }')
    awk_below=$(awk -v j="$j" 'BEGIN { print (j+0 < 0.6) ? "1" : "0" }')
    if [[ "$awk_below" == "1" ]]; then below_06=$((below_06 + 1)); fi
    b_only=$(comm -13 <(echo "$a_set") <(echo "$b_set") 2>/dev/null | head -1 | cut -c1-50)
    a_only=$(comm -23 <(echo "$a_set") <(echo "$b_set") 2>/dev/null | head -1 | cut -c1-50)
    echo "| $gap_id | $inter_n | $union_n | $j | ${b_only:--} | ${a_only:--} |" >> "$OUT"
done <<< "$PICKED"

mean_j=$(awk -v s="$sum_j" -v n="$N" 'BEGIN { if (n>0) printf "%.3f", s/n; else print "0.0" }')
frac_below=$(awk -v b="$below_06" -v n="$N" 'BEGIN { if (n>0) printf "%.2f", b/n; else print "0.0" }')

{
    echo
    echo "## Aggregate"
    echo
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Sample size (n) | $N |"
    echo "| Mean Jaccard | $mean_j |"
    echo "| Fraction meaningfully different (Jaccard < 0.6) | $frac_below |"
    echo "| Mode-B empty (fell back to recency-freq) | $empty_b / $N |"
    echo
    echo "## Decision (per prereg)"
    echo
    decision="REJECT H1 (semantic mode does NOT produce meaningfully different rankings on this corpus)"
    if awk -v f="$frac_below" 'BEGIN { exit !(f+0 >= 0.50) }'; then
        decision="ACCEPT H1 (semantic mode produces meaningfully different rankings on ≥ 50% of sampled gaps)"
    fi
    echo "**Verdict:** $decision"
    echo
    echo "**What this eval can claim:** divergence only — not quality. A follow-up downstream"
    echo "eval (e.g. ship-rate per lesson set) is required before flipping the default."
} >> "$OUT"

echo "wrote $OUT"
echo
echo "Verdict: $decision"
echo "  Mean Jaccard:               $mean_j"
echo "  Frac Jaccard < 0.6:         $frac_below"
echo "  Mode-B empty (fallback):    $empty_b / $N"
