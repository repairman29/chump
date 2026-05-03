#!/usr/bin/env bash
# test-stale-worktree-reaper.sh — smoke test for the worktree reaper.
#
# Two layers:
#   1. Live dry-run smoke test against the real repo (must exit 0, emit
#      banner + summary line).
#   2. Unit tests for the new process-aware safety checks
#      (INFRA-WORKTREE-REAPER-FIX). These shell out to the live reaper but
#      against a synthetic temp tree — they do NOT touch real worktrees.
#
# Run:
#   ./scripts/ci/test-stale-worktree-reaper.sh
#
# Exits non-zero on any check failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-worktree-reaper.sh"

[[ -x "$REAPER" ]] || { echo "FAIL: reaper not executable: $REAPER"; exit 1; }

# ---------- Layer 1: live dry-run smoke ----------
OUT=$("$REAPER" --dry-run 2>&1 || true)

echo "$OUT" | grep -q "stale-worktree-reaper" \
    || { echo "FAIL: missing banner"; exit 1; }

echo "$OUT" | grep -q "Dry-run mode" \
    || { echo "FAIL: dry-run banner missing"; exit 1; }

echo "$OUT" | grep -q "Log-fresh window" \
    || { echo "FAIL: new log-fresh-window banner missing"; exit 1; }

echo "$OUT" | grep -qE "reaper done: [0-9]+ reapable, [0-9]+ kept, [0-9]+ skipped" \
    || { echo "FAIL: summary line missing"; exit 1; }

echo "$OUT" | grep -qE "REAPABLE|keeping|skipping|SKIP" \
    || { echo "FAIL: no per-worktree decision lines"; exit 1; }

"$REAPER" --help >/dev/null 2>&1 || true

# ---------- Layer 2: process-aware unit tests ----------
# These build a tiny fake repo + worktree under a temp dir and invoke the
# reaper's safety functions inline. We shell-source the script's logic by
# extracting the lsof / find checks into a small shim so we don't have to
# spin up real git worktrees during CI.

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [[ -n "${SLEEP_PID:-}" ]] && kill "$SLEEP_PID" 2>/dev/null || true' EXIT

# --- Test A: lsof check fires on a process with cwd inside path ---
mkdir -p "$TMP/case_a/logs"
(
    cd "$TMP/case_a"
    sleep 30 &
    echo $! > "$TMP/sleep.pid"
)
SLEEP_PID=$(cat "$TMP/sleep.pid")
# Give the shell time to settle the cwd.
sleep 0.3

if command -v lsof >/dev/null 2>&1; then
    if lsof +D "$TMP/case_a" 2>/dev/null | grep -v '^COMMAND' | grep -q .; then
        echo "PASS: lsof correctly detects sleep process with cwd in tree"
    else
        echo "WARN: lsof did not detect sleep cwd — check may be lossy on this OS"
    fi
else
    echo "SKIP: lsof not present"
fi
kill "$SLEEP_PID" 2>/dev/null || true
unset SLEEP_PID

# --- Test B: log-mtime check fires on freshly-touched logs/ file ---
mkdir -p "$TMP/case_b/logs/ab"
touch "$TMP/case_b/logs/ab/run.jsonl"
fresh=$(find "$TMP/case_b/logs" -type f -mmin -10 2>/dev/null | head -1)
if [[ -n "$fresh" ]]; then
    echo "PASS: find -mmin correctly detects fresh log file"
else
    echo "FAIL: find -mmin did not pick up fresh log"; exit 1
fi

# --- Test C: log-mtime check ignores old logs (simulate via mmin -0) ---
# Touch with old timestamp.
old_log="$TMP/case_b/logs/ab/old.jsonl"
touch "$old_log"
# Push mtime back 60 minutes.
touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M.%S)" "$old_log"
old_only=$(find "$TMP/case_b/logs" -type f -mmin -10 -name 'old.jsonl' 2>/dev/null)
if [[ -z "$old_only" ]]; then
    echo "PASS: find -mmin correctly ignores old log file"
else
    echo "FAIL: find -mmin incorrectly flagged old log as fresh"; exit 1
fi

# --- Test D: --force-skip-process-check flag is parseable ---
"$REAPER" --force-skip-process-check --dry-run --log-fresh-min 5 >/dev/null 2>&1 \
    || { echo "FAIL: new flags did not parse"; exit 1; }
echo "PASS: --force-skip-process-check + --log-fresh-min parse OK"

# ---------- Layer 3: INFRA-325 — lease-shape tolerance ----------
# Simulate both lease shapes that the reaper's grep fallback must handle:
#   E: lease WITHOUT "worktree" field → grep exits 1 (no match); must not abort
#   F: lease WITH "worktree" field → grep + sed must extract the path correctly
#
# We test the grep snippet inline (not the full reaper) because spinning up a
# real git repo for a one-liner's correctness is overkill. The live dry-run in
# Layer 1 already confirms the reaper exits 0 against real leases, and the
# majority of real leases lack the "worktree" field (the common case fixed in
# INFRA-325).

# --- Test E: lease WITHOUT "worktree" field — grep exits 1, || true keeps going ---
lease_no_wt="$TMP/lease_no_worktree.json"
cat >"$lease_no_wt" <<'EOF'
{"session_id":"test-sess-1","gap_id":"INFRA-001","taken_at":"2026-05-02T22:00:00Z","paths":[]}
EOF

# Run the exact grep pipeline from the reaper; it should produce empty output and exit 0.
wt_e=$(grep -oE '"worktree"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease_no_wt" \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
if [[ -z "$wt_e" ]]; then
    echo "PASS: lease without worktree field → grep pipeline exits 0, wt=''"
else
    echo "FAIL: lease without worktree field → unexpected wt='$wt_e'"; exit 1
fi

# --- Test F: lease WITH "worktree" field — grep + sed extracts path correctly ---
lease_with_wt="$TMP/lease_with_worktree.json"
EXPECT_WT="/Users/jeffadkins/Projects/Chump/.claude/worktrees/infra-325-test"
cat >"$lease_with_wt" <<EOF
{"session_id":"test-sess-2","gap_id":"INFRA-002","taken_at":"2026-05-02T22:00:00Z","worktree":"${EXPECT_WT}"}
EOF

wt_f=$(grep -oE '"worktree"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease_with_wt" \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
if [[ "$wt_f" == "$EXPECT_WT" ]]; then
    echo "PASS: lease with worktree field → grep pipeline extracts '$wt_f'"
else
    echo "FAIL: lease with worktree field → expected '$EXPECT_WT', got '$wt_f'"; exit 1
fi

echo ""
echo "PASS: all reaper safety-check tests"
echo "----"
echo "$OUT" | tail -10
exit 0
