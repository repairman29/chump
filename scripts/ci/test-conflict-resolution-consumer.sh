#!/usr/bin/env bash
# scripts/ci/test-conflict-resolution-consumer.sh — RESILIENT-301
#
# Source-contract + structural tests for the standing consumer of
# armed_pr_needs_conflict_resolution. Full end-to-end execution requires a
# live gh/PR queue, so this layer asserts:
#   - Script exists, executable, no bash syntax errors
#   - All 4 new event kinds emit + are registered in EVENT_REGISTRY.yaml
#   - Attempt-tracking + escalation constants present (AC #3)
#   - Plain-rebase-first + conflict-resolver-agent dispatch present (AC #2)
#   - No-op exit when gh/python3 missing (defensive guards)
#   - Synthetic real-conflict scenario: script's rebase-detection logic
#     correctly distinguishes clean vs conflicted via a real git worktree

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/conflict-resolution-consumer.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== RESILIENT-301 conflict-resolution-consumer tests ==="

# ── Source-contract ───────────────────────────────────────────────────────────
[[ -x "$SCRIPT" ]] && ok "script exists + executable" || { fail "missing $SCRIPT"; exit 1; }

if bash -n "$SCRIPT"; then
    ok "no bash syntax errors"
else
    fail "bash -n reported syntax errors"
fi

for kind in conflict_resolution_consumer_tick conflict_resolution_consumer_rebase_clean \
            conflict_resolution_consumer_resolved conflict_resolution_consumer_escalated; do
    if grep -q "\"$kind\"" "$SCRIPT"; then
        ok "script emits $kind"
    else
        fail "script missing emit $kind"
    fi
    if grep -q "kind: $kind" "$REGISTRY"; then
        ok "EVENT_REGISTRY.yaml registers $kind"
    else
        fail "EVENT_REGISTRY.yaml missing $kind"
    fi
done

# AC #1: consumes armed_pr_needs_conflict_resolution (reads from ambient.jsonl)
if grep -q "armed_pr_needs_conflict_resolution" "$SCRIPT"; then
    ok "AC#1: script consumes armed_pr_needs_conflict_resolution"
else
    fail "AC#1: script does not reference armed_pr_needs_conflict_resolution"
fi

# AC #1: also picks up green+DIRTY+unarmed PRs
if grep -q "mergeStateStatus" "$SCRIPT" && grep -q "autoMergeRequest" "$SCRIPT"; then
    ok "AC#1: script scans green+DIRTY+unarmed PRs via mergeStateStatus/autoMergeRequest"
else
    fail "AC#1: missing green-DIRTY-unarmed scan"
fi

# AC #2: attempts resolution — plain rebase first, then conflict-resolver-agent
if grep -q "git rebase origin/main" "$SCRIPT"; then
    ok "AC#2: plain-rebase-first path present"
else
    fail "AC#2: missing plain rebase attempt"
fi
if grep -q "conflict-resolver-agent.sh" "$SCRIPT"; then
    ok "AC#2: dispatches conflict-resolver-agent.sh on real conflicts"
else
    fail "AC#2: missing conflict-resolver-agent.sh dispatch"
fi
if grep -q "force-with-lease" "$SCRIPT" && grep -q "pr merge" "$SCRIPT"; then
    ok "AC#2: pushes clean + arms auto-merge"
else
    fail "AC#2: missing push+arm on clean resolution"
fi

# AC #3: escalates after N tries with PR#, age, reason
if grep -q "CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS" "$SCRIPT"; then
    ok "AC#3: max-attempts budget present"
else
    fail "AC#3: missing max-attempts env"
fi
if grep -q "age_hrs" "$SCRIPT" && grep -q "reason=" "$SCRIPT"; then
    ok "AC#3: escalation includes age + reason"
else
    fail "AC#3: escalation missing age/reason fields"
fi
if grep -q "conflict_resolution_consumer_escalated" "$SCRIPT" && grep -q "BROADCAST" "$SCRIPT"; then
    ok "AC#3: escalates via ambient + broadcast to operator"
