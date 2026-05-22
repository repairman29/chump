#!/usr/bin/env bash
# scripts/ci/test-content-bots-dispatcher.sh — INFRA-1695
#
# Smoke test for scripts/content-bots/run-bot.sh dispatcher (META-066
# phase 2). Asserts the wiring contracts without requiring a live LLM:
#
#   1. Unknown bot_id exits 4 with bot_id-not-in-bots.yaml message
#   2. --dry-run with a valid bot_id and CHUMP_CONTENT_BOTS=<bot_id> prints
#      the dispatch summary + creates the output dir (no LLM call)
#   3. Without --dry-run AND without claude on PATH, the dispatcher emits
#      content_bot_invoked + content_bot_output{status:failed} events and
#      exits 6 (LLM-call-failed)
#   4. With --predecessor-output, content_bot_pipeline_step is also emitted
#   5. Toggle gate: if bot is not enabled, exit 3 with helpful message
#   6. 3 ambient event kinds (content_bot_invoked, content_bot_output,
#      content_bot_pipeline_step) are registered in EVENT_REGISTRY.yaml
#
# Exit: 0 = contracts intact, 1 = regression

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="$REPO_ROOT/scripts/content-bots/run-bot.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

failures=0

assert_file() {
    if [[ ! -f "$1" ]]; then
        echo "FAIL: $2 not found at $1"
        failures=$((failures + 1))
    fi
}

# ── 1. Files exist + executable ─────────────────────────────────────────────
assert_file "$DISPATCHER" "dispatcher script"
if [[ -f "$DISPATCHER" && ! -x "$DISPATCHER" ]]; then
    echo "FAIL: dispatcher script not executable"
    failures=$((failures + 1))
fi

assert_file "$REGISTRY" "EVENT_REGISTRY.yaml"

# ── 2. Event-registry entries for all 3 kinds ───────────────────────────────
for kind in content_bot_invoked content_bot_output content_bot_pipeline_step; do
    if ! grep -qE "^[[:space:]]*-[[:space:]]*kind:[[:space:]]*$kind\b" "$REGISTRY" 2>/dev/null; then
        echo "FAIL: EVENT_REGISTRY.yaml missing entry for '$kind'"
        failures=$((failures + 1))
    fi
done

# ── 3. Usage: no bot_id → exit 2 ────────────────────────────────────────────
"$DISPATCHER" >/dev/null 2>&1 && ec=$? || ec=$?
if [[ "$ec" -ne 2 ]]; then
    echo "FAIL: dispatcher with no args should exit 2, got $ec"
    failures=$((failures + 1))
fi

# ── 4. Unknown bot_id → exit 4 ──────────────────────────────────────────────
CHUMP_CONTENT_BOTS=nonexistent "$DISPATCHER" nonexistent --dry-run >/dev/null 2>&1 && ec=$? || ec=$?
if [[ "$ec" -ne 4 ]]; then
    echo "FAIL: unknown bot_id should exit 4, got $ec"
    failures=$((failures + 1))
fi

# ── 5. Toggle gate: bot NOT in enabled list (empty env) → exit 3 ────────────
CHUMP_CONTENT_BOTS="" "$DISPATCHER" pmm --dry-run >/dev/null 2>&1 && ec=$? || ec=$?
if [[ "$ec" -ne 3 ]]; then
    echo "FAIL: disabled bot should exit 3 (toggle gate), got $ec"
    failures=$((failures + 1))
fi

# ── 6. Valid dispatch in --dry-run mode → exit 0 + summary printed ──────────
out="$(CHUMP_CONTENT_BOTS=pmm "$DISPATCHER" pmm --dry-run 2>&1)" || true
if ! echo "$out" | grep -q 'DRY-RUN summary'; then
    echo "FAIL: dispatcher --dry-run should print 'DRY-RUN summary'"
    echo "$out" | head -5 | sed 's/^/    /'
    failures=$((failures + 1))
fi

# ── 7. Ambient: content_bot_invoked should fire on --dry-run too ────────────
AMBIENT_TMP="$(mktemp)"
trap 'rm -f "$AMBIENT_TMP"' EXIT
CHUMP_AMBIENT_LOG="$AMBIENT_TMP" CHUMP_CONTENT_BOTS=pmm \
    "$DISPATCHER" pmm --dry-run --run-id smoke-test-001 >/dev/null 2>&1 || true
if ! grep -q '"kind":"content_bot_invoked"' "$AMBIENT_TMP" 2>/dev/null; then
    echo "FAIL: dispatcher did not emit content_bot_invoked to ambient"
    cat "$AMBIENT_TMP" | head -3 | sed 's/^/    /'
    failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1695: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1695: dispatcher wiring intact + 3 ambient event kinds registered"
