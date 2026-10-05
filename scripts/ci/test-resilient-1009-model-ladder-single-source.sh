#!/usr/bin/env bash
# scripts/ci/test-resilient-1009-model-ladder-single-source.sh — RESILIENT-1009
# (a RESILIENT-596 slice)
#
# AC1: the default floor model, escalation ladder, and API-key references are
# defined in ONE tracked manifest referenced by the organ-manifest and by the
# reproducible installer template (provision-chumpd-host.sh's chumpd.env),
# rather than duplicated as hand-copied literals in each.
# AC2: the fleet worker runtime (worker.sh) reads the ladder EXCLUSIVELY from
# that single-sourced manifest — sourcing it last so it wins over whatever a
# launcher already exported from machine-local ~/.chump/providers.env.
#
# Run from repo root: bash scripts/ci/test-resilient-1009-model-ladder-single-source.sh

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

MANIFEST="$REPO_ROOT/scripts/setup/model-escalation-ladder.env"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
PROVISION="$REPO_ROOT/scripts/setup/provision-chumpd-host.sh"
ORGAN_MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# --- AC1: canonical manifest exists, is tracked, and defines the ladder ---
if [[ -f "$MANIFEST" ]]; then
  pass "manifest exists at scripts/setup/model-escalation-ladder.env"
else
  fail "manifest missing at scripts/setup/model-escalation-ladder.env"
fi

if git ls-files --error-unmatch "scripts/setup/model-escalation-ladder.env" >/dev/null 2>&1; then
  pass "manifest is tracked in git (survives fresh checkout)"
else
  fail "manifest is NOT tracked in git"
fi

for var in CHUMP_FLOOR_MODEL CHUMP_MODEL_ESCALATION_LADDER CHUMP_FREE_TIER_PROVIDERS; do
  if grep -qE "^${var}=" "$MANIFEST" 2>/dev/null; then
    pass "manifest defines $var"
  else
    fail "manifest missing $var"
  fi
done

# --- AC1: reproducible installer template references the manifest instead of
# hand-copying the ladder literal ---
if grep -q 'model-escalation-ladder.env' "$PROVISION" 2>/dev/null; then
  pass "provision-chumpd-host.sh chumpd.env template references the canonical manifest"
else
  fail "provision-chumpd-host.sh does not reference scripts/setup/model-escalation-ladder.env"
fi

if grep -qE '^# ?CHUMP_MODEL_ESCALATION_LADDER=' "$PROVISION" 2>/dev/null; then
  fail "provision-chumpd-host.sh still hand-copies a CHUMP_MODEL_ESCALATION_LADDER literal (drift risk)"
else
  pass "provision-chumpd-host.sh no longer duplicates the escalation-ladder literal"
fi

# --- AC1: organ-manifest.txt cross-references the single-sourced manifest ---
if grep -q 'model-escalation-ladder.env' "$ORGAN_MANIFEST" 2>/dev/null; then
  pass "organ-manifest.txt cross-references the model-ladder manifest"
else
  fail "organ-manifest.txt does not mention scripts/setup/model-escalation-ladder.env"
fi

# --- AC2: worker.sh sources the manifest, and does so AFTER REPO_ROOT is set
# so the path resolves, and the source line appears near the top of the file
# (before the per-cycle dispatch body) so it always runs once per process. ---
if grep -q 'source "\$CHUMP_MODEL_LADDER_MANIFEST"' "$WORKER" 2>/dev/null; then
  pass "worker.sh sources the model-ladder manifest"
else
  fail "worker.sh does not source \$CHUMP_MODEL_LADDER_MANIFEST"
fi

repo_root_line=$(grep -n '^REPO_ROOT=' "$WORKER" | head -1 | cut -d: -f1)
manifest_source_line=$(grep -n 'source "\$CHUMP_MODEL_LADDER_MANIFEST"' "$WORKER" | head -1 | cut -d: -f1)
chump_local_branch_line=$(grep -n 'chump-local)' "$WORKER" | head -1 | cut -d: -f1)

if [[ -n "$repo_root_line" && -n "$manifest_source_line" && "$manifest_source_line" -gt "$repo_root_line" ]]; then
  pass "manifest sourced after REPO_ROOT is resolved"
else
  fail "manifest source ordering relative to REPO_ROOT looks wrong (repo_root=$repo_root_line, manifest=$manifest_source_line)"
fi

if [[ -n "$manifest_source_line" && -n "$chump_local_branch_line" && "$manifest_source_line" -lt "$chump_local_branch_line" ]]; then
  pass "manifest sourced before the chump-local dispatch branch consumes the ladder"
else
  fail "manifest source ordering relative to the chump-local branch looks wrong (manifest=$manifest_source_line, chump_local=$chump_local_branch_line)"
fi

# --- AC2: hermetic proof the manifest WINS over an inherited (launcher /
# providers.env) value, mirroring worker.sh's own sourcing block exactly. ---
resolve_ladder() {
  local inherited="$1"
  CHUMP_MODEL_ESCALATION_LADDER="$inherited" \
  CHUMP_MODEL_LADDER_MANIFEST="$MANIFEST" \
    bash -c '
      if [[ -f "$CHUMP_MODEL_LADDER_MANIFEST" ]]; then
          set -a
          source "$CHUMP_MODEL_LADDER_MANIFEST"
          set +a
      fi
      echo "$CHUMP_MODEL_ESCALATION_LADDER"
    '
}

manifest_value="$(grep -E '^CHUMP_MODEL_ESCALATION_LADDER=' "$MANIFEST" | tail -1 | cut -d= -f2-)"
got="$(resolve_ladder "some-stale-local-model,another-stale-model")"
if [[ "$got" == "$manifest_value" ]]; then
  pass "manifest overrides an inherited/stale CHUMP_MODEL_ESCALATION_LADDER (got '$got')"
else
  fail "manifest did NOT override inherited ladder — got '$got', want '$manifest_value'"
fi

echo ""
echo "=== test-resilient-1009-model-ladder-single-source.sh: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
