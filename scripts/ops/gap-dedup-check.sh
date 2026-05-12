#!/usr/bin/env bash
# gap-dedup-check.sh — INFRA-881
#
# Detects near-duplicate open gaps using TF-IDF cosine similarity on titles.
# Reports pairs with similarity > THRESHOLD (default 0.85).
#
# Usage:
#   gap-dedup-check.sh [--threshold N] [--apply] [--json] [--dry-run]
#
# Options:
#   --threshold N   Cosine similarity threshold (default: 0.85, range 0..1)
#   --apply         Close the lower-priority gap in each duplicate pair
#                   (lower priority = higher priority number; when equal, keep newer)
#   --json          Output JSON array of duplicate pairs
#   --dry-run       With --apply: print what would be closed, but don't modify
#   --help          Show this message
#
# Examples:
#   gap-dedup-check.sh
#   gap-dedup-check.sh --threshold 0.90
#   gap-dedup-check.sh --apply --dry-run
#   gap-dedup-check.sh --apply

set -uo pipefail

THRESHOLD="0.85"
APPLY=0
JSON_OUT=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --apply)     APPLY=1; shift ;;
        --json)      JSON_OUT=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -25 | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

REPO_ROOT="${CHUMP_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"

# ── Get open gaps from chump gap list --json ──────────────────────────────────
RAW_GAPS=$(chump gap list --status open --json 2>/dev/null) || {
    echo "ERROR: 'chump gap list --status open --json' failed" >&2
    exit 1
}

# ── Compute TF-IDF cosine similarity in Python ────────────────────────────────
PAIRS=$(python3 - <<PYEOF
import json, math, re, sys

gaps = json.loads(r'''$RAW_GAPS''')
threshold = float("$THRESHOLD")

# Keep only open gaps with non-empty titles
gaps = [g for g in gaps if g.get("status") == "open" and g.get("title","").strip()]

def tokenize(text):
    # Lowercase, strip punctuation, split on whitespace
    text = text.lower()
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return [t for t in text.split() if len(t) > 1]

# Priority numeric value (lower number = higher priority)
priority_map = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
def priority_num(g):
    return priority_map.get(g.get("priority","P3"), 3)

def created_ts(g):
    return g.get("created_at") or 0

# Build TF-IDF
docs = [tokenize(g["title"]) for g in gaps]

# IDF: log(N / df) for each term
from collections import Counter
N = len(docs)
df = Counter()
for doc in docs:
    for term in set(doc):
        df[term] += 1

def idf(term):
    return math.log((N + 1) / (df.get(term, 0) + 1)) + 1  # smoothed

def tfidf_vec(tokens):
    tf = Counter(tokens)
    total = len(tokens) or 1
    vec = {}
    for term, cnt in tf.items():
        vec[term] = (cnt / total) * idf(term)
    return vec

def cosine(v1, v2):
    common = set(v1) & set(v2)
    if not common:
        return 0.0
    dot = sum(v1[t] * v2[t] for t in common)
    mag1 = math.sqrt(sum(x*x for x in v1.values()))
    mag2 = math.sqrt(sum(x*x for x in v2.values()))
    if mag1 == 0 or mag2 == 0:
        return 0.0
    return dot / (mag1 * mag2)

vecs = [tfidf_vec(doc) for doc in docs]

pairs = []
for i in range(len(gaps)):
    for j in range(i + 1, len(gaps)):
        sim = cosine(vecs[i], vecs[j])
        if sim >= threshold:
            ga, gb = gaps[i], gaps[j]
            # Determine which to keep (lower priority_num = keep) and close the other
            pa, pb = priority_num(ga), priority_num(gb)
            if pa < pb:
                keep, close = ga, gb
            elif pb < pa:
                keep, close = gb, ga
            else:
                # Same priority — keep the one created later (more recent = more refined)
                if created_ts(ga) >= created_ts(gb):
                    keep, close = ga, gb
                else:
                    keep, close = gb, ga
            pairs.append({
                "keep_id":    keep["id"],
                "keep_title": keep["title"],
                "close_id":   close["id"],
                "close_title": close["title"],
                "similarity": round(sim, 4),
            })

print(json.dumps(pairs))
PYEOF
)

if [[ -z "$PAIRS" || "$PAIRS" == "null" ]]; then
    echo "ERROR: similarity computation failed" >&2
    exit 1
fi

PAIR_COUNT=$(python3 -c "import json; print(len(json.loads(r'''$PAIRS''')))")

# ── Output ────────────────────────────────────────────────────────────────────
if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '%s\n' "$PAIRS"
    exit 0
fi

if [[ "$PAIR_COUNT" -eq 0 ]]; then
    echo "No near-duplicate gaps found (threshold: $THRESHOLD)."
    exit 0
fi

echo "Near-duplicate gap pairs (similarity ≥ $THRESHOLD):"
echo
python3 - <<PYEOF
import json
pairs = json.loads(r'''$PAIRS''')
for p in pairs:
    print(f"  [{p['similarity']:.3f}]  KEEP  {p['keep_id']:12s}  {p['keep_title'][:60]}")
    print(f"           CLOSE {p['close_id']:12s}  {p['close_title'][:60]}")
    print()
PYEOF

# ── Apply mode: close duplicates ──────────────────────────────────────────────
if [[ "$APPLY" -eq 1 ]]; then
    echo "Closing duplicate gaps..."
    echo

    python3 - <<PYEOF | while IFS= read -r line; do
import json
pairs = json.loads(r'''$PAIRS''')
for p in pairs:
    print(f"{p['close_id']}\t{p['keep_id']}")
PYEOF
        IFS=$'\t' read -r CLOSE_ID KEEP_ID <<< "$line"
        NOTE="duplicate of $KEEP_ID — closed by gap-dedup-check.sh"

        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "  [dry-run] would close $CLOSE_ID (duplicate of $KEEP_ID)"
        else
            echo "  Closing $CLOSE_ID (duplicate of $KEEP_ID)..."
            if chump gap ship "$CLOSE_ID" \
                --status "closed" \
                --notes "$NOTE" \
                --update-yaml 2>/dev/null; then
                echo "  ✓ closed $CLOSE_ID"
            else
                echo "  ✗ failed to close $CLOSE_ID" >&2
            fi
        fi
    done
fi
