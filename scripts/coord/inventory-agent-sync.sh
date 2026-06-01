#!/usr/bin/env bash
# INFRA-2366: agent-awareness sync — flag shipped artifacts that no agent
# doc currently mentions. Quartermaster-class finding: "you shipped X, but
# nobody downstream knows it exists."
#
# Algorithm:
#   1. Scan agent-context corpus: .claude/agents/*.md + docs/process/*.md +
#      AGENTS.md + CLAUDE.md (configurable via CHUMP_INVENTORY_AGENT_DOCS).
#   2. Query .chump/inventory.db for artifact_index rows where
#      introducing_pr IS NOT NULL AND last_modified_at within window-days
#      (default 30; configurable via --window-days N).
#   3. For each artifact, grep the agent-doc corpus for path or basename.
#      If zero hits, surface it as an inventory_agent_sync_finding event
#      to .chump-locks/ambient.jsonl.
#   4. Report tally: scanned N docs, M shipped-but-unmentioned (last <window>d).
#
# Exit codes: 0 always (advisory, not gate). Errors written to stderr.
#
# Usage:
#   scripts/coord/inventory-agent-sync.sh                    # default 30d
#   scripts/coord/inventory-agent-sync.sh --window-days 7    # last 7d
#   scripts/coord/inventory-agent-sync.sh --dry-run          # no ambient emit
#   scripts/coord/inventory-agent-sync.sh --json             # machine-readable

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INVENTORY_DB="${CHUMP_INVENTORY_DB:-$REPO_ROOT/.chump/inventory.db}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

window_days=30
dry_run=0
emit_json=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-days)
            window_days="${2:-30}"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --json)
            emit_json=1
            shift
            ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *)
            echo "[inventory-agent-sync] unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

if [[ ! -f "$INVENTORY_DB" ]]; then
    echo "[inventory-agent-sync] inventory DB not found: $INVENTORY_DB" >&2
    echo "[inventory-agent-sync] run 'chump inventory rebuild' first" >&2
    exit 0
fi

# Build the agent-doc corpus list (mapfile not always available on macOS
# bash 3.2; use array-from-while-read for portability).
agent_docs=()
while IFS= read -r line; do
    [[ -n "$line" ]] && agent_docs+=("$line")
done < <(
    find "$REPO_ROOT/.claude/agents" -maxdepth 2 -name '*.md' 2>/dev/null
    find "$REPO_ROOT/docs/process" -maxdepth 2 -name '*.md' 2>/dev/null
    [[ -f "$REPO_ROOT/AGENTS.md" ]] && echo "$REPO_ROOT/AGENTS.md"
    [[ -f "$REPO_ROOT/CLAUDE.md" ]] && echo "$REPO_ROOT/CLAUDE.md"
)
scanned_doc_count=${#agent_docs[@]}

if [[ "$scanned_doc_count" == "0" ]]; then
    echo "[inventory-agent-sync] no agent docs found under .claude/agents/, docs/process/, AGENTS.md, CLAUDE.md" >&2
    exit 0
fi

# Window cutoff in unix seconds.
cutoff_ts=$(($(date -u +%s) - window_days * 86400))

# Pull candidate artifacts shipped within window.
candidates=$(sqlite3 -separator $'\t' "$INVENTORY_DB" \
    "SELECT path, introducing_pr, COALESCE(introducing_gap, ''), last_modified_at
     FROM artifact_index
     WHERE introducing_pr IS NOT NULL
       AND last_modified_at >= $cutoff_ts
     ORDER BY last_modified_at DESC")

if [[ -z "$candidates" ]]; then
    if [[ "$emit_json" == "1" ]]; then
        echo "{\"scanned_doc_count\":$scanned_doc_count,\"findings\":[],\"window_days\":$window_days}"
    else
        echo "agent-sync: scanned $scanned_doc_count docs, found 0 shipped-but-unmentioned artifacts (last ${window_days}d)"
    fi
    exit 0
fi

findings_json="["
findings_count=0
first=1

while IFS=$'\t' read -r path intro_pr intro_gap lmt; do
    [[ -z "$path" ]] && continue
    basename="${path##*/}"
    stem="${basename%.*}"

    # Search the agent-doc corpus for path or basename. Cheap fixed-string grep.
    if grep -lF "$path" "${agent_docs[@]}" >/dev/null 2>&1; then
        continue
    fi
    if grep -lF "$basename" "${agent_docs[@]}" >/dev/null 2>&1; then
        continue
    fi
    # Stem-only match (e.g. "trunk-sentinel" without .sh).
    if [[ "$stem" != "$basename" ]] && grep -lF "$stem" "${agent_docs[@]}" >/dev/null 2>&1; then
        continue
    fi

    findings_count=$((findings_count + 1))

    # Build JSON entry.
    [[ $first -eq 1 ]] && first=0 || findings_json="${findings_json},"
    findings_json="${findings_json}{\"path\":\"$path\",\"introducing_pr\":$intro_pr,\"introducing_gap\":\"$intro_gap\",\"last_modified_at\":$lmt,\"scanned_doc_count\":$scanned_doc_count}"

    # Emit ambient event (unless --dry-run).
    if [[ "$dry_run" == "0" ]]; then
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        evt="{\"ts\":\"$ts\",\"kind\":\"inventory_agent_sync_finding\",\"path\":\"$path\",\"introducing_pr\":$intro_pr,\"introducing_gap\":\"$intro_gap\",\"last_modified_at\":$lmt,\"scanned_doc_count\":$scanned_doc_count}"
        mkdir -p "$(dirname "$AMBIENT_LOG")"
        printf '%s\n' "$evt" >> "$AMBIENT_LOG"
    fi
done <<< "$candidates"

findings_json="${findings_json}]"

if [[ "$emit_json" == "1" ]]; then
    echo "{\"scanned_doc_count\":$scanned_doc_count,\"window_days\":$window_days,\"findings_count\":$findings_count,\"findings\":$findings_json}"
else
    echo "agent-sync: scanned $scanned_doc_count docs, found $findings_count shipped-but-unmentioned artifacts (last ${window_days}d)"
    if [[ "$dry_run" == "1" ]]; then
        echo "agent-sync: --dry-run; no ambient events emitted"
    elif [[ "$findings_count" -gt 0 ]]; then
        echo "agent-sync: emitted $findings_count kind=inventory_agent_sync_finding to $AMBIENT_LOG"
    fi
fi
exit 0
