#!/usr/bin/env bash
# growth-worker.sh — EFFECTIVE-356
#
# Factory L7 (growth) chair: closes shipped -> told. Read-only over
# git/state.db/ambient.jsonl; no new state stores. Reuses the shipped-gap
# record in state.db (same source kpi_report/gap-audit read) instead of
# polling `gh` for merge history.
#
# SLICE 1 (M3 clarification, Jeff 2026-08-05): draft release notes from the
# merge log, draft a preview-mode announcement from those notes, and flag
# docs pages that cite a gap as pending when it has actually shipped. Every
# output is a DRAFT written under docs/releases/ — nothing here posts
# anywhere. Publish stays human (org/RUN/publication/roles/publisher.md).
#
# Usage:
#   growth-worker.sh release-notes [--days N] [--out PATH]
#   growth-worker.sh stale-docs    [--days N] [--out PATH]
#   growth-worker.sh announcement  [--notes PATH] [--out PATH]
#   growth-worker.sh run           [--days N]   # all three, in order
#
# Exit 0 on success (announcement/release-notes) even with zero shipped
# gaps in window — an empty window is not a failure. stale-docs exits 0
# with a report either way (findings are advisory, not a gate).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

STATE_DB="${CHUMP_STATE_DB:-.chump/state.db}"
OUT_DIR="${CHUMP_GROWTH_OUT_DIR:-docs/releases}"

portable_since_date() {
  local days="$1"
  if date -v-1d +%Y-%m-%d >/dev/null 2>&1; then
    date -v-"${days}"d +%Y-%m-%d # macOS/BSD
  else
    date -u -d "${days} days ago" +%Y-%m-%d # GNU
  fi
}

today() { date -u +%Y-%m-%d; }

# House style for the release-note artifact type (scripts/ci/test-release-note-voice-lint.sh)
# bans em dashes. Gap titles carry the repo's own em-dash convention, so
# every generated file is passed through this filter at write time rather
# than trusting each caller to remember.
house_style() { sed -E 's/ *— */ - /g'; }

usage() {
  cat >&2 <<'EOF'
Usage: growth-worker.sh <release-notes|stale-docs|announcement|run> [options]
EOF
  exit 1
}

# ---- release-notes ---------------------------------------------------

cmd_release_notes() {
  local days=7 out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
  done
  local since; since="$(portable_since_date "$days")"
  local date_stamp; date_stamp="$(today)"
  out="${out:-$OUT_DIR/growth-${date_stamp}-release-notes.md}"

  local rows
  rows="$(sqlite3 -separator $'\t' "$STATE_DB" \
    "select id, domain, title, closed_pr from gaps
     where status in ('shipped','done') and closed_date >= '${since}'
     order by domain, closed_date;" 2>/dev/null || true)"

  {
    echo "# chump growth digest — ${date_stamp}"
    echo
    echo "## What shipped since ${since}"
    echo
    if [[ -z "$rows" ]]; then
      echo "No gaps closed in this window."
    else
      local prev_domain=""
      while IFS=$'\t' read -r id domain title pr; do
        [[ -z "$id" ]] && continue
        if [[ "$domain" != "$prev_domain" ]]; then
          echo
          echo "### ${domain}"
          echo
          prev_domain="$domain"
        fi
        local pr_ref=""
        [[ -n "$pr" && "$pr" != "" ]] && pr_ref=" (#${pr})"
        echo "- **${id}**${pr_ref} — ${title}"
      done <<< "$rows"
    fi
    echo
    echo "## Receipts"
    echo
    echo "Generated from ${STATE_DB} \`status in (shipped, done)\` and \`closed_date >= ${since}\`."
    echo "No claim in this file is unlinked from a gap ID above."
  } | house_style > "$out"

  echo "$out"
}

# ---- stale-docs -------------------------------------------------------

