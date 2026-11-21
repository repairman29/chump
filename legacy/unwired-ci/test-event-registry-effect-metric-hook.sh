#!/usr/bin/env bash
# scripts/ci/test-event-registry-effect-metric-hook.sh — INFRA-1517
#
# Validates that pre-commit-effect-metric.sh:
#   1. Blocks a commit that adds a new EVENT_REGISTRY entry without effect_metric
#   2. Passes a commit that adds a new entry WITH effect_metric
#   3. Passes when no changes to EVENT_REGISTRY.yaml
#   4. Passes when CHUMP_EFFECT_METRIC_CHECK=0 (bypass)
#   5. Hook is wired into pre-commit (source check)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit-effect-metric.sh"
PRE_COMMIT="$REPO_ROOT/scripts/git-hooks/pre-commit"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$HOOK" ]] || fail "pre-commit-effect-metric.sh missing or not executable: $HOOK"
[[ -f "$REGISTRY" ]] || fail "EVENT_REGISTRY.yaml not found: $REGISTRY"

# ── Test harness: synthetic git repo ─────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
mkdir -p docs/observability scripts/git-hooks

# Seed registry with one well-formed entry.
cat > docs/observability/EVENT_REGISTRY.yaml <<'YAML'
events:
  - kind: existing_kind
    effect_metric: self
    emitter: some/module.rs
    trigger: existing trigger
    consumers: [fleet-brief]
    fields_required: [ts, kind]
YAML

git add docs/observability/EVENT_REGISTRY.yaml
git commit -m "init registry" -q

# Copy hook into the synthetic repo.
cp "$HOOK" scripts/git-hooks/pre-commit-effect-metric.sh
chmod +x scripts/git-hooks/pre-commit-effect-metric.sh

# Helper: run the hook against the current staged index.
run_hook() {
    bash "$WORK/scripts/git-hooks/pre-commit-effect-metric.sh" 2>&1
}

# ── Test 1: new entry WITHOUT effect_metric → should BLOCK ───────────────────
cat >> docs/observability/EVENT_REGISTRY.yaml <<'YAML'

  - kind: bad_new_kind
    emitter: src/foo.rs
    trigger: missing effect_metric
    consumers: [fleet-brief]
    fields_required: [ts, kind]
YAML

git add docs/observability/EVENT_REGISTRY.yaml

set +e
OUT1=$(run_hook 2>&1)
EXIT1=$?
set -e

if [[ "$EXIT1" -eq 0 ]]; then
    fail "test 1: hook should have BLOCKED (missing effect_metric), but exited 0"
fi
echo "$OUT1" | grep -q "bad_new_kind" \
    || fail "test 1: diagnostic should mention 'bad_new_kind'; got: $OUT1"
ok "test 1: new entry without effect_metric blocked correctly"

# ── Test 2: new entry WITH effect_metric → should PASS ───────────────────────
cat > docs/observability/EVENT_REGISTRY.yaml <<'YAML'
events:
  - kind: existing_kind
    effect_metric: self
    emitter: some/module.rs
    trigger: existing trigger
    consumers: [fleet-brief]
    fields_required: [ts, kind]

  - kind: good_new_kind
    effect_metric: self
    emitter: src/bar.rs
    trigger: has effect_metric so should pass
    consumers: [fleet-brief]
    fields_required: [ts, kind]
YAML

git add docs/observability/EVENT_REGISTRY.yaml

set +e
OUT2=$(run_hook 2>&1)
EXIT2=$?
set -e

if [[ "$EXIT2" -ne 0 ]]; then
    fail "test 2: hook should PASS (effect_metric present), but exited $EXIT2; output: $OUT2"
fi
ok "test 2: new entry with effect_metric passes"

# ── Test 3: no changes to EVENT_REGISTRY → PASS (no-op) ──────────────────────
# Stage a different file entirely.
echo "unrelated change" > unrelated.txt
git add unrelated.txt

set +e
OUT3=$(run_hook 2>&1)
EXIT3=$?
set -e

if [[ "$EXIT3" -ne 0 ]]; then
    fail "test 3: no registry changes — hook should be no-op, got $EXIT3; $OUT3"
fi
ok "test 3: no EVENT_REGISTRY changes → hook is no-op"
git checkout docs/observability/EVENT_REGISTRY.yaml 2>/dev/null
git rm -f unrelated.txt 2>/dev/null || true

# ── Test 4: CHUMP_EFFECT_METRIC_CHECK=0 bypasses the block ───────────────────
# Re-stage the bad entry.
cat >> docs/observability/EVENT_REGISTRY.yaml <<'YAML'

  - kind: bypass_test_kind
    emitter: src/baz.rs
    trigger: no effect_metric but bypassed
YAML
git add docs/observability/EVENT_REGISTRY.yaml

set +e
OUT4=$(CHUMP_EFFECT_METRIC_CHECK=0 run_hook 2>&1)
EXIT4=$?
set -e

if [[ "$EXIT4" -ne 0 ]]; then
    fail "test 4: CHUMP_EFFECT_METRIC_CHECK=0 should bypass, got exit $EXIT4"
fi
ok "test 4: CHUMP_EFFECT_METRIC_CHECK=0 bypasses the block"

# ── Test 5: hook wired into pre-commit ───────────────────────────────────────
grep -q "pre-commit-effect-metric" "$PRE_COMMIT" \
    || fail "test 5: pre-commit-effect-metric.sh not wired into $PRE_COMMIT"
grep -q "INFRA-1517" "$PRE_COMMIT" \
    || fail "test 5: INFRA-1517 marker not found in pre-commit"
ok "test 5: hook wired into pre-commit (INFRA-1517)"

echo ""
echo "All 5 checks PASSED — INFRA-1517 effect-metric pre-commit guard works"
