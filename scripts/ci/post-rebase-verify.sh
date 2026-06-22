#!/usr/bin/env bash
# post-rebase-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop detector. Run immediately after `git rebase` succeeds
# to catch silent content loss from buggy merge drivers (e.g. rust-main-append
# dropping 173 lines from src/main.rs in PR #2216, 2026-05-16).
#
# Algorithm:
#   For each file the branch touches vs base:
#     1. Count lines the original branch added (vs base, at ORIG_HEAD).
#     2. Count lines the rebased branch adds (vs base, at HEAD).
#     3. If original added >= THRESHOLD and rebased adds 0 → silent drop.
#   On drop: print diagnostic, emit kind=rebase_hunk_dropped to ambient.jsonl, exit 1.
#
# Usage:
#   scripts/ci/post-rebase-verify.sh [--base <ref>] [--threshold <N>]
#
# Env overrides:
#   CHUMP_AMBIENT_LOG     path to ambient.jsonl (default: .chump-locks/ambient.jsonl)
#   REBASE_VERIFY_BASE      upstream ref (default: origin/main)
#   REBASE_VERIFY_THRESHOLD min added lines to trigger check (default: 50)
#
# Exit codes:
#   0 — clean or skipped (no drops, or ORIG_HEAD not available)
#   1 — hunk drop detected (ambient event emitted; details on stderr)
#
# Pairs with INFRA-1509 (env-var/kind registration lint at pre-push).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REBASE_VERIFY_REPO_ROOT overrides the repo root for tests; normally derived from script location.
REPO_ROOT="${REBASE_VERIFY_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

BASE="${REBASE_VERIFY_BASE:-origin/main}"
THRESHOLD="${REBASE_VERIFY_THRESHOLD:-50}"
AMBIENT="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)       BASE="$2";      shift 2 ;;
        --threshold)  THRESHOLD="$2"; shift 2 ;;
        *) echo "[post-rebase-verify] unknown arg: $1" >&2; exit 1 ;;
    esac
done

cd "$REPO_ROOT"

# ORIG_HEAD is written by git after a rebase — the pre-rebase branch tip.
ORIG_HEAD_REF=$(git rev-parse ORIG_HEAD 2>/dev/null || true)
if [[ -z "$ORIG_HEAD_REF" ]]; then
    echo "[post-rebase-verify] ORIG_HEAD not set — no rebase in progress, skipping." >&2
    exit 0
fi

REBASED_HEAD=$(git rev-parse HEAD)

# Collect files the original branch modified vs base.
original_files=$(git diff --name-only "$BASE" "$ORIG_HEAD_REF" 2>/dev/null || true)
if [[ -z "$original_files" ]]; then
    exit 0
fi

drops_found=0
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")

while IFS= read -r file; do
    [[ -z "$file" ]] && continue

    # Lines the original branch added for this file (vs base).
    orig_added=$(git diff --numstat "$BASE" "$ORIG_HEAD_REF" -- "$file" 2>/dev/null \
        | awk '{print $1}' || echo "0")
    orig_added="${orig_added:-0}"

    # Only inspect files with significant original additions.
    if [[ "$orig_added" -lt "$THRESHOLD" ]]; then
        continue
    fi

    # Lines the rebased branch adds for this file (vs base).
    rebased_added=$(git diff --numstat "$BASE" "$REBASED_HEAD" -- "$file" 2>/dev/null \
        | awk '{print $1}' || echo "0")
    rebased_added="${rebased_added:-0}"

    # Silent drop: file had substantial additions before; rebased version adds nothing.
    if [[ "$rebased_added" -eq 0 ]]; then
        lines_dropped="$orig_added"
        echo "[post-rebase-verify] HUNK DROP: $file — $lines_dropped lines silently dropped (was +${orig_added}, now +0)" >&2
        drops_found=$((drops_found + 1))

        # Emit ambient event (scanner-anchor: "kind":"rebase_hunk_dropped").
        mkdir -p "$(dirname "$AMBIENT")"
        printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%d,"original_commit":"%s","rebased_commit":"%s"}\n' \
            "$ts" "$file" "$lines_dropped" "$ORIG_HEAD_REF" "$REBASED_HEAD" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
done <<< "$original_files"

if [[ "$drops_found" -gt 0 ]]; then
    echo "[post-rebase-verify] $drops_found file(s) had hunks silently dropped during rebase." >&2
    echo "[post-rebase-verify] Ambient event kind=rebase_hunk_dropped emitted to: $AMBIENT" >&2
    echo "[post-rebase-verify] Recovery: git rebase --abort, then rebase manually with conflict markers." >&2
    exit 1
fi

exit 0
