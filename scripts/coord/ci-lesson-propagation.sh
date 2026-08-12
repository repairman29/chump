#!/usr/bin/env bash
# scripts/coord/ci-lesson-propagation.sh — INFRA-1765
#
# Turns failing CI checks on a PR into structured lessons in memory_db, via
# `chump ci-lesson capture` (src/ci_lesson.rs). Those lessons are then
# auto-surfaced in the *next* session's briefing for the same domain
# (src/briefing.rs merges `reflection_db::load_ci_lessons` into
# relevant_reflections) — no separate injection step needed.
#
# Usage:
#   scripts/coord/ci-lesson-propagation.sh <PR-number> [--domain <domain>]
#
# Reads cache-first per CLAUDE.md "Cache-first reads" doctrine: looks up the
# PR's head SHA + failing checks via .chump/github_cache.db, falls through
# cleanly (prints nothing, exits 0) on cache miss rather than polling `gh`.
#
# Events (see src/ci_lesson.rs top-of-file doc for the full contract):
#   ci_lesson_captured        — emitted by the Rust binary on success
#   ci_lesson_capture_failed  — emitted by the Rust binary on a DB error
#   ci_lesson_capture_timeout — emitted HERE when `timeout` kills the binary
#                                (the binary itself never blocks that long;
#                                this catches process-level wedges: OOM,
#                                disk-full flushing WAL, etc.)
#
# Smoke test: scripts/ci/test-ci-lesson-propagation.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/github_cache.sh
source "$(dirname "$0")/lib/github_cache.sh"

PR_NUMBER="${1:?Usage: ci-lesson-propagation.sh <PR-number> [--domain <domain>]}"
shift || true
DOMAIN="infra"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        *) shift ;;
    esac
done

CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
CAPTURE_TIMEOUT_SECS="${CI_LESSON_CAPTURE_TIMEOUT_SECS:-10}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

pr_json="$(cache_lookup_pr "$PR_NUMBER" || true)"
head_sha="$(printf '%s' "$pr_json" | jq -r '.head.sha // empty' 2>/dev/null || true)"
if [[ -z "$head_sha" ]]; then
    echo "ci-lesson-propagation: no cached head_sha for PR #$PR_NUMBER (cache miss) — nothing to do" >&2
    exit 0
fi

captured=0
failed=0
while IFS=$'\t' read -r name status conclusion; do
    [[ -z "$name" ]] && continue
    [[ "$conclusion" == "failure" || "$conclusion" == "timed_out" ]] || continue

    log_text="failed check '$name' (status=$status conclusion=$conclusion) on PR #$PR_NUMBER"
    if timeout "$CAPTURE_TIMEOUT_SECS" "$CHUMP_BIN" ci-lesson capture \
        --check "$name" --pr-ref "PR#$PR_NUMBER" --domain "$DOMAIN" \
        --failure-text "$log_text"; then
        captured=$((captured + 1))
    else
        rc=$?
        if [[ $rc -eq 124 ]]; then
            printf '{"ts":"%s","kind":"ci_lesson_capture_timeout","check":"%s","pr_ref":"PR#%s","timeout_secs":%s,"cost_usd":0.0}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$PR_NUMBER" "$CAPTURE_TIMEOUT_SECS" >> "$AMBIENT" 2>/dev/null || true
        fi
        failed=$((failed + 1))
    fi
done < <(cache_lookup_checks "$head_sha")

echo "ci-lesson-propagation: PR #$PR_NUMBER — captured=$captured failed=$failed"
