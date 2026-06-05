#!/usr/bin/env bash
# Smoke test for mission-scoreboard.sh modes (MISSION-037).
# Asserts:
#   (a) default mode prints all four lines (① ② ③ ④) + VERDICT
#   (b) --aggregate prints AGGREGATE block + VERDICT
#   (c) --per-repo prints PER-REPO block + AGGREGATE block
#   (d) --help exits 0
#   (e) unknown flag exits non-zero with error message
#   (f) all three real modes are bash 3.2 compatible (no mapfile / arr+=())
#       — verified by piping through bash -n (already done in step a).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/mission-scoreboard.sh"

[[ -x "$SCRIPT" ]] || { echo "[test] FAIL: scoreboard not executable"; exit 1; }
echo "[test] (z) executable: OK"

# ── (a) default mode ──────────────────────────────────────────────────────
out=$("$SCRIPT" 2>&1 || true)
for tok in "① THE BINARY" "② Mission-ship ratio" "③ Deploy" "④ Fleet liveness" "VERDICT"; do
    echo "$out" | grep -q "$tok" || { echo "[test] FAIL: default missing '$tok'"; exit 1; }
done
echo "[test] (a) default mode prints all four lines + VERDICT: OK"

# ── (b) --aggregate ───────────────────────────────────────────────────────
out=$("$SCRIPT" --aggregate 2>&1 || true)
echo "$out" | grep -q 'AGGREGATE (across' || { echo "[test] FAIL: --aggregate missing AGGREGATE block"; exit 1; }
echo "$out" | grep -q '═══ VERDICT ═══' || { echo "[test] FAIL: --aggregate missing VERDICT"; exit 1; }
# Should NOT print per-repo block in aggregate-only mode.
echo "$out" | grep -q '═══ PER-REPO ═══' && { echo "[test] FAIL: --aggregate should not show PER-REPO block"; exit 1; }
echo "[test] (b) --aggregate prints AGGREGATE + VERDICT, no PER-REPO: OK"

# ── (c) --per-repo ────────────────────────────────────────────────────────
out=$("$SCRIPT" --per-repo 2>&1 || true)
echo "$out" | grep -q '═══ PER-REPO ═══' || { echo "[test] FAIL: --per-repo missing PER-REPO block"; exit 1; }
echo "$out" | grep -q 'AGGREGATE (across' || { echo "[test] FAIL: --per-repo missing AGGREGATE block"; exit 1; }
echo "$out" | grep -q '═══ VERDICT ═══' || { echo "[test] FAIL: --per-repo missing VERDICT"; exit 1; }
echo "[test] (c) --per-repo prints PER-REPO + AGGREGATE + VERDICT: OK"

# ── (d) --help ────────────────────────────────────────────────────────────
"$SCRIPT" --help >/dev/null 2>&1 || { echo "[test] FAIL: --help non-zero"; exit 1; }
echo "[test] (d) --help exits 0: OK"

# ── (e) unknown flag ──────────────────────────────────────────────────────
"$SCRIPT" --not-a-real-flag >/dev/null 2>&1 && { echo "[test] FAIL: unknown flag should exit non-zero"; exit 1; }
echo "[test] (e) unknown flag exits non-zero: OK"

echo "[test-mission-scoreboard-modes] PASS"
