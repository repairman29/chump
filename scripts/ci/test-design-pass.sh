#!/usr/bin/env bash
# test-design-pass.sh — EFFECTIVE-358 slice (EFFECTIVE-1159)
#
# Placeholder `design-pass` CI stage for user-facing tools (web/**, ChumpMenu/**).
# Convention: a design spec for a changed user-facing file lives at
#   docs/design/specs/<slugified-path>.md
# where <slugified-path> replaces '/' with '-' and strips the extension, e.g.
#   web/v2/foo.html -> docs/design/specs/web-v2-foo.md
#
# Today no producer writes these specs (factory L3 design chair does not
# exist yet — EFFECTIVE-358 is still open), so this stage is intentionally
# non-blocking: it reports which changed files are AWAITING a design spec
# artifact and exits 0. It exits non-zero only on a real regression: a spec
# file that exists but is empty (a stub that was created but never filled
# in), so the stage has a genuine failure path once specs start landing.
#
# Usage:
#   scripts/ci/test-design-pass.sh [--base <git-ref>]
#
# Rust-First-Bypass: one-shot CI glue over git diff + test -s; <200 LOC, no
# state mutation, exploratory per META-064 shell-OK criteria.

set -euo pipefail

BASE_REF="${1:-}"
if [[ "$BASE_REF" == "--base" ]]; then
  BASE_REF="${2:-}"
fi

SPEC_DIR="docs/design/specs"

log() { echo "[design-pass] $*"; }

# Resolve the diff range. In CI this is the PR's merge-base; locally it
# falls back to comparing against HEAD~1 so the script is runnable standalone.
if [[ -n "$BASE_REF" ]]; then
  DIFF_RANGE="${BASE_REF}...HEAD"
elif [[ -n "${GITHUB_BASE_REF:-}" ]]; then
  git fetch --quiet origin "${GITHUB_BASE_REF}" 2>/dev/null || true
  DIFF_RANGE="origin/${GITHUB_BASE_REF}...HEAD"
else
  DIFF_RANGE="HEAD~1...HEAD"
fi

CHANGED_FILES="$(git diff --name-only "$DIFF_RANGE" -- 'web/**' 'ChumpMenu/**' 2>/dev/null || true)"

if [[ -z "$CHANGED_FILES" ]]; then
  log "no user-facing (web/**, ChumpMenu/**) files changed — nothing to review, exiting 0"
  exit 0
fi

log "user-facing files changed in this diff:"
echo "$CHANGED_FILES" | sed 's/^/[design-pass]   - /'

fail=0
awaiting=0

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  slug="$(echo "$f" | sed -E 's#/#-#g; s#\.[a-zA-Z0-9]+$##')"
  spec="${SPEC_DIR}/${slug}.md"
  if [[ ! -f "$spec" ]]; then
    log "AWAITING design spec artifact for '$f' (expected: $spec)"
    awaiting=$((awaiting + 1))
    continue
  fi
  if [[ ! -s "$spec" ]]; then
    log "FAIL: design spec '$spec' exists but is empty (stub never filled in) for '$f'"
    fail=1
    continue
  fi
  log "OK: '$f' has design spec $spec"
done <<< "$CHANGED_FILES"

if [[ "$fail" -ne 0 ]]; then
  log "design-pass: FAILED — one or more design spec stubs are empty"
  exit 1
fi

if [[ "$awaiting" -gt 0 ]]; then
  log "design-pass: $awaiting file(s) awaiting a design spec artifact — non-blocking (factory L3 design chair not yet built, EFFECTIVE-358), reporting success"
fi

log "design-pass: SUCCESS"
exit 0
