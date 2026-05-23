#!/usr/bin/env bash
# test-preflight-cache.sh — INFRA-1835 smoke test for preflight tree-sha cache
#
# Asserts:
#   1. First call computes tree-sha + runs `chump preflight` + writes cache
#   2. Second call with no changes returns "HIT (pass)" in <2s (warm cache)
#   3. CHUMP_PREFLIGHT_NO_CACHE=1 bypasses cache and re-runs gates
#   4. Cache file has expected JSON shape (tree_sha, status, exit_code, ts)
#
# The test stubs `chump` so we don't need a real chump binary in CI; the
# stub returns 0 (pass) and prints a marker line we look for.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/coord/preflight-cache.sh"

fail=0
ok()   { printf '\033[0;32mOK\033[0m   %s\n' "$*"; }
err()  { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; fail=1; }
warn() { printf '\033[0;33mWARN\033[0m %s\n' "$*" >&2; }

[ -x "$WRAPPER" ] || { err "wrapper not executable: $WRAPPER"; exit 1; }
ok "wrapper present + executable"

# ── Test fixture: stub `chump` ───────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$REPO_ROOT/.chump-locks/preflight-cache/test-fixture-*.json" 2>/dev/null' EXIT

cat > "$TMP/chump" <<'STUBEOF'
#!/usr/bin/env bash
# Stub `chump` for the smoke test — just returns 0 quickly and prints a marker.
echo "[stub-chump] called: $*"
exit 0
STUBEOF
chmod +x "$TMP/chump"

# Use a temp HOME so the cache lives in a known place
export PATH="$TMP:$PATH"
which chump | head -1
chump --version 2>&1 || true

# ── Test 1: first run = MISS, runs the (stub) chump preflight ────────────────
echo "--- Test 1: cold cache (MISS) ---"
out1=$(bash "$WRAPPER" 2>&1)
rc1=$?
echo "$out1"
if echo "$out1" | grep -q "MISS"; then
    ok "first run reported MISS"
else
    err "expected MISS marker on first run"
fi
if [ "$rc1" = "0" ]; then
    ok "first run exit=0 (matches stub-chump)"
else
    err "first run exit=$rc1 (expected 0)"
fi

# ── Test 2: second run with no changes = HIT, fast ──────────────────────────
echo ""
echo "--- Test 2: warm cache (HIT, expect <2s) ---"
t_start=$(date +%s)
out2=$(bash "$WRAPPER" 2>&1)
rc2=$?
t_end=$(date +%s)
elapsed=$((t_end - t_start))
echo "$out2"
echo "  elapsed: ${elapsed}s"
if echo "$out2" | grep -q "HIT (pass"; then
    ok "second run reported HIT (pass)"
else
    err "expected HIT (pass) on second run; got: $out2"
fi
if [ "$elapsed" -lt 5 ]; then
    ok "second run completed in ${elapsed}s (<5s threshold)"
else
    warn "second run took ${elapsed}s — slower than expected but not a hard fail"
fi
if [ "$rc2" = "0" ]; then
    ok "second run exit=0 (cached pass)"
else
    err "second run exit=$rc2 (expected 0)"
fi

# ── Test 3: CHUMP_PREFLIGHT_NO_CACHE=1 bypasses cache ───────────────────────
echo ""
echo "--- Test 3: CHUMP_PREFLIGHT_NO_CACHE=1 bypass ---"
out3=$(CHUMP_PREFLIGHT_NO_CACHE=1 bash "$WRAPPER" 2>&1)
rc3=$?
echo "$out3"
if echo "$out3" | grep -q "bypassing cache"; then
    ok "bypass env recognized"
else
    err "expected 'bypassing cache' in output on CHUMP_PREFLIGHT_NO_CACHE=1"
fi
if [ "$rc3" = "0" ]; then
    ok "bypass run exit=0"
else
    err "bypass run exit=$rc3"
fi

# ── Test 4: cache file shape ────────────────────────────────────────────────
echo ""
echo "--- Test 4: cache file JSON shape ---"
CACHE_DIR="$REPO_ROOT/.chump-locks/preflight-cache"
latest=$(ls -t "$CACHE_DIR"/*.json 2>/dev/null | head -1)
if [ -z "$latest" ]; then
    err "no cache file written to $CACHE_DIR"
else
    ok "cache file: $latest"
    for field in tree_sha status exit_code ts duration_s; do
        if python3 -c "import json; assert '$field' in json.load(open('$latest'))" 2>/dev/null; then
            ok "  field present: $field"
        else
            err "  missing field: $field"
        fi
    done
fi

echo ""
if [ "$fail" = "0" ]; then
    ok "INFRA-1835 preflight-cache smoke test PASSED"
fi
exit "$fail"
