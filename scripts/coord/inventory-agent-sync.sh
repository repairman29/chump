#!/usr/bin/env bash
# scripts/coord/inventory-agent-sync.sh — INFRA-2366 (META-271 follow-up)
#
# Agent-awareness sync: cross-references shipped artifacts (introducing_pr IS NOT NULL,
# last 30d) against agent docs (.claude/agents/*.md, docs/process/*.md, AGENTS.md,
# CLAUDE.md) and surfaces artifacts with zero mentions in any agent doc as
# quartermaster-class findings.
#
# scanner-anchor: "kind":"inventory_agent_sync_finding"
# scanner-anchor: "kind":"inventory_agent_sync_run"
#
# Usage:
#   scripts/coord/inventory-agent-sync.sh [--window-days N] [--json] [--dry-run]
#   scripts/coord/inventory-agent-sync.sh --help
#
# Options:
#   --window-days N   Days back to scan artifact_index.last_modified_at (default: 30)
#   --json            Emit machine-readable JSON array of findings to stdout
#   --dry-run         Report only; do not emit ambient events
#   --help | -h       Print this header
#
# Exit codes:
#   0 — success (findings are advisory, not a gate)
#   1 — invalid argument
#   2 — inventory DB not found or unreadable
#   3 — sqlite3 not available
#
# Env vars:
#   CHUMP_AGENT_SYNC_INVENTORY_DB    Override DB path (default: .chump/inventory.db)
#   CHUMP_AGENT_SYNC_AMBIENT_LOG     Override ambient log (default: .chump-locks/ambient.jsonl)
#   CHUMP_SESSION_ID                 Session identifier for ambient events
#
# Rust-First-Bypass: bash glue + read-only sqlite3 query + grep sweep; no canonical state mutation
# Rust-First-Bypass-Accept: loc,state

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi

LOCK_DIR="$MAIN_REPO/.chump-locks"
CHUMP_DIR="${CHUMP_DIR:-$MAIN_REPO/.chump}"
AMBIENT_LOG="${CHUMP_AGENT_SYNC_AMBIENT_LOG:-${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}}"
SESSION_ID="${CHUMP_SESSION_ID:-inventory-agent-sync-$$}"
INVENTORY_DB="${CHUMP_AGENT_SYNC_INVENTORY_DB:-$CHUMP_DIR/inventory.db}"

# Defaults
WINDOW_DAYS=30
EMIT_JSON=0
DRY_RUN=0

# ── arg parse ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-days)
            if [[ -z "${2:-}" || ! "${2:-}" =~ ^[0-9]+$ ]]; then
                echo "inventory-agent-sync: --window-days requires a positive integer" >&2
                exit 1
            fi
            WINDOW_DAYS="$2"; shift 2 ;;
        --json)
            EMIT_JSON=1; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --help|-h)
            grep '^#' "$0" | sed -n '2,32p' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "inventory-agent-sync: unknown option '$1' (try --help)" >&2
            exit 1 ;;
    esac
done

# ── dependency checks ─────────────────────────────────────────────────────────

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "inventory-agent-sync: sqlite3 not found in PATH" >&2
    exit 3
fi

if [[ ! -f "$INVENTORY_DB" ]]; then
    echo "inventory-agent-sync: inventory DB not found at $INVENTORY_DB" >&2
    echo "  Run 'chump inventory rebuild' to populate it first." >&2
    exit 2
fi

# ── helpers ───────────────────────────────────────────────────────────────────

ambient_emit() {
    local kind="$1" payload="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT_LOG")"
    if [[ -n "$payload" ]]; then
        printf '{"ts":"%s","session":"%s","kind":"%s",%s}\n' \
            "$ts" "$SESSION_ID" "$kind" "$payload" >> "$AMBIENT_LOG"
    else
        printf '{"ts":"%s","session":"%s","kind":"%s"}\n' \
            "$ts" "$SESSION_ID" "$kind" >> "$AMBIENT_LOG"
    fi
}

