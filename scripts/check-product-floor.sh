#!/usr/bin/env bash
# check-product-floor.sh — PRODUCT-010 weekly product-commit floor check.
#
# Scans the last 7 days of merged PRs for product-touching commits. A PR
# counts as "product" if EITHER condition holds:
#   - its title or body references a PRODUCT-*, REL-*, UX-*, or COMP-010 gap ID
#   - any file it touches is under web/, crates/chump-pwa/, app/, or a
#     known product path
#
# If the rolling 7-day window has zero product PRs merged to main, emit
# `ALERT kind=product_drought` to ambient.jsonl so the next Red Letter pass
# picks it up. Intended to run once a day via launchd; also runnable
# manually and in CI (`--json` prints a machine-readable summary).
#
# Usage:
#   ./scripts/check-product-floor.sh              # human output + ALERT on drought
#   ./scripts/check-product-floor.sh --json       # json summary to stdout
#   ./scripts/check-product-floor.sh --days 14    # custom window (default 7)
#   ./scripts/check-product-floor.sh --quiet      # suppress output when healthy
#
# Exit codes:
#   0   — floor met (>=1 product PR in window)
#   10  — product drought (no product PRs) — alert emitted
#   2   — usage error
#
# Filed by PRODUCT-010 (Red Letter Issues #2 + #3, 2026-04-21).

set -euo pipefail

DAYS=7
JSON=0
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)  DAYS="$2"; shift ;;
        --json)  JSON=1 ;;
        --quiet) QUIET=1 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

# Product-touching file path prefixes (newline-separated for the python side).
export PRODUCT_PATHS='web/
crates/chump-pwa/
app/
install/brew/
scripts/install-'

# Product-touching gap-ID regex (for PR title/body scan).
export PRODUCT_GAP_REGEX='PRODUCT-[0-9]+|REL-[0-9]+|COMP-010|UX-[0-9]+'
export DAYS

SINCE_DATE=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)
export SINCE_DATE

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI required" >&2
    exit 2
fi

export PR_JSON
PR_JSON=$(gh pr list --state merged --limit 100 \
    --json number,title,body,mergedAt,files \
    --jq "[.[] | select(.mergedAt >= \"$SINCE_DATE\")]" 2>/dev/null || echo '[]')

SUMMARY=$(python3 <<'PYEOF'
import json, os, re
prs = json.loads(os.environ.get("PR_JSON", "[]") or "[]")
paths = [p for p in os.environ["PRODUCT_PATHS"].splitlines() if p.strip()]
gap_re = re.compile(os.environ["PRODUCT_GAP_REGEX"])
days = int(os.environ["DAYS"])
since = os.environ["SINCE_DATE"]

def classify(pr):
    text = (pr.get("title") or "") + "\n" + (pr.get("body") or "")
    if gap_re.search(text):
        return "gap-id-match"
    for f in (pr.get("files") or []):
        fp = f.get("path", "")
        for p in paths:
            if fp.startswith(p):
                return f"path:{p}"
    return None

product = []
for pr in prs:
    r = classify(pr)
    if r:
        product.append({
            "number": pr["number"],
            "title": pr["title"],
            "reason": r,
            "mergedAt": pr["mergedAt"],
        })

print(json.dumps({
    "window_days": days,
    "since": since,
    "total_merged_prs": len(prs),
    "product_prs": len(product),
    "product_pr_list": product,
    "drought": len(product) == 0,
}, indent=2))
PYEOF
)

PRODUCT_COUNT=$(echo "$SUMMARY" | python3 -c "import json,sys; print(json.load(sys.stdin)['product_prs'])")
TOTAL=$(echo "$SUMMARY" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_merged_prs'])")
DROUGHT=$(echo "$SUMMARY" | python3 -c "import json,sys; print('1' if json.load(sys.stdin)['drought'] else '0')")

if [[ $JSON -eq 1 ]]; then
    echo "$SUMMARY"
else
    if [[ $DROUGHT == "1" ]]; then
        echo "⚠️  product drought: 0 product PRs of $TOTAL merged in last $DAYS days"
        echo "   paths counted: web/ crates/chump-pwa/ app/ install/brew/ scripts/install-*"
        echo "   gap prefixes:  PRODUCT-*, REL-*, COMP-010, UX-*"
    elif [[ $QUIET -eq 0 ]]; then
        echo "OK — $PRODUCT_COUNT product PR(s) of $TOTAL merged in last $DAYS days"
        echo "$SUMMARY" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for p in d['product_pr_list']:
    print(f\"  #{p['number']} ({p['reason']}) — {p['title'][:80]}\")
"
    fi
fi

if [[ $DROUGHT == "1" ]]; then
    if [[ -x "$REPO_ROOT/scripts/broadcast.sh" ]]; then
        "$REPO_ROOT/scripts/broadcast.sh" ALERT kind=product_drought \
            "0 product PRs merged in last $DAYS days — product-commit floor breached" \
            >/dev/null 2>&1 || true
    else
        mkdir -p "$(dirname "$AMBIENT")"
        printf '{"event":"ALERT","kind":"product_drought","ts":"%s","reason":"0 product PRs merged in last %s days"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DAYS" >> "$AMBIENT"
    fi
    exit 10
fi

exit 0
