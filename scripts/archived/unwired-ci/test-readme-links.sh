#!/usr/bin/env bash
# scripts/ci/test-readme-links.sh — DOC-049
#
# Validates that every relative-path doc link in README.md exists on disk.
# Skips http(s)://, mailto:, and anchors-only (#section). Run on every
# README commit via path filter in .github/workflows/ci.yml.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$REPO_ROOT/README.md" ] || fail "README.md missing"

broken_count=0
total_count=0
while IFS= read -r link; do
  # Strip the [...]( wrapper
  raw="${link#*\(}"
  raw="${raw%\)*}"
  # Skip absolute URLs, mailto:, and pure anchors
  case "$raw" in
    http://*|https://*|mailto:*|\#*) continue ;;
  esac
  # Strip query string + anchor
  path="${raw%%\#*}"
  path="${path%%\?*}"
  [ -z "$path" ] && continue
  total_count=$((total_count + 1))
  if [ ! -e "$REPO_ROOT/$path" ]; then
    echo "  ✗ MISSING: $path"
    broken_count=$((broken_count + 1))
  fi
done < <(grep -oE '\[[^]]*\]\([^)]+\)' "$REPO_ROOT/README.md")

if [ "$broken_count" -gt 0 ]; then
  fail "$broken_count broken README link(s) of $total_count total"
fi
ok "all $total_count README links resolve on disk"

echo
echo "DOC-049 README link validation passed."
