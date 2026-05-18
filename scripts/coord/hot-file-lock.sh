#!/usr/bin/env bash
# hot-file-lock.sh — INFRA-953
#
# Acquire flocks for any hot files touched by the current branch's diff,
# so two bot-merges that both touch the same file cannot race and produce
# bot_merge_hot_file rebase rounds.
#
# Usage:
#   scripts/coord/hot-file-lock.sh acquire [--base origin/main] [--timeout 600]
#       Exits 0 once all required locks are held. Each lock is taken on a
#       file descriptor that stays open for the lifetime of the SHELL that
#       called us — release happens automatically when the shell exits.
#       To hold across multiple sub-commands within the same script, source
#       this file instead and call hot_file_lock_acquire (see below).
#
#   scripts/coord/hot-file-lock.sh list [--base origin/main]
#       Print, one per line, the hot files the current diff touches.
#       No locking; for diagnostics.
#
# When sourced (recommended for bot-merge.sh):
#   source scripts/coord/hot-file-lock.sh
#   hot_file_lock_acquire           # populates HOT_FILE_LOCK_FDS for the caller
#   ...                              # do rebase, push, gh pr merge
#   hot_file_lock_release            # explicit release (also fires on shell exit)
#
# Env:
#   CHUMP_HOT_FILES_YAML       config path (default: scripts/coord/hot-files.yaml)
#   CHUMP_HOT_FILE_LOCK_DIR    lock dir (default: .chump-locks)
#   CHUMP_HOT_FILE_LOCK_TIMEOUT_S  per-lock wait timeout (default 600 = 10min)
#   CHUMP_HOT_FILE_LOCK_DISABLE=1  skip acquisition entirely (escape hatch)

set -uo pipefail

_HF_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HF_REPO_ROOT="${REPO_ROOT:-$(cd "$_HF_SCRIPT_DIR/../.." && pwd)}"
HF_YAML="${CHUMP_HOT_FILES_YAML:-$HF_REPO_ROOT/scripts/coord/hot-files.yaml}"
HF_LOCK_DIR="${CHUMP_HOT_FILE_LOCK_DIR:-$HF_REPO_ROOT/.chump-locks}"
HF_TIMEOUT="${CHUMP_HOT_FILE_LOCK_TIMEOUT_S:-600}"
HF_BASE="${CHUMP_HOT_FILE_BASE:-origin/main}"
HF_DISABLED="${CHUMP_HOT_FILE_LOCK_DISABLE:-0}"

# Parsed lazily on first call. macOS bash 3.2 — no associative arrays.
HOT_FILE_LOCK_FDS=()
HOT_FILE_LOCK_FILES=()

_hf_log() { printf '[hot-file-lock] %s\n' "$*" >&2; }

