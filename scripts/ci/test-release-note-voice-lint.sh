#!/usr/bin/env bash
# test-release-note-voice-lint.sh — EFFECTIVE-363
#
# Quality gate for the `release-note` artifact_type: the first non-code type
# proving the per-type gate registry (crates/chump-preflight/src/artifact_gates.rs)
# end to end. Checks release-note prose against two voice rules:
#
#   1. No em dashes (—). Ban-listed the same way test-voice-banlist.sh bans
#      marketing hype words, for the same reason: it reads as house style,
#      not a claim.
#   2. Receipts, not adjectives: a banned list of unsupported superlative/
#      hype adjectives that release notes lean on instead of citing the
#      actual change (gap ID, PR number, metric).
#
# Usage:
#   test-release-note-voice-lint.sh <file> [<file> ...]
#   test-release-note-voice-lint.sh                # defaults to git-diff
#                                                    # docs/releases/*.md
#
# Exit 0 — clean. Exit 1 — violation(s) found (printed to stderr).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

BANNED_ADJECTIVES=(
  "amazing"
  "incredible"
  "game-changing"
  "revolutionary"
  "seamless"
  "robust"
  "cutting-edge"
  "best-in-class"
)

FILES=("$@")
if [[ ${#FILES[@]} -eq 0 ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && FILES+=("$f")
  done < <(git diff --name-only origin/main...HEAD -- 'docs/releases/*.md' 2>/dev/null || true)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "[release-note-voice-lint] no release-note files to check — pass"
  exit 0
fi

fail=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue

  if grep -nP '\x{2014}' "$f" >/dev/null 2>&1; then
    echo "[release-note-voice-lint] FAIL: $f contains an em dash (—) — house style is plain punctuation" >&2
    grep -nP '\x{2014}' "$f" >&2 || true
    fail=1
  fi

  for word in "${BANNED_ADJECTIVES[@]}"; do
    if grep -niE "\\b${word}\\b" "$f" >/dev/null 2>&1; then
      echo "[release-note-voice-lint] FAIL: $f uses banned adjective '${word}' — cite the receipt (gap ID / PR / metric) instead" >&2
      fail=1
    fi
  done
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "[release-note-voice-lint] ${#FILES[@]} file(s) clean"
exit 0
