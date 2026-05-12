#!/usr/bin/env bash
# INFRA-399: Archive subagent output transcripts from Claude Code's ephemeral tmp storage.
#
# Claude Code stores agent task outputs at:
#   /private/tmp/claude-501/<project-slug>/<session-uuid>/tasks/<agent-id>.output
# Those files disappear on reboot or tmp cleanup. This script copies them to:
#   ~/.claude/projects/<project-slug>/notes/subagent-archive/<agent-id>.jsonl
# so post-mortem analysis is available after the tmp dir is cleared.
#
# Usage:
#   archive-subagent-transcripts.sh [--project-slug SLUG] [--since-secs N] [--dry-run]
#
# Options:
#   --project-slug SLUG   Project slug (default: derived from CHUMP_HOME or pwd)
#   --since-secs N        Only archive files modified in the last N seconds (default: 3600)
#   --dry-run             Print what would be archived without writing anything
#
# Retention: files in the archive older than SUBAGENT_ARCHIVE_COMPRESS_DAYS (default 30)
# are compressed with gzip. Files older than SUBAGENT_ARCHIVE_DELETE_DAYS (default 90)
# are deleted.
set -euo pipefail

SINCE_SECS="${SINCE_SECS:-3600}"
DRY_RUN=0
PROJECT_SLUG=""
TMP_OVERRIDE=""  # for testing: override /private/tmp/claude-501 base

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-slug) PROJECT_SLUG="$2"; shift 2 ;;
    --since-secs)   SINCE_SECS="$2";   shift 2 ;;
    --tmp-base)     TMP_OVERRIDE="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1;          shift   ;;
    *) echo "archive-subagent-transcripts.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Derive project slug from CHUMP_HOME or cwd: convert absolute path to
# the same slug Claude Code uses (replace / with - and strip leading -)
if [[ -z "$PROJECT_SLUG" ]]; then
  _home="${CHUMP_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  PROJECT_SLUG="$(echo "$_home" | sed 's|/|-|g' | sed 's/^-//')"
fi

_claude_tmp_root="${TMP_OVERRIDE:-/private/tmp/claude-501}"
TMP_BASE="${_claude_tmp_root}/${PROJECT_SLUG}"
ARCHIVE_BASE="${HOME}/.claude/projects/${PROJECT_SLUG}/notes/subagent-archive"
COMPRESS_DAYS="${SUBAGENT_ARCHIVE_COMPRESS_DAYS:-30}"
DELETE_DAYS="${SUBAGENT_ARCHIVE_DELETE_DAYS:-90}"

if [[ ! -d "$TMP_BASE" ]]; then
  echo "archive-subagent-transcripts.sh: tmp dir not found: $TMP_BASE" >&2
  exit 0
fi

[[ "$DRY_RUN" -eq 0 ]] && mkdir -p "$ARCHIVE_BASE"

archived=0
skipped=0

# Find .output files modified in last SINCE_SECS seconds
while IFS= read -r -d '' output_file; do
  agent_id="$(basename "$output_file" .output)"
  dest="${ARCHIVE_BASE}/${agent_id}.jsonl"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would archive: $output_file → $dest"
    (( archived++ )) || true
    continue
  fi

  # Skip if already archived and dest is newer than source
  if [[ -f "$dest" ]] && [[ "$dest" -nt "$output_file" ]]; then
    (( skipped++ )) || true
    continue
  fi

  cp "$output_file" "$dest"
  (( archived++ )) || true
done < <(find "$TMP_BASE" -path "*/tasks/*.output" -newer /dev/null \
  -mmin "-$(( SINCE_SECS / 60 + 1 ))" -print0 2>/dev/null)

# Retention: compress files older than COMPRESS_DAYS
if [[ "$DRY_RUN" -eq 0 ]] && [[ -d "$ARCHIVE_BASE" ]]; then
  find "$ARCHIVE_BASE" -name "*.jsonl" -mtime "+${COMPRESS_DAYS}" \
    -exec gzip -f {} \; 2>/dev/null || true

  # Delete compressed files older than DELETE_DAYS
  find "$ARCHIVE_BASE" -name "*.jsonl.gz" -mtime "+${DELETE_DAYS}" \
    -delete 2>/dev/null || true
fi

if [[ "$archived" -gt 0 ]] || [[ "$skipped" -gt 0 ]]; then
  echo "archive-subagent-transcripts.sh: archived=$archived skipped=$skipped dest=$ARCHIVE_BASE"
fi