# Print the serialize list (one path per line) from the YAML.
_hf_serialize_list() {
  [[ -r "$HF_YAML" ]] || return 0
  awk '
    /^serialize:/ { in_section=1; next }
    /^[a-zA-Z]/ && !/^serialize:/ { in_section=0 }
    in_section && /^[[:space:]]+- / {
      sub(/^[[:space:]]+- /, "")
      sub(/[[:space:]]+#.*$/, "")
      sub(/[[:space:]]+$/, "")
      if (length($0) > 0) print
    }
  ' "$HF_YAML"
}

# Print the warn_only list (one path per line) from the YAML. Used by
# bot-merge.sh to compose its BOT_MERGE_HOT_FILES warning list.
hot_file_warn_list() {
  [[ -r "$HF_YAML" ]] || return 0
  awk '
    /^warn_only:/ { in_section=1; next }
    /^[a-zA-Z]/ && !/^warn_only:/ { in_section=0 }
    in_section && /^[[:space:]]+- / {
      sub(/^[[:space:]]+- /, "")
      sub(/[[:space:]]+#.*$/, "")
      sub(/[[:space:]]+$/, "")
      if (length($0) > 0) print
    }
  ' "$HF_YAML"
}

# Print the diff-vs-base files (one per line).
_hf_diff_files() {
  git diff "$HF_BASE"...HEAD --name-only 2>/dev/null || true
}

# Sanitize a path into a usable lock-file name.
_hf_sanitize() {
  local p="$1"
  printf '%s' "$p" | tr '/' '_' | tr -c '[:alnum:]._-' '_'
}

# Acquire flocks for any diff files that match the serialize list. Each lock
# is a fresh file descriptor stored in HOT_FILE_LOCK_FDS. "$FLOCK_BIN" holds while
# the FD is open — by the time the caller's shell exits, locks release.
hot_file_lock_acquire() {
  if [[ "$HF_DISABLED" == "1" ]]; then
    _hf_log "CHUMP_HOT_FILE_LOCK_DISABLE=1 — skipping"
    return 0
  fi
  mkdir -p "$HF_LOCK_DIR" 2>/dev/null || true

  local diff_files
  diff_files="$(_hf_diff_files)"
  [[ -z "$diff_files" ]] && return 0

  local serialize_list
  serialize_list="$(_hf_serialize_list)"
  [[ -z "$serialize_list" ]] && return 0

  # Find the intersection.
  local needed=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      if [[ "$f" == "$s" ]]; then
        needed+=("$f")
        break
      fi
    done <<< "$serialize_list"
  done <<< "$diff_files"

  [[ ${#needed[@]} -eq 0 ]] && return 0

  _hf_log "diff touches ${#needed[@]} hot file(s); acquiring locks (timeout=${HF_TIMEOUT}s each)"
  local f sanitized lockfile fd
  for f in "${needed[@]}"; do
    sanitized="$(_hf_sanitize "$f")"
    lockfile="$HF_LOCK_DIR/hot-file-${sanitized}.lock"
    fd=$(( 200 + ${#HOT_FILE_LOCK_FDS[@]} ))
    eval "exec $fd>>\"\$lockfile\""
# INFRA-1600: brew util-linux "$FLOCK_BIN" not on default PATH on self-hosted CI runners.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/discover-flock.sh"

    if ! "$FLOCK_BIN" -w "$HF_TIMEOUT" "$fd"; then
      _hf_log "ERROR: timed out waiting for $lockfile after ${HF_TIMEOUT}s"
      return 1
    fi
    HOT_FILE_LOCK_FDS+=("$fd")
    HOT_FILE_LOCK_FILES+=("$lockfile")
    _hf_log "  acquired $lockfile (fd=$fd)"
  done
  return 0
}

# Explicit release (also happens automatically when the shell exits).
hot_file_lock_release() {
  local i fd
  for ((i = 0; i < ${#HOT_FILE_LOCK_FDS[@]}; i++)); do
    fd="${HOT_FILE_LOCK_FDS[$i]}"
    eval "exec $fd<&-"
  done
  if [[ ${#HOT_FILE_LOCK_FDS[@]} -gt 0 ]]; then
    _hf_log "released ${#HOT_FILE_LOCK_FDS[@]} lock(s)"
  fi
  HOT_FILE_LOCK_FDS=()
  HOT_FILE_LOCK_FILES=()
}

# Direct CLI invocation.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  case "${1:-}" in
    acquire) hot_file_lock_acquire; rc=$?; exit "$rc" ;;
    list)
      diff_files="$(_hf_diff_files)"
      serialize_list="$(_hf_serialize_list)"
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        while IFS= read -r s; do
          [[ "$f" == "$s" ]] && echo "$f"
        done <<< "$serialize_list"
      done <<< "$diff_files" | sort -u
      ;;
    warn-list) hot_file_warn_list ;;
    serialize-list) _hf_serialize_list ;;
    *)
      echo "Usage: $0 {acquire|list|warn-list|serialize-list}" >&2
      exit 1
      ;;
  esac
fi
