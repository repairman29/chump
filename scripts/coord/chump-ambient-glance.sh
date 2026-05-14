#!/usr/bin/env bash
#
# chump-ambient-glance.sh — scan .chump-locks/ambient.jsonl for overlap signals.
#
# Checks the last N seconds of ambient.jsonl for INTENT events or open PRs
# matching the given domain and title. Returns 0 (no overlap) or 1 (overlap found).
#
# Usage:
#   scripts/coord/chump-ambient-glance.sh [--domain D] [--title T] [--window-secs S] [--check-prs]
#
# --domain D      Domain to search (e.g. INFRA, FLEET, EVAL); glances for INTENT events
# --title T       Title substring to search for; glances ambient and gh pr list
# --window-secs S Seconds of ambient.jsonl history to inspect (default: 300)
# --check-prs     Also scan gh pr list (requires gh auth); otherwise ambient-only
#
# Exit codes:
#   0 = no overlap found
#   1 = overlap found or error
#
# Output format:
#   Prints [WARN] lines to stderr describing the overlap.
#   Matches are printed in order: ambient events first, then PRs.

set -euo pipefail

DOMAIN=""
TITLE=""
WINDOW_SECS=300
CHECK_PRS=0
REPO_ROOT="${CHUMP_REPO_ROOT:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --title)
      TITLE="$2"
      shift 2
      ;;
    --window-secs)
      WINDOW_SECS="$2"
      shift 2
      ;;
    --check-prs)
      CHECK_PRS=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

AMBIENT_FILE="${REPO_ROOT}/.chump-locks/ambient.jsonl"
FOUND_OVERLAP=0

# ── Step 1: Check ambient.jsonl for INTENT/OBSERVED events in the window ──
if [[ -f "${AMBIENT_FILE}" ]]; then
  NOW_TS=$(date +%s)
  CUTOFF_TS=$((NOW_TS - WINDOW_SECS))

  # Tail the ambient file and look for recent events matching our domain or title
  if [[ -n "${DOMAIN}" ]]; then
    # Look for INTENT events with this domain or title mentions
    if tail -500 "${AMBIENT_FILE}" | jq -r \
      "select(.timestamp // 0 > ${CUTOFF_TS}) |
       select(.kind == \"intent\" or (.notes // \"\" | contains(\"INTENT\"))) |
       select((.domain // \"\" | contains(\"${DOMAIN}\")) or (.title // \"\" | contains(\"${TITLE}\"))) |
       \"[WARN] Ambient overlap: \\(.kind // \"unknown\") by \\(.session_id // \"unknown\") — domain=\\(.domain // \"N/A\") title=\\(.title // \"N/A\")\"" \
      2>/dev/null | grep -q . ; then
      FOUND_OVERLAP=1
      tail -500 "${AMBIENT_FILE}" | jq -r \
        "select(.timestamp // 0 > ${CUTOFF_TS}) |
         select(.kind == \"intent\" or (.notes // \"\" | contains(\"INTENT\"))) |
         select((.domain // \"\" | contains(\"${DOMAIN}\")) or (.title // \"\" | contains(\"${TITLE}\"))) |
         \"[WARN] Ambient overlap: \\(.kind // \"unknown\") by \\(.session_id // \"unknown\") — domain=\\(.domain // \"N/A\") title=\\(.title // \"N/A\")\"" \
        2>/dev/null >&2 || true
    fi
  fi

  # Always check for title substring matches in ambient
  if [[ -n "${TITLE}" ]]; then
    if tail -500 "${AMBIENT_FILE}" | jq -r \
      "select(.timestamp // 0 > ${CUTOFF_TS}) |
       select(.kind == \"intent\" or .kind == \"observed\") |
       select(.title // \"\" | contains(\"${TITLE}\")) |
       \"[WARN] Ambient title match: \\(.kind // \"unknown\") — \\(.title // \"N/A\")\"" \
      2>/dev/null | grep -q . ; then
      FOUND_OVERLAP=1
      tail -500 "${AMBIENT_FILE}" | jq -r \
        "select(.timestamp // 0 > ${CUTOFF_TS}) |
         select(.kind == \"intent\" or .kind == \"observed\") |
         select(.title // \"\" | contains(\"${TITLE}\")) |
         \"[WARN] Ambient title match: \\(.kind // \"unknown\") — \\(.title // \"N/A\")\"" \
        2>/dev/null >&2 || true
    fi
  fi
fi

# ── Step 2: INFRA-1108 — cache-first scan for overlapping open PRs ──
# Prefer reading pr_state from .chump/github_cache.db (populated by webhooks
# INFRA-1081). Falls back to gh pr list when cache is empty.
if [[ "${CHECK_PRS}" == "1" ]]; then
  MATCHES=""
  # Cache-first path
  CACHE_LIB="$(dirname "$0")/lib/github_cache.sh"
  CACHE_DB="${CHUMP_CACHE_DB:-$(git rev-parse --show-toplevel 2>/dev/null)/.chump/github_cache.db}"
  if [[ -f "$CACHE_LIB" && -f "$CACHE_DB" && -n "${TITLE}" ]]; then
    # SQL LIKE with case-sensitive substring match (matches contains() semantics).
    MATCHES=$(sqlite3 -separator ' ' "$CACHE_DB" \
      "SELECT number, title FROM pr_state \
       WHERE merged_at IS NULL AND title LIKE '%${TITLE//\'/}%' \
       ORDER BY number" 2>/dev/null || true)
    if [[ -n "$MATCHES" ]]; then
      printf '[INFO] FLEET-029 cache hit: read overlap candidates from .chump/github_cache.db (INFRA-1108)\n' >&2
    fi
  fi
  # Fallback to gh pr list when cache empty (cold start) or returned nothing.
  if [[ -z "$MATCHES" ]] && command -v gh &>/dev/null && [[ -n "${TITLE}" ]]; then
    MATCHES=$(gh pr list --state open --limit 50 --json number,title --jq \
      ".[] | select(.title | contains(\"${TITLE}\")) | \"\(.number) \(.title)\"" 2>/dev/null || echo "")
    [[ -n "$MATCHES" ]] && printf '[INFO] FLEET-029 fallback: queried gh pr list (cache empty)\n' >&2
  fi
  if [[ -n "${MATCHES}" ]]; then
    FOUND_OVERLAP=1
    while read -r line; do
      echo "[WARN] Open PR overlap: #${line}" >&2
    done <<< "${MATCHES}"
  fi
fi

exit "${FOUND_OVERLAP}"
