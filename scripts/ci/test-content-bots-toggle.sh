#!/usr/bin/env bash
# scripts/ci/test-content-bots-toggle.sh — INFRA-1696
#
# Smoke test for `chump content-bots list` — the operator-facing CLI surface
# for the Content Bots Suite (META-066). Verifies:
#   1. `chump content-bots list` prints all 4 bots from docs/agents/content-bots/bots.yaml
#   2. CHUMP_CONTENT_BOTS env override is reflected in the ENABLED column
#   3. `--json` output is valid JSON listing the same bots
#   4. Unknown subcommand exits 2 with help message
#
# Depends on INFRA-1700 (src/content_bots.rs resolver) + INFRA-1690 (bots.yaml).
#
# Exit: 0 = contracts intact, 1 = regression

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif [[ -x "$REPO_ROOT/target/release/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/release/chump"
    elif command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "FAIL INFRA-1696: chump binary not found (set CHUMP_BIN= to override)"
        exit 1
    fi
fi

export CHUMP_BINARY_STALENESS_CHECK="${CHUMP_BINARY_STALENESS_CHECK:-0}"

# Test from inside the repo so repo_path::repo_root() resolves correctly.
cd "$REPO_ROOT"

failures=0

# ── 1. list shows all 4 bot_ids ─────────────────────────────────────────────
out="$(env -u CHUMP_CONTENT_BOTS "$CHUMP_BIN" content-bots list 2>&1)"
for bot in pmm docubot evangelist copybot; do
    if ! echo "$out" | grep -qE "^${bot}\b"; then
        echo "FAIL: 'content-bots list' output missing bot_id '$bot'"
        echo "$out" | head -10 | sed 's/^/    /'
        failures=$((failures + 1))
    fi
done

# ── 2. CHUMP_CONTENT_BOTS env reflected in ENABLED column ───────────────────
out="$(CHUMP_CONTENT_BOTS=pmm,evangelist "$CHUMP_BIN" content-bots list 2>&1)"
pmm_line="$(echo "$out" | grep '^pmm' || true)"
copybot_line="$(echo "$out" | grep '^copybot' || true)"
if ! echo "$pmm_line" | grep -qF '✓'; then
    echo "FAIL: 'pmm' should be enabled when CHUMP_CONTENT_BOTS=pmm,evangelist"
    echo "    got: $pmm_line"
    failures=$((failures + 1))
fi
if echo "$copybot_line" | grep -qE '✓ \(config\|env\)'; then
    echo "FAIL: 'copybot' should be DISABLED when CHUMP_CONTENT_BOTS=pmm,evangelist (not in list)"
    echo "    got: $copybot_line"
    failures=$((failures + 1))
fi

# ── 3. --json output is parseable + contains all 4 bots ─────────────────────
json_out="$(env -u CHUMP_CONTENT_BOTS "$CHUMP_BIN" content-bots list --json 2>&1)"
if ! echo "$json_out" | python3 -c "
import sys, json
try:
    arr = json.loads(sys.stdin.read())
except json.JSONDecodeError as e:
    print(f'invalid json: {e}', file=sys.stderr); sys.exit(1)
ids = sorted(b.get('bot_id','') for b in arr)
want = ['copybot','docubot','evangelist','pmm']
if ids != want:
    print(f'expected {want}, got {ids}', file=sys.stderr); sys.exit(1)
# all default-enabled false from INFRA-1690 foundation
if any(b.get('enabled') for b in arr):
    print('expected all enabled=false in default state', file=sys.stderr); sys.exit(1)
" 2>&1; then
    echo "FAIL: --json output invalid or missing expected fields"
    echo "$json_out" | head -10 | sed 's/^/    /'
    failures=$((failures + 1))
fi

# ── 4. Unknown subcommand exits 2 ───────────────────────────────────────────
"$CHUMP_BIN" content-bots nonsense >/dev/null 2>&1 && ec=$? || ec=$?
if [[ "$ec" -ne 2 ]]; then
    echo "FAIL: unknown subcommand should exit 2, got $ec"
    failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1696: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1696: chump content-bots list intact (4 bots, toggle env wired, --json valid)"