else
    fail "AC#3: missing operator escalation path"
fi

# Defensive guards — no-op if gh/python3 missing
if grep -q "command -v gh" "$SCRIPT" && grep -q "command -v python3" "$SCRIPT"; then
    ok "defensive: exits cleanly if gh/python3 missing"
else
    fail "missing defensive command -v guards"
fi

# ── Structural: synthetic conflict vs clean rebase detection ──────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" && git init --quiet -b main
git config user.email t@e && git config user.name t
echo "base" > f.txt && git add . && git commit -q -m base

git checkout -q -b feature
echo "feature-change" > f.txt && git commit -q -am feature

git checkout -q main
echo "main-conflicting-change" > f.txt && git commit -q -am main-change

git checkout -q feature
if ! git rebase main >/dev/null 2>&1; then
    if [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
        ok "structural: synthetic conflict correctly detected via diff-filter=U"
    else
        fail "structural: conflict not surfaced via diff-filter=U"
    fi
    git rebase --abort 2>/dev/null || true
else
    fail "structural: expected rebase conflict did not occur"
fi

# RESILIENT-360: gap-id extraction must work on REAL (lowercase) branch names.
# Branches are named chump/<lowercase-domain>-<num>-fleet-N-<timestamp> but gap
# IDs in state.db are uppercase (RESILIENT-322) — a case-sensitive-only regex
# silently extracts nothing, so conflict-resolver-agent.sh is NEVER dispatched
# on any real orphan (the root cause of the consumer no-op'ing on live PRs).
extract_gap_id() {
    echo "$1" | grep -ioE '[a-z][a-z0-9]*-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]'
}
for case in \
    "chump/resilient-322-fleet-2-20260820-195831=RESILIENT-322" \
    "chump/credible-099-fleet-1-20260818-184349=CREDIBLE-099" \
    "chump/resilient-360-fleet-1-20260821-160649=RESILIENT-360"; do
    br="${case%%=*}"
    want="${case##*=}"
    got="$(extract_gap_id "$br")"
    if [ "$got" = "$want" ]; then
        ok "AC#2: gap_id extracted from real branch '$br' -> $got"
    else
        fail "AC#2: gap_id extraction on '$br' got '$got' want '$want'"
    fi
done
if grep -q "grep -ioE" "$SCRIPT" && grep -q "tr '\[:lower:\]' '\[:upper:\]'" "$SCRIPT"; then
    ok "AC#2: script's gap_id extraction is case-insensitive (matches lowercase branch names)"
else
    fail "AC#2: script's gap_id extraction is case-SENSITIVE-only — will never match real lowercase branch names"
fi

echo ""
# ── Functional: union/stale conflict-drain (the durable drain2.sh, RESILIENT-301) ──
# Source the consumer to get its resolution helpers, then drive _resolve_rebase
# against real git conflicts. The consumer is sourceable: main() runs only when
# executed directly ([ "${BASH_SOURCE[0]}" = "$0" ]), so `source` yields the
# helpers with no side effects. Counters (ok/fail) update in THIS shell (no
# subshell), so a drain regression fails the suite.
# shellcheck disable=SC1090
source "$SCRIPT"
WT_BASE="$TMP"   # keep _union_merge_file scratch inside the test tmpdir

_mkrepo() { mkdir -p "$1"; ( cd "$1" && git init -q -b main \
    && git config user.email t@e && git config user.name t ); }
# _resolve_rebase rebases onto origin/main; fake that ref from local main.
_seal_origin() { ( cd "$1" && git update-ref refs/remotes/origin/main main && git checkout -q feature ); }

# 1) UNION: append-only manifest — both sides' appended lines must survive.
UDIR="$(mktemp -d "$TMP/union.XXXXXX")"; _mkrepo "$UDIR"
( cd "$UDIR"
  printf 'organ-a\norgan-b\n' > organ-manifest.txt; git add .; git commit -q -m base
  git checkout -q -b feature
  printf 'organ-a\norgan-b\norgan-FEATURE\n' > organ-manifest.txt; git commit -qam feat
  git checkout -q main
  printf 'organ-a\norgan-b\norgan-MAIN\n' > organ-manifest.txt; git commit -qam main )
_seal_origin "$UDIR"
UNION_FILES="organ-manifest.txt" STALE_MAIN_FILES="" via="$( cd "$UDIR" && _resolve_rebase )"; rc=$?
if [ "$rc" -eq 0 ] && grep -q organ-MAIN "$UDIR/organ-manifest.txt" && grep -q organ-FEATURE "$UDIR/organ-manifest.txt"; then
    ok "drain: union file keeps BOTH sides' appended lines (via=$via)"
else
    fail "drain: union merge lost a side or failed (rc=$rc via=$via): $(tr '\n' '|' < "$UDIR/organ-manifest.txt" 2>/dev/null)"
fi

# 2) STALE-MAIN: known-stale file must resolve to main's version.
SDIR="$(mktemp -d "$TMP/stale.XXXXXX")"; _mkrepo "$SDIR"
( cd "$SDIR"
  echo base > stale.txt; git add .; git commit -q -m base
  git checkout -q -b feature; echo FEATURE-VERSION > stale.txt; git commit -qam feat
  git checkout -q main;       echo MAIN-VERSION > stale.txt; git commit -qam main )
_seal_origin "$SDIR"
UNION_FILES="" STALE_MAIN_FILES="stale.txt" via="$( cd "$SDIR" && _resolve_rebase )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$SDIR/stale.txt")" = "MAIN-VERSION" ]; then
    ok "drain: stale-main file resolves to main's side (via=$via)"