cmd_stale_docs() {
  local days=30 out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
  done
  local since; since="$(portable_since_date "$days")"
  local date_stamp; date_stamp="$(today)"
  out="${out:-$OUT_DIR/growth-${date_stamp}-stale-docs-report.md}"

  # Gap IDs closed in the window — these are the ones docs might still
  # describe as pending/open/TODO.
  local shipped_ids
  shipped_ids="$(sqlite3 "$STATE_DB" \
    "select id from gaps where status in ('shipped','done') and closed_date >= '${since}';" \
    2>/dev/null || true)"

  local findings=""
  if [[ -n "$shipped_ids" ]]; then
    while IFS= read -r gid; do
      [[ -z "$gid" ]] && continue
      # Look for the gap ID appearing near forward-looking language in
      # tracked docs — grep -B2/-A2 window, case-insensitive marker set.
      local hits
      hits="$(grep -rnEI "$gid" docs/ 2>/dev/null | grep -iE 'pending|not yet|todo|will (ship|land|add)|planned|coming soon|unimplemented' || true)"
      if [[ -n "$hits" ]]; then
        while IFS= read -r hit; do
          [[ -z "$hit" ]] && continue
          findings+="- ${gid} shipped $(sqlite3 "$STATE_DB" "select closed_date from gaps where id='${gid}';" 2>/dev/null) — but still marked pending: ${hit}"$'\n'
        done <<< "$hits"
      fi
    done <<< "$shipped_ids"
  fi

  {
    echo "# stale-doc report — ${date_stamp}"
    echo
    echo "Gaps shipped since ${since} that a tracked doc still describes as pending."
    echo
    if [[ -z "$findings" ]]; then
      echo "No stale references found."
    else
      printf '%s' "$findings"
    fi
  } | house_style > "$out"

  echo "$out"
}

# ---- announcement -------------------------------------------------------

cmd_announcement() {
  local notes="" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --notes) notes="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
  done
  local date_stamp; date_stamp="$(today)"
  notes="${notes:-$OUT_DIR/growth-${date_stamp}-release-notes.md}"
  out="${out:-$OUT_DIR/growth-${date_stamp}-announcement.md}"

  if [[ ! -f "$notes" ]]; then
    echo "growth-worker: no release notes at $notes — run 'release-notes' first" >&2
    exit 1
  fi

  # Pull the bullet lines (the "- **ID** ... — title" rows) straight out
  # of the release notes; the announcement is a shorter, human-facing
  # summary of the same receipts, not new claims.
  local bullets
  bullets="$(grep -E '^- \*\*[A-Z]+-[0-9]+\*\*' "$notes" || true)"
  local count
  count="$(printf '%s\n' "$bullets" | grep -c . || true)"

  {
    echo "# [DRAFT — PREVIEW ONLY, not for publish] chump shipped this week — ${date_stamp}"
    echo
    echo "Status: awaiting captain approve-and-post (org/RUN/publication/roles/publisher.md)."
    echo
    if [[ "$count" -eq 0 ]]; then
      echo "Quiet week — nothing closed in the source window."
    else
      echo "${count} change(s) shipped this week:"
      echo
      printf '%s\n' "$bullets"
    fi
    echo
    echo "Full receipts: ${notes}"
  } | house_style > "$out"

  echo "$out"
}

# ---- run ----------------------------------------------------------------

cmd_run() {
  local days=7
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="$2"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
  done
  mkdir -p "$OUT_DIR"
  local notes_path stale_path ann_path
  notes_path="$(cmd_release_notes --days "$days")"
  stale_path="$(cmd_stale_docs --days "$days")"
  ann_path="$(cmd_announcement --notes "$notes_path")"
  echo "release-notes:  $notes_path"
  echo "stale-docs:     $stale_path"
  echo "announcement:   $ann_path"
}

[[ $# -ge 1 ]] || usage
sub="$1"; shift
mkdir -p "$OUT_DIR"
case "$sub" in
  release-notes) cmd_release_notes "$@" ;;
  stale-docs) cmd_stale_docs "$@" ;;
  announcement) cmd_announcement "$@" ;;
  run) cmd_run "$@" ;;
  *) usage ;;
esac