# Escape a string for inclusion in a JSON value (basic).
json_escape() {
    local s="$1"
    # Backslash → \\, double-quote → \", newline → \n
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# ── scan doc targets ──────────────────────────────────────────────────────────

DOC_SCAN_DIRS=(
    "$MAIN_REPO/.claude/agents"
    "$MAIN_REPO/docs/process"
)
DOC_SCAN_FILES=(
    "$MAIN_REPO/AGENTS.md"
    "$MAIN_REPO/CLAUDE.md"
)

# Count total scanned docs (once, for the summary line).
count_scanned_docs() {
    local count=0
    for dir in "${DOC_SCAN_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            local n
            n="$(find "$dir" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')"
            count=$(( count + n ))
        fi
    done
    for f in "${DOC_SCAN_FILES[@]}"; do
        [[ -f "$f" ]] && count=$(( count + 1 ))
    done
    echo "$count"
}

# Returns 1 if the search term appears in any scanned doc, 0 otherwise.
mentioned_in_docs() {
    local term="$1"
    for dir in "${DOC_SCAN_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            if grep -rl --include="*.md" -F "$term" "$dir" 2>/dev/null | head -1 | grep -q .; then
                return 1
            fi
        fi
    done
    for f in "${DOC_SCAN_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            if grep -qF "$term" "$f" 2>/dev/null; then
                return 1
            fi
        fi
    done
    return 0
}

# ── query inventory DB ────────────────────────────────────────────────────────

# Epoch threshold: now minus WINDOW_DAYS * 86400
WINDOW_CUTOFF=$(( $(date +%s) - WINDOW_DAYS * 86400 ))

# Fetch artifacts: path, introducing_pr, introducing_gap, last_modified_at
ARTIFACTS_TMP="$(mktemp)"
trap 'rm -f "$ARTIFACTS_TMP"' EXIT

sqlite3 "$INVENTORY_DB" \
    "SELECT path, introducing_pr, COALESCE(introducing_gap,''), last_modified_at \
     FROM artifact_index \
     WHERE introducing_pr IS NOT NULL \
       AND last_modified_at >= ${WINDOW_CUTOFF} \
     ORDER BY last_modified_at DESC;" \
    2>/dev/null > "$ARTIFACTS_TMP" || {
    echo "inventory-agent-sync: failed to query inventory DB" >&2
    exit 2
}

SCANNED_DOC_COUNT="$(count_scanned_docs)"
FINDINGS=()         # array of JSON objects
UNMENTIONED=0
TOTAL_ARTIFACTS=0

while IFS='|' read -r artifact_path introducing_pr introducing_gap last_modified_at; do
    [[ -z "$artifact_path" ]] && continue
    TOTAL_ARTIFACTS=$(( TOTAL_ARTIFACTS + 1 ))

    # Use the basename as the primary search term (most greppable).
    # Also try the full relative path and the gap ID.
    local_basename="$(basename "$artifact_path")"

    # Check basename in docs.
    found=0
    mentioned_in_docs "$local_basename" || found=1

    # If not found by basename, try the full path (minus leading ./).
    if [[ "$found" -eq 0 ]]; then
        local_path="${artifact_path#./}"
        mentioned_in_docs "$local_path" || found=1
    fi

    # If gap ID is present and not found yet, check it too.
    if [[ "$found" -eq 0 && -n "$introducing_gap" ]]; then
        mentioned_in_docs "$introducing_gap" || found=1
    fi

    if [[ "$found" -eq 0 ]]; then
        UNMENTIONED=$(( UNMENTIONED + 1 ))

        # Build a JSON object for this finding.
        esc_path="$(json_escape "$artifact_path")"
        esc_pr="$(json_escape "$introducing_pr")"
        esc_gap="$(json_escape "$introducing_gap")"
        local_finding="{\"path\":\"$esc_path\",\"introducing_pr\":\"$esc_pr\",\"introducing_gap\":\"$esc_gap\",\"last_modified_at\":$last_modified_at,\"scanned_doc_count\":$SCANNED_DOC_COUNT}"
        FINDINGS+=("$local_finding")
    fi
done < "$ARTIFACTS_TMP"

# ── emit ambient events ────────────────────────────────────────────────────────

if [[ "$DRY_RUN" -eq 0 ]]; then
    for finding in "${FINDINGS[@]}"; do
        # Extract fields for the flat ambient payload.
        path_val="$(echo "$finding" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['path'])" 2>/dev/null || echo "")"
        pr_val="$(echo "$finding" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['introducing_pr'])" 2>/dev/null || echo "")"
        gap_val="$(echo "$finding" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('introducing_gap',''))" 2>/dev/null || echo "")"
        lm_val="$(echo "$finding" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['last_modified_at'])" 2>/dev/null || echo "0")"

        ambient_emit "inventory_agent_sync_finding" \
            "\"path\":\"$(json_escape "$path_val")\",\"introducing_pr\":\"$(json_escape "$pr_val")\",\"introducing_gap\":\"$(json_escape "$gap_val")\",\"last_modified_at\":$lm_val,\"scanned_doc_count\":$SCANNED_DOC_COUNT"
    done

    # Summary event.
    ambient_emit "inventory_agent_sync_run" \
        "\"scanned_doc_count\":$SCANNED_DOC_COUNT,\"window_days\":$WINDOW_DAYS,\"total_artifacts\":$TOTAL_ARTIFACTS,\"unmentioned_count\":$UNMENTIONED"
fi

# ── output ────────────────────────────────────────────────────────────────────

if [[ "$EMIT_JSON" -eq 1 ]]; then
    # Emit a JSON array of findings.
    printf '['
    local_first=1
    for finding in "${FINDINGS[@]}"; do
        [[ "$local_first" -eq 1 ]] && local_first=0 || printf ','
        printf '%s' "$finding"
    done
    printf ']\n'
fi

# Summary line: goes to stderr when --json is active so the JSON array is clean on stdout.
SUMMARY_LINE="agent-sync: scanned $SCANNED_DOC_COUNT docs, found $UNMENTIONED shipped-but-unmentioned artifacts (last ${WINDOW_DAYS}d)"
if [[ "$EMIT_JSON" -eq 1 ]]; then
    echo "$SUMMARY_LINE" >&2
else
    echo "$SUMMARY_LINE"
fi

exit 0
