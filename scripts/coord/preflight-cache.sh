#!/usr/bin/env bash
# preflight-cache.sh — INFRA-1835 tree-sha cache wrapper for `chump preflight`
#
# Computes a content-hash of the staged delta + key source dirs (src/, scripts/,
# crates/, Cargo.lock, .github/workflows/), checks a cache at
# .chump-locks/preflight-cache/<tree-sha>.json, and:
#   - PASS cache hit (age <1h): exits 0 immediately with "cache HIT (pass)"
#   - FAIL cache hit (age <24h): exits 1 immediately with cached failure summary
#   - Miss / stale / bypass: runs `chump preflight` and writes the result
#
# Use as a drop-in for `chump preflight`:
#   bash scripts/coord/preflight-cache.sh [args...]
#
# Operator overrides:
#   CHUMP_PREFLIGHT_NO_CACHE=1   # force re-run, don't read or write cache
#
# Pairs with: META-071 (preflight parity), INFRA-1670 (chump preflight core).
#
# Removes the skip-incentive: warm preflight is now faster than `cargo check`
# alone, so operators stop bypassing the gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CACHE_DIR="$REPO_ROOT/.chump-locks/preflight-cache"

# ── Bypass ───────────────────────────────────────────────────────────────────
if [ "${CHUMP_PREFLIGHT_NO_CACHE:-0}" = "1" ]; then
    echo "[preflight-cache] CHUMP_PREFLIGHT_NO_CACHE=1 — bypassing cache" >&2
    exec chump preflight "$@"
fi

mkdir -p "$CACHE_DIR"

# ── Compute tree-sha ─────────────────────────────────────────────────────────
# Hash inputs: staged diff content + content-hashes of every tracked source
# file under src/, scripts/, crates/, Cargo.lock, .github/workflows/.
# `git diff --cached` covers what the user is about to commit; the directory
# scan captures the rest of the workspace so a change anywhere invalidates.

cd "$REPO_ROOT"

# Build a deterministic input stream:
#   1) Staged diff (what's about to be committed)
#   2) hash-object for every tracked file in the cache-relevant dirs
{
    git diff --cached 2>/dev/null
    git ls-files \
        src/ scripts/ crates/ Cargo.lock '.github/workflows/' 2>/dev/null \
        | sort \
        | while read -r f; do
            [ -f "$f" ] || continue
            printf '%s ' "$f"
            git hash-object "$f" 2>/dev/null || echo "0000"
        done
} > /tmp/preflight-cache-input-$$.txt

TREE_SHA=$(shasum -a 256 /tmp/preflight-cache-input-$$.txt | awk '{print $1}')
rm -f /tmp/preflight-cache-input-$$.txt
SHORT_SHA="${TREE_SHA:0:12}"
CACHE_FILE="$CACHE_DIR/${TREE_SHA}.json"

# ── Cache lookup ─────────────────────────────────────────────────────────────
now_ts=$(date +%s)
if [ -f "$CACHE_FILE" ]; then
    mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    age=$((now_ts - mtime))
    cached_status=$(python3 -c "import json; print(json.load(open('$CACHE_FILE')).get('status', '?'))" 2>/dev/null || echo '?')

    if [ "$cached_status" = "pass" ] && [ "$age" -lt 3600 ]; then
        echo "[preflight-cache] HIT (pass, age=${age}s, tree-sha=${SHORT_SHA}) — skipping gates"
        exit 0
    fi
    if [ "$cached_status" = "fail" ] && [ "$age" -lt 86400 ]; then
        echo "[preflight-cache] HIT (fail, age=${age}s, tree-sha=${SHORT_SHA})"
        python3 -c "import json; print(json.load(open('$CACHE_FILE')).get('failure_summary', '(no summary)'))" 2>/dev/null || true
        echo "[preflight-cache] Re-run with: CHUMP_PREFLIGHT_NO_CACHE=1 $0 $*"
        exit 1
    fi
fi

# ── Cache miss → run + cache ─────────────────────────────────────────────────
echo "[preflight-cache] MISS (tree-sha=${SHORT_SHA}) — running gates"
start_ts=$(date +%s)
LOG_FILE="/tmp/preflight-cache-output-$$.log"

chump preflight "$@" 2>&1 | tee "$LOG_FILE"
exit_code=${PIPESTATUS[0]}
end_ts=$(date +%s)

if [ "$exit_code" = "0" ]; then
    status="pass"
    failure_summary=""
else
    status="fail"
    failure_summary=$(tail -25 "$LOG_FILE" 2>/dev/null | tr '\n' '\\n' | head -c 2000)
fi

python3 - "$CACHE_FILE" "$TREE_SHA" "$status" "$exit_code" "$((end_ts - start_ts))" "$failure_summary" <<'PYEOF'
import json, sys, datetime
cache_file, tree_sha, status, exit_code, duration_s, failure_summary = sys.argv[1:7]
data = {
    "tree_sha": tree_sha,
    "status": status,
    "exit_code": int(exit_code),
    "duration_s": int(duration_s),
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "failure_summary": failure_summary,
}
with open(cache_file, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF

rm -f "$LOG_FILE"
echo "[preflight-cache] wrote cache (status=${status}, duration=${end_ts}s) — tree-sha=${SHORT_SHA}"
exit "$exit_code"
