#!/usr/bin/env bash
# test-almanac-refresh-guard.sh — RESILIENT-352
#
# Proves scripts/dev/almanac-refresh-guard.py:
#   1. reindexes + advances the marker when origin/main has moved (real_fresh)
#   2. self-heals a dev-hijacked checkout (wrong branch + stray commit) back
#      to origin/main instead of staying parked
#   3. is idempotent: a second run with no new upstream commits does nothing
#      and does NOT re-invoke the reindex command (up_to_date)
#   4. reports `parked` (non-zero exit, marker untouched) when the reindex
#      command fails, instead of a silent rc=0
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d -t almanac-refresh-guard-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

ORIGIN="$TMP/origin.git"
CHECKOUT="$TMP/checkout"
MARKER="$TMP/checkout.last-indexed-commit"
LOG="$TMP/refresh-guard.jsonl"
REINDEX_LOG="$TMP/reindex-calls.log"

git init --quiet --bare "$ORIGIN"

SEED="$TMP/seed"
git init --quiet "$SEED"
git -C "$SEED" config user.email "test@example.com"
git -C "$SEED" config user.name "Test"
echo "v1" > "$SEED/file.txt"
git -C "$SEED" add file.txt
git -C "$SEED" commit --quiet -m "v1"
git -C "$SEED" branch -M main
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push --quiet origin main

git clone --quiet "$ORIGIN" "$CHECKOUT"
git -C "$CHECKOUT" checkout --quiet main 2>/dev/null || git -C "$CHECKOUT" checkout --quiet -b main origin/main

REINDEX_CMD="printf 'ran\n' >> $REINDEX_LOG"

# --- Cycle 1: fresh checkout, no marker yet -> real_fresh ------------------
python3 scripts/dev/almanac-refresh-guard.py \
    --checkout "$CHECKOUT" --marker "$MARKER" --reindex-cmd "$REINDEX_CMD" --log "$LOG"

KIND1=$(tail -1 "$LOG" | python3 -c "import json,sys; print(json.load(sys.stdin)['kind'])")
[ "$KIND1" = "real_fresh" ] || { echo "FAIL: cycle 1 expected real_fresh, got $KIND1"; exit 1; }
[ -f "$MARKER" ] || { echo "FAIL: marker not written after cycle 1"; exit 1; }
CALLS1=$(wc -l < "$REINDEX_LOG" 2>/dev/null || echo 0)
[ "$CALLS1" -eq 1 ] || { echo "FAIL: expected reindex-cmd invoked once, got $CALLS1"; exit 1; }

MAIN_SHA=$(git -C "$SEED" rev-parse main)
MARKER_SHA=$(cat "$MARKER")
[ "$MARKER_SHA" = "$MAIN_SHA" ] || { echo "FAIL: marker $MARKER_SHA != origin main $MAIN_SHA"; exit 1; }

# --- Cycle 2: no upstream change -> up_to_date, no reindex re-run ---------
python3 scripts/dev/almanac-refresh-guard.py \
    --checkout "$CHECKOUT" --marker "$MARKER" --reindex-cmd "$REINDEX_CMD" --log "$LOG"

KIND2=$(tail -1 "$LOG" | python3 -c "import json,sys; print(json.load(sys.stdin)['kind'])")
[ "$KIND2" = "up_to_date" ] || { echo "FAIL: cycle 2 expected up_to_date, got $KIND2"; exit 1; }
CALLS2=$(wc -l < "$REINDEX_LOG")
[ "$CALLS2" -eq 1 ] || { echo "FAIL: up_to_date must not re-invoke reindex-cmd, calls=$CALLS2"; exit 1; }

# --- Dev-hijack simulation: someone checks out a feature branch inside the
# shared index checkout and leaves a stray uncommitted file + a local commit
# that never reached origin. This is the exact class that stayed parked for
# 11 days in the incident.
git -C "$CHECKOUT" checkout --quiet -b dev-hijack
echo "stray dev work" > "$CHECKOUT/hijack.txt"
git -C "$CHECKOUT" add hijack.txt
git -C "$CHECKOUT" commit --quiet -m "dev was here"
echo "uncommitted too" > "$CHECKOUT/untracked.txt"

# Meanwhile origin/main moves forward.
echo "v2" > "$SEED/file.txt"
git -C "$SEED" add file.txt
git -C "$SEED" commit --quiet -m "v2"
git -C "$SEED" push --quiet origin main
MAIN_SHA2=$(git -C "$SEED" rev-parse main)

# --- Cycle 3: hijacked + stale checkout -> must self-heal to real_fresh ---
python3 scripts/dev/almanac-refresh-guard.py \
    --checkout "$CHECKOUT" --marker "$MARKER" --reindex-cmd "$REINDEX_CMD" --log "$LOG"

KIND3=$(tail -1 "$LOG" | python3 -c "import json,sys; print(json.load(sys.stdin)['kind'])")
[ "$KIND3" = "real_fresh" ] || { echo "FAIL: cycle 3 expected real_fresh (self-heal), got $KIND3"; exit 1; }

MARKER_SHA3=$(cat "$MARKER")
[ "$MARKER_SHA3" = "$MAIN_SHA2" ] || { echo "FAIL: marker did not advance to new origin main after hijack"; exit 1; }

CHECKOUT_HEAD=$(git -C "$CHECKOUT" rev-parse HEAD)
[ "$CHECKOUT_HEAD" = "$MAIN_SHA2" ] || { echo "FAIL: checkout HEAD $CHECKOUT_HEAD != origin main $MAIN_SHA2 after force-reset"; exit 1; }
[ ! -f "$CHECKOUT/hijack.txt" ] || { echo "FAIL: stray dev commit's file survived force-reset"; exit 1; }
[ ! -f "$CHECKOUT/untracked.txt" ] || { echo "FAIL: stray untracked file survived git clean"; exit 1; }

CALLS3=$(wc -l < "$REINDEX_LOG")
[ "$CALLS3" -eq 2 ] || { echo "FAIL: expected reindex-cmd invoked a 2nd time, got $CALLS3"; exit 1; }

# --- Cycle 4: reindex-cmd fails -> parked, marker unchanged, non-zero exit -
echo "v3" > "$SEED/file.txt"
git -C "$SEED" add file.txt
git -C "$SEED" commit --quiet -m "v3"
git -C "$SEED" push --quiet origin main

set +e
python3 scripts/dev/almanac-refresh-guard.py \
    --checkout "$CHECKOUT" --marker "$MARKER" --reindex-cmd "exit 1" --log "$LOG"
RC=$?
set -e

[ "$RC" -ne 0 ] || { echo "FAIL: expected non-zero exit when reindex-cmd fails"; exit 1; }
KIND4=$(tail -1 "$LOG" | python3 -c "import json,sys; print(json.load(sys.stdin)['kind'])")
[ "$KIND4" = "parked" ] || { echo "FAIL: cycle 4 expected parked on reindex failure, got $KIND4"; exit 1; }
MARKER_SHA4=$(cat "$MARKER")
[ "$MARKER_SHA4" = "$MAIN_SHA2" ] || { echo "FAIL: marker must not advance when reindex-cmd fails"; exit 1; }

echo "OK: almanac-refresh-guard.py tracks origin/main, self-heals dev-hijack, and distinguishes real_fresh/up_to_date/parked"
