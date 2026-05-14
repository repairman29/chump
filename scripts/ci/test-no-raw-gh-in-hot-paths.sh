#!/usr/bin/env bash
# scripts/ci/test-no-raw-gh-in-hot-paths.sh
# INFRA-1274: CI lint gate — no new raw `gh` calls in scripts/coord|dispatch|ops outside lib/
#
# Greps for raw GitHub CLI calls in the hot-path script directories and rejects
# any file NOT listed in scripts/ci/raw-gh-allowlist.txt.
#
# Existing violators that predate the cache-first mandate (INFRA-1081) are
# enumerated in raw-gh-allowlist.txt with their migration gap reference.
# Remove entries from the allowlist as their migration gaps ship.
#
# Exit 0 = no new violations.
# Exit 1 = new raw-gh caller found (pipe error message to stderr).
#
# Usage:
#   bash scripts/ci/test-no-raw-gh-in-hot-paths.sh           # full scan
#   bash scripts/ci/test-no-raw-gh-in-hot-paths.sh --advisory # advisory (always exits 0)
#
# Also callable as pre-commit hook (advisory):
#   bash scripts/ci/test-no-raw-gh-in-hot-paths.sh --advisory

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALLOWLIST="$REPO_ROOT/scripts/ci/raw-gh-allowlist.txt"
ADVISORY=0
if [[ "${1:-}" == "--advisory" ]]; then
  ADVISORY=1
fi

# ── Pattern to detect raw gh calls ────────────────────────────────────────────
# Matches lines that directly invoke the gh CLI for API / PR / search operations.
# Excludes:
#   - lines starting with # (comments)
#   - doc strings / echo / printf showing example commands
#   - chump_gh calls (already wrapped)
#   - CHUMP_GH_ env var references
GH_PATTERN='^\s*(gh api |gh pr (list|view|merge|comment|edit|review)|gh search |gh issue )'

# ── Directories to scan ───────────────────────────────────────────────────────
SCAN_DIRS=(
  "$REPO_ROOT/scripts/coord"
  "$REPO_ROOT/scripts/dispatch"
  "$REPO_ROOT/scripts/ops"
)

# ── Exclusions ────────────────────────────────────────────────────────────────
# - scripts/coord/lib/ — this IS the approved wrapper library
# - test-* files — CI tests themselves may reference gh for fixture setup
EXCLUDE_PATTERNS=(
  "scripts/coord/lib/"
  "/test-"
)

# ── Load allowlist ────────────────────────────────────────────────────────────
load_allowlist() {
  if [[ ! -f "$ALLOWLIST" ]]; then
    echo "[raw-gh-lint] WARN: allowlist not found at $ALLOWLIST — treating as empty" >&2
    return
  fi
  grep -v '^\s*#' "$ALLOWLIST" | grep -v '^\s*$' | awk '{print $1}'
}

ALLOWED_FILES=()
while IFS= read -r line; do
  ALLOWED_FILES+=("$line")
done < <(load_allowlist)

is_allowed() {
  local rel="$1"
  for allowed in "${ALLOWED_FILES[@]:-}"; do
    if [[ "$rel" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

is_excluded() {
  local path="$1"
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    if [[ "$path" == *"$pat"* ]]; then
      return 0
    fi
  done
  return 1
}

# ── Scan ──────────────────────────────────────────────────────────────────────
VIOLATIONS=0
VIOLATION_LINES=()

for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' file; do
    is_excluded "$file" && continue

    # Get relative path from repo root.
    rel="${file#$REPO_ROOT/}"

    # Check if file has raw gh calls.
    if grep -qEe "$GH_PATTERN" "$file" 2>/dev/null; then
      # Check against allowlist.
      if ! is_allowed "$rel"; then
        VIOLATIONS=$((VIOLATIONS + 1))
        while IFS= read -r match; do
          VIOLATION_LINES+=("$rel: $match")
        done < <(grep -nEe "$GH_PATTERN" "$file" 2>/dev/null)
      fi
    fi
  done < <(find "$dir" -name "*.sh" -print0)
done

# ── Report ────────────────────────────────────────────────────────────────────
if [[ $VIOLATIONS -gt 0 ]]; then
  echo "[raw-gh-lint] FAIL: $VIOLATIONS new raw-gh caller(s) found in hot paths" >&2
  echo "" >&2
  echo "  These scripts call 'gh api'/'gh pr ...'/'gh search' directly rather than" >&2
  echo "  using the cache-first wrapper in scripts/coord/lib/github_cache.sh." >&2
  echo "" >&2
  echo "  Matching lines:" >&2
  for v in "${VIOLATION_LINES[@]}"; do
    echo "    $v" >&2
  done
  echo "" >&2
  echo "  Fix: use cache_lookup_pr / cache_lookup_checks / chump_gh from" >&2
  echo "  scripts/coord/lib/github_cache.sh instead of raw 'gh' calls." >&2
  echo "  See CLAUDE.md §Cache-first reads (INFRA-1081)." >&2
  echo "" >&2
  echo "  If this script pre-dates the mandate (INFRA-1081, 2026-05-14) and has" >&2
  echo "  an open migration gap, add it to scripts/ci/raw-gh-allowlist.txt with" >&2
  echo "  a comment referencing the gap ID." >&2

  if [[ $ADVISORY -eq 1 ]]; then
    echo "[raw-gh-lint] Advisory mode — not blocking." >&2
    exit 0
  fi
  exit 1
else
  echo "[raw-gh-lint] PASS: no new raw-gh callers in hot paths (${#ALLOWED_FILES[@]} allowlisted)"
  exit 0
fi