else
    fail "drain: stale-main resolution wrong (rc=$rc via=$via got=$(cat "$SDIR/stale.txt" 2>/dev/null))"
fi

# 3) REAL code conflict (unclassified) must NOT be guessed — return 1, worktree aborted clean.
RDIR="$(mktemp -d "$TMP/real.XXXXXX")"; _mkrepo "$RDIR"
( cd "$RDIR"
  echo base > code.txt; git add .; git commit -q -m base
  git checkout -q -b feature; echo feature-logic > code.txt; git commit -qam feat
  git checkout -q main;       echo main-logic > code.txt; git commit -qam main )
_seal_origin "$RDIR"
UNION_FILES="organ-manifest.txt" STALE_MAIN_FILES="stale.txt" via="$( cd "$RDIR" && _resolve_rebase )"; rc=$?
inprogress=no
( cd "$RDIR" && { [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] || [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]; } ) && inprogress=yes
if [ "$rc" -ne 0 ] && [ "$inprogress" = no ]; then
    ok "drain: real code conflict is left for escalation (return 1, worktree aborted clean)"
else
    fail "drain: real conflict mishandled (rc=$rc inprogress=$inprogress) — must not guess on code"
fi

# 4) MIXED union+stale in one PR: both resolve.
MDIR="$(mktemp -d "$TMP/mix.XXXXXX")"; _mkrepo "$MDIR"
( cd "$MDIR"
  printf 'x\n' > organ-manifest.txt; echo base > stale.txt; git add .; git commit -q -m base
  git checkout -q -b feature; printf 'x\nfeat\n' > organ-manifest.txt; echo FEATURE > stale.txt; git commit -qam feat
  git checkout -q main;       printf 'x\nmain\n' > organ-manifest.txt; echo MAIN > stale.txt; git commit -qam main )
_seal_origin "$MDIR"
UNION_FILES="organ-manifest.txt" STALE_MAIN_FILES="stale.txt" via="$( cd "$MDIR" && _resolve_rebase )"; rc=$?
if [ "$rc" -eq 0 ] && grep -q feat "$MDIR/organ-manifest.txt" && grep -q main "$MDIR/organ-manifest.txt" && [ "$(cat "$MDIR/stale.txt")" = MAIN ]; then
    ok "drain: mixed union+stale PR resolves both (via=$via)"
else
    fail "drain: mixed union+stale failed (rc=$rc via=$via)"
fi

echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
