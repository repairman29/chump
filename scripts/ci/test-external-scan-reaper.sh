#!/usr/bin/env bash
# Smoke test for scripts/ops/external-scan-reaper.sh (MISSION-036).
# Asserts:
#   (a) script is executable
#   (b) --help exits 0
#   (c) default dry-run on empty tree: exits 0, reaps nothing
#   (d) fixture with N>KEEP scans: dry-run shows N-KEEP reaps; execute removes oldest
#   (e) keep N >= count → no reap
#   (f) --keep 0 / non-numeric → exit non-zero (safety)
#   (g) per-repo independence: reaping repo A's old scans doesn't touch repo B
#   (h) emits kind=external_scan_reaped to ambient (when path provided)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/external-scan-reaper.sh"

WORK_DIR="$(mktemp -d /tmp/scan-reaper-test-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

EXTERNAL_ROOT="$WORK_DIR/external"
AMBIENT="$WORK_DIR/ambient.jsonl"
touch "$AMBIENT"

export CHUMP_EXTERNAL_ROOT="$EXTERNAL_ROOT"
export CHUMP_AMBIENT_PATH="$AMBIENT"

# ── (a) executable ────────────────────────────────────────────────────────
[[ -x "$REAPER" ]] || { echo "[test] FAIL: reaper not executable"; exit 1; }
echo "[test] (a) executable: OK"

# ── (b) --help ────────────────────────────────────────────────────────────
"$REAPER" --help >/dev/null 2>&1 || { echo "[test] FAIL: --help non-zero"; exit 1; }
echo "[test] (b) --help: OK"

# ── (c) empty tree ────────────────────────────────────────────────────────
mkdir -p "$EXTERNAL_ROOT"
out=$("$REAPER" 2>&1)
echo "$out" | grep -q 'repos=0' || { echo "[test] FAIL: empty tree should report repos=0; got: $out"; exit 1; }
echo "[test] (c) empty tree: OK"

# ── (d) N>KEEP fixture ────────────────────────────────────────────────────
SCANS="$EXTERNAL_ROOT/foo/bar/scans"
mkdir -p "$SCANS"
# 7 scans, newest first by name (later timestamps come last lexicographically).
for ts in 20260601T000000Z 20260602T000000Z 20260603T000000Z 20260604T000000Z \
          20260605T000000Z 20260606T000000Z 20260607T000000Z; do
    echo "{}" > "$SCANS/onboard-scan-$ts.json"
done

# Dry-run with keep=3 → would reap 4 oldest (20260601..20260604), keep 3 newest.
out=$("$REAPER" --keep 3 2>&1)
reap=$(echo "$out" | grep -E 'reaped=[0-9]+' | tail -1 | sed -E 's/.*reaped=([0-9]+).*/\1/')
[[ "$reap" == "4" ]] || { echo "[test] FAIL: expected reap=4 dry-run, got reap=$reap; output: $out"; exit 1; }
# Files all still present after dry-run.
remaining=$(find "$SCANS" -name 'onboard-scan-*.json' | wc -l | tr -d ' ')
[[ "$remaining" == "7" ]] || { echo "[test] FAIL: dry-run removed files (expected 7, got $remaining)"; exit 1; }
echo "[test] (d.dry-run) reap=4 expected, files intact: OK"

# Execute with keep=3 → 4 oldest deleted, 3 newest remain.
"$REAPER" --execute --keep 3 >/dev/null 2>&1
remaining=$(find "$SCANS" -name 'onboard-scan-*.json' | wc -l | tr -d ' ')
[[ "$remaining" == "3" ]] || { echo "[test] FAIL: execute should leave 3 (got $remaining)"; exit 1; }
# The 3 left are the 3 latest.
[[ -f "$SCANS/onboard-scan-20260607T000000Z.json" ]] || { echo "[test] FAIL: newest removed"; exit 1; }
[[ -f "$SCANS/onboard-scan-20260606T000000Z.json" ]] || { echo "[test] FAIL: 2nd-newest removed"; exit 1; }
[[ -f "$SCANS/onboard-scan-20260605T000000Z.json" ]] || { echo "[test] FAIL: 3rd-newest removed"; exit 1; }
[[ -f "$SCANS/onboard-scan-20260601T000000Z.json" ]] && { echo "[test] FAIL: oldest survived"; exit 1; }
echo "[test] (d.execute) 4 oldest removed, 3 newest kept: OK"

# ── (e) keep ≥ count: no reap ─────────────────────────────────────────────
out=$("$REAPER" --keep 10 2>&1)
echo "$out" | grep -q 'reaped=0' || { echo "[test] FAIL: keep>=count should reap 0; got: $out"; exit 1; }
echo "[test] (e) keep >= count: no reap: OK"

# ── (f) --keep 0 / non-numeric ────────────────────────────────────────────
"$REAPER" --keep 0 >/dev/null 2>&1 && { echo "[test] FAIL: --keep 0 should error"; exit 1; }
"$REAPER" --keep abc >/dev/null 2>&1 && { echo "[test] FAIL: --keep abc should error"; exit 1; }
echo "[test] (f) safety guards on --keep: OK"

# ── (g) per-repo independence ─────────────────────────────────────────────
SCANS_B="$EXTERNAL_ROOT/qux/quux/scans"
mkdir -p "$SCANS_B"
echo "{}" > "$SCANS_B/onboard-scan-20260101T000000Z.json"
# Reaper sees both repos. Reap to keep=1: foo/bar has 3 → reaps 2; qux/quux has 1 → reaps 0.
"$REAPER" --execute --keep 1 >/dev/null 2>&1
remaining_a=$(find "$EXTERNAL_ROOT/foo/bar/scans" -name 'onboard-scan-*.json' | wc -l | tr -d ' ')
remaining_b=$(find "$EXTERNAL_ROOT/qux/quux/scans" -name 'onboard-scan-*.json' | wc -l | tr -d ' ')
[[ "$remaining_a" == "1" ]] || { echo "[test] FAIL: repo A should have 1 (got $remaining_a)"; exit 1; }
[[ "$remaining_b" == "1" ]] || { echo "[test] FAIL: repo B should have 1 (got $remaining_b)"; exit 1; }
echo "[test] (g) per-repo independence: OK"

# ── (h) ambient emit ──────────────────────────────────────────────────────
grep -q '"kind":"external_scan_reaped"' "$AMBIENT" \
    || { echo "[test] FAIL: no external_scan_reaped event emitted"; exit 1; }
echo "[test] (h) ambient emit: OK"

echo "[test-external-scan-reaper] PASS"
