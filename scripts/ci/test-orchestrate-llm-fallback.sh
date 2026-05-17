#!/usr/bin/env bash
# scripts/ci/test-orchestrate-llm-fallback.sh — INFRA-1452
#
# Verifies that chump orchestrate auto-falls back to LLM when pattern matching
# returns intent_parse_unknown and a provider is configured.
#
# Checks:
#   1. INFRA-1452 marker in src/intent_parser.rs
#   2. Source: llm_provider_configured, parse_llm_response, emit_intent_llm_event defined
#   3. Source: BudgetStatus enum + intent_llm_budget_check defined
#   4. intent_parse_llm registered in EVENT_REGISTRY.yaml
#   5. Binary: stub-unknown + ANTHROPIC_API_KEY set → kind=intent_parse_llm emitted
#   6. Binary: no API key → hint "set ANTHROPIC_API_KEY" in stderr
#   7. Binary: known intent → kind=intent_parse_ok (no LLM call for known patterns)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/src/intent_parser.rs"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
skip() { printf '\033[0;33mSKIP\033[0m %s\n' "$*"; }

[[ -f "$SRC" ]] || fail "intent_parser.rs missing: $SRC"

# ── 1. INFRA-1452 marker ──────────────────────────────────────────────────────
grep -q "INFRA-1452" "$SRC" \
    || fail "INFRA-1452 marker missing from intent_parser.rs"
ok "INFRA-1452 marker present"

# ── 2. Required functions defined ─────────────────────────────────────────────
grep -q "fn llm_provider_configured" "$SRC" \
    || fail "llm_provider_configured not defined"
grep -q "fn parse_llm_response" "$SRC" \
    || fail "parse_llm_response not defined"
grep -q "fn emit_intent_llm_event" "$SRC" \
    || fail "emit_intent_llm_event not defined"
ok "LLM fallback functions defined (llm_provider_configured, parse_llm_response, emit_intent_llm_event)"

# ── 3. BudgetStatus + intent_llm_budget_check defined ────────────────────────
grep -q "BudgetStatus" "$SRC" \
    || fail "BudgetStatus enum not defined"
grep -q "fn intent_llm_budget_check" "$SRC" \
    || fail "intent_llm_budget_check not defined"
grep -q "fn record_intent_llm_spend" "$SRC" \
    || fail "record_intent_llm_spend not defined"
ok "Budget functions defined (BudgetStatus, intent_llm_budget_check, record_intent_llm_spend)"

# ── 4. EVENT_REGISTRY entry ───────────────────────────────────────────────────
[[ -f "$REGISTRY" ]] || fail "EVENT_REGISTRY.yaml missing"
grep -q "intent_parse_llm" "$REGISTRY" \
    || fail "intent_parse_llm not in EVENT_REGISTRY.yaml"
ok "intent_parse_llm registered in EVENT_REGISTRY"

# ── Binary integration tests ──────────────────────────────────────────────────
# Find binary (shared target dir for worktrees).
if [[ ! -x "$CHUMP_BIN" ]]; then
    ALT="$(cd "$REPO_ROOT" && git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
    if [[ -n "$ALT" && -x "$ALT/target/debug/chump" ]]; then
        CHUMP_BIN="$ALT/target/debug/chump"
    elif [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
        CHUMP_BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
    fi
fi

if [[ ! -x "$CHUMP_BIN" ]]; then
    skip "CHUMP_BIN not found — skipping binary rounds 5-7"
    skip "  Build with: cargo build --bin chump"
    echo ""
    echo "Source-level checks (rounds 1-4) PASSED."
    exit 0
fi

# Prepare an isolated repo for ambient.jsonl writes.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/.chump-locks" "$WORK/repo/.chump"
cd "$WORK/repo"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
git commit --allow-empty -m "init" -q

run_orchestrate() {
    # Run chump orchestrate with given env vars (as separate name=value args) and intent text.
    # Last positional arg is the intent text string.
    # All preceding args (before --intent) are name=value env pairs.
    #
    # Usage: run_orchestrate "VAR1=val1" "VAR2=val2" -- "intent text here"
    local env_args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        env_args+=("$1")
        shift
    done
    shift  # consume "--"
    local intent_text="$1"

    local ambient="$WORK/repo/.chump-locks/ambient.jsonl"
    rm -f "$ambient"
    set +e
    env "${env_args[@]}" \
        CHUMP_REPO_ROOT="$WORK/repo" \
        "$CHUMP_BIN" orchestrate "$intent_text" \
        > "$WORK/stdout.txt" 2> "$WORK/stderr.txt"
    set -e
}

# ── 5. Stub unknown → intent_parse_llm emitted ───────────────────────────────
run_orchestrate \
    "ANTHROPIC_API_KEY=stub-key" \
    "CHUMP_INTENT_LLM_STUB_CMD=chump gap list --status open" \
    -- "ship the offline quickstart by EOD"

STDOUT="$(cat "$WORK/stdout.txt")"
AMBIENT="$WORK/repo/.chump-locks/ambient.jsonl"

echo "$STDOUT" | grep -q '"kind":"intent_parse_llm"' \
    || fail "round 5: intent_parse_llm not in stdout; got: $STDOUT"
[[ -f "$AMBIENT" ]] && grep -q '"kind":"intent_parse_llm"' "$AMBIENT" \
    || fail "round 5: intent_parse_llm not in ambient.jsonl"
echo "$STDOUT" | grep -q '"provider":"stub"' \
    || fail "round 5: provider:stub not in stdout; got: $STDOUT"
ok "round 5: stub-unknown + provider configured → kind=intent_parse_llm emitted"

# ── 6. No API key → hint on stderr ───────────────────────────────────────────
# Clear any inherited provider env vars by passing empty values.
run_orchestrate \
    "ANTHROPIC_API_KEY=" \
    "OPENAI_API_KEY=" \
    "CHUMP_OPENAI_API_KEY=" \
    "OLLAMA_HOST=" \
    "CHUMP_CASCADE_ENABLED=" \
    -- "ship the offline quickstart by EOD"

STDERR="$(cat "$WORK/stderr.txt")"
echo "$STDERR" | grep -qi "set ANTHROPIC_API_KEY" \
    || fail "round 6: hint not in stderr; got: $STDERR"
ok "round 6: no provider → hint 'set ANTHROPIC_API_KEY to enable freeform intents'"

# ── 7. Known pattern → intent_parse_ok (no LLM) ──────────────────────────────
run_orchestrate \
    "ANTHROPIC_API_KEY=" \
    "OPENAI_API_KEY=" \
    "CHUMP_OPENAI_API_KEY=" \
    "OLLAMA_HOST=" \
    "CHUMP_CASCADE_ENABLED=" \
    -- "show me the open gaps"

STDOUT="$(cat "$WORK/stdout.txt")"
echo "$STDOUT" | grep -q '"kind":"intent_parse_ok"' \
    || fail "round 7: expected intent_parse_ok for known pattern; got: $STDOUT"
ok "round 7: known intent → intent_parse_ok without LLM call"

echo ""
echo "All 7 checks PASSED — INFRA-1452 LLM fallback for chump orchestrate works"
