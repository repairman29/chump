#!/usr/bin/env bash
# bypass-var-cull-audit.sh — INFRA-3625: the RECURRING half of the bypass-var
# debt ceiling (EFFECTIVE-094).
#
# WHY: scripts/ci/test-no-new-bypass-env-vars.sh enforces the ceiling in
# scripts/ci/bypass-var-ceiling.txt on every PR (fails if count > ceiling),
# but nothing ever pushed the ceiling back DOWN except a human noticing.
# Result (2026-08-15): main sat pinned exactly AT the ceiling with zero
# headroom, so every PR that introduced even one new CHUMP_*_BYPASS/SKIP/
# IGNORE var tripped audit-shard(4) — hit repeatedly across PRs #3775/#3785/
# #3792 in a single day. A one-off cull restores headroom once; only a
# RECURRING organ keeps it restored.
#
# WHAT THIS DOES (read-only; never edits the ceiling or deletes vars itself —
# a human/gap makes that call, this organ just surfaces the opportunity):
#   1. Recomputes the live count the same way the CI gate does.
#   2. Reports headroom = ceiling - count.
#   3. Lists "candidate" vars: distinct bypass-shaped names that appear in
#      exactly ONE file across scripts/src/crates and are never referenced
#      via env::var("NAME") or a shell $NAME / ${NAME} dereference anywhere
#      in the repo — i.e. they look like leftover debt (dead code, stale
#      doc-registry entries, renamed-and-forgotten) rather than a live
#      operator escape hatch. This is a heuristic, not proof — always confirm
#      by hand before deleting (see INFRA-3625 for the audit trail of the
#      first cull).
#   4. Exits non-zero (and emits reaper_run status=warn) when headroom drops
#      below CHUMP_DEBT_VAR_HEADROOM_MIN, so a scheduled tick can be wired
#      into the same alerting path as any other reaper falling behind.
#
# Usage:
#   ./scripts/ops/bypass-var-cull-audit.sh
#
# Environment:
#   CHUMP_DEBT_VAR_HEADROOM_MIN   min acceptable (ceiling - count) before
#                                   this organ flags a warning (default 3).
set -uo pipefail

source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup bypass-var-cull
reaper_rotate_log /tmp/chump-bypass-var-cull.out.log

# TEST HOOK: point the scan at a synthetic fixture tree instead of the live
# repo, so CI can exercise the headroom math without depending on today's
# real bypass-var count (which legitimately drifts).
REPO_ROOT="${CHUMP_DEBT_VAR_CULL_ROOT_OVERRIDE:-$REAPER_REPO_ROOT}"
CEILING_FILE="$REPO_ROOT/scripts/ci/bypass-var-ceiling.txt"
HEADROOM_MIN="${CHUMP_DEBT_VAR_HEADROOM_MIN:-3}"

CEILING="$(grep -oE '^[0-9]+' "$CEILING_FILE" 2>/dev/null | head -1 || true)"
CEILING="${CEILING:-99999}"

# Mirror scripts/ci/test-no-new-bypass-env-vars.sh's counting logic exactly —
# two independent implementations of the same count would drift.
ALL_VARS="$(grep -rhoP '(?<![A-Za-z0-9_])CHUMP_[A-Z0-9_]*(BYPASS|SKIP|IGNORE|_CHECK|NO_)[A-Z0-9_]*' \
    "$REPO_ROOT/scripts" "$REPO_ROOT/src" "$REPO_ROOT/crates" 2>/dev/null \
    --exclude='test-no-new-bypass-env-vars.sh' \
    --exclude='bypass-var-ceiling.txt' --exclude='test-bypass-var-cull-audit.sh' \
    | grep -vE '_CMD$' | sort -u)"
NOW="$(echo "$ALL_VARS" | grep -c . || true)"
HEADROOM=$((CEILING - NOW))

echo "[bypass-var-cull] count=${NOW} ceiling=${CEILING} headroom=${HEADROOM} (min=${HEADROOM_MIN})"

CANDIDATES=""
CANDIDATE_COUNT=0
while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    nfiles=$(grep -rl "$var" "$REPO_ROOT/scripts" "$REPO_ROOT/src" "$REPO_ROOT/crates" 2>/dev/null \
        --exclude='test-no-new-bypass-env-vars.sh' --exclude='bypass-var-ceiling.txt' --exclude='test-bypass-var-cull-audit.sh' | grep -c .)
    [[ "$nfiles" -gt 1 ]] && continue
    reads=$(grep -rlP "env::var\(\"$var\"\)|\\\$\{?$var\}?\\b" "$REPO_ROOT/scripts" "$REPO_ROOT/src" "$REPO_ROOT/crates" 2>/dev/null \
        --exclude='test-no-new-bypass-env-vars.sh' --exclude='bypass-var-ceiling.txt' --exclude='test-bypass-var-cull-audit.sh' | grep -c .)
    [[ "$reads" -gt 0 ]] && continue
    CANDIDATES="${CANDIDATES}${var}"$'\n'
    CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
done <<<"$ALL_VARS"

if [[ "$CANDIDATE_COUNT" -gt 0 ]]; then
    echo "[bypass-var-cull] ${CANDIDATE_COUNT} candidate(s) for manual review (single-file mention, no detected read-site):"
    echo "$CANDIDATES" | grep -v '^$' | sed 's/^/  - /'
fi

COUNTS_JSON="{\"count\":${NOW},\"ceiling\":${CEILING},\"headroom\":${HEADROOM},\"candidates\":${CANDIDATE_COUNT}}"

if [[ "$HEADROOM" -lt "$HEADROOM_MIN" ]]; then
    echo "[bypass-var-cull] WARN: headroom ${HEADROOM} < min ${HEADROOM_MIN} — cull dead vars and ratchet the ceiling down (see candidates above)." >&2
    reaper_finish warn "$COUNTS_JSON"
    exit 1
fi

reaper_finish ok "$COUNTS_JSON"
exit 0
