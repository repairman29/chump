#!/usr/bin/env bash
# scripts/coord/gap-normalize-domains.sh — INFRA-318
#
# Normalize state.db's `gaps.domain` field to a single canonical UPPER form
# per logical domain. Caught 2026-05-02: state.db had ~30 distinct domain
# strings for ~20 logical domains:
#
#   INFRA + infra            (case-only drift, 328 rows total)
#   EVAL  + eval             (case-only drift, 97 rows)
#   FLEET + fleet            (case-only drift, 41 rows)
#   PRODUCT + product        (case-only drift, 24 rows)
#   META + (uppercase only)
#   RESEARCH + research      (case-only)
#   RELIABILITY + reliability (case-only)
#   DOC + doc                (case-only)
#   COG + cognition + cognitive + consciousness  (semantic drift, 37 rows)
#   COMP + competitive + completeness            (semantic drift, 23 rows)
#   AUTONOMY (always uppercase)
#   MEMORY (always uppercase)
#   FRONTIER (always uppercase)
#   AGENT + ACP + REMOVAL + SECURITY + QUALITY + TEST + AUTO (single form, OK)
#   ux → UX (single-row casing)
#
# Why it matters: every consumer that filters by `domain` (FLEET workers,
# audits, reports) had to .lower() defensively to handle drift. The
# canonical convention per AGENTS.md is the upper-case prefix used in
# gap-IDs (INFRA-N → domain INFRA). Normalizing once removes the
# defensive code burden.
#
# State.db is gitignored, so this script must be RUN locally on each
# operator's machine. Idempotent — safe to re-run.
#
# Usage:
#   bash scripts/coord/gap-normalize-domains.sh             # apply
#   bash scripts/coord/gap-normalize-domains.sh --dry-run   # report only
#
# Bypass / preview: --dry-run only prints the SQL that would run.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

if [[ ! -f "$DB" ]]; then
    echo "ERROR: state.db missing at $DB" >&2
    exit 2
fi

# Snapshot before
BEFORE_DISTINCT=$(sqlite3 "$DB" "SELECT COUNT(DISTINCT domain) FROM gaps;")
echo "[normalize] before: $BEFORE_DISTINCT distinct domain values"
sqlite3 "$DB" "SELECT domain, COUNT(*) FROM gaps GROUP BY domain HAVING domain != UPPER(domain) OR LOWER(domain) IN ('cognition','cognitive','consciousness','competitive','completeness') ORDER BY 2 DESC;" | head -20

# The canonical SQL.
SQL='
-- Step 1: case-only drift → UPPER
UPDATE gaps SET domain = UPPER(domain)
    WHERE LOWER(domain) IN (
        "infra","eval","fleet","product","meta","research","reliability",
        "doc","cog","test","security","removal","acp","quality","frontier",
        "memory","agent","autonomy","auto","ux"
    );

-- Step 2: semantic drift — collapse synonyms to canonical prefix
UPDATE gaps SET domain = "COG"
    WHERE LOWER(domain) IN ("consciousness","cognition","cognitive");
UPDATE gaps SET domain = "COMP"
    WHERE LOWER(domain) IN ("competitive","completeness");
UPDATE gaps SET domain = "UX"
    WHERE LOWER(domain) = "ux";
'

if [[ $DRY -eq 1 ]]; then
    echo
    echo "[normalize] DRY-RUN — would execute:"
    echo "$SQL"
    exit 0
fi

echo
echo "[normalize] applying..."
sqlite3 "$DB" "$SQL"

AFTER_DISTINCT=$(sqlite3 "$DB" "SELECT COUNT(DISTINCT domain) FROM gaps;")
echo "[normalize] after:  $AFTER_DISTINCT distinct domain values"
echo
echo "[normalize] final distribution:"
sqlite3 "$DB" "SELECT domain, COUNT(*) FROM gaps GROUP BY domain ORDER BY 2 DESC;"
