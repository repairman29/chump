#!/usr/bin/env bash
# test-provider-model-class-manifest.sh — CREDIBLE-185
#
# Proves that opus/sonnet/haiku slot tags come from the tracked manifest at
# config/provider-model-classes.env rather than living only in a gitignored,
# drift-prone .env: runs scripts/setup/apply-mabel-badass-env.sh against a
# sandboxed CHUMP_DIR and asserts the generated .env carries
# CHUMP_PROVIDER_N_MODEL_CLASS values that match the manifest, and that
# swapping the manifest value changes the generated tag (proving it's the
# manifest driving the output, not a hardcoded default).
#
# Run from repo root: bash scripts/ci/test-provider-model-class-manifest.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

MANIFEST_SRC="$REPO_ROOT/scripts/setup/provider-model-classes.env"

# --- AC1: manifest file exists and is tracked in git ---
if [[ -f "$MANIFEST_SRC" ]]; then
  pass "manifest file exists at scripts/setup/provider-model-classes.env"
else
  fail "manifest file missing at scripts/setup/provider-model-classes.env"
fi

if git ls-files --error-unmatch "scripts/setup/provider-model-classes.env" >/dev/null 2>&1; then
  pass "manifest file is tracked in git (survives fresh checkout)"
else
  fail "manifest file is NOT tracked in git"
fi

run_apply_script() {
  local chump_dir="$1"
  mkdir -p "$chump_dir/logs"
  # Stub start-companion.sh so the trailing bot-restart step is a fast no-op.
  cat > "$chump_dir/start-companion.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$chump_dir/start-companion.sh"

  CHUMP_DIR="$chump_dir" \
  MAC_ENV="$chump_dir/.env.mac" \
  PROVIDER_MODEL_CLASS_MANIFEST="$2" \
    bash "$REPO_ROOT/scripts/setup/apply-mabel-badass-env.sh" >/dev/null 2>&1
}

# --- AC2/3: default manifest drives the generated .env ---
CHUMP_DIR_1="$SANDBOX/chump1"
mkdir -p "$CHUMP_DIR_1"
cat > "$CHUMP_DIR_1/.env.mac" <<'EOF'
CHUMP_PROVIDER_1_KEY=gsk_faketestkey
CHUMP_PROVIDER_2_KEY=csk-faketestkey
EOF

run_apply_script "$CHUMP_DIR_1" "$MANIFEST_SRC" || true

if grep -q '^CHUMP_PROVIDER_1_MODEL_CLASS=sonnet$' "$CHUMP_DIR_1/.env"; then
  pass "groq slot (provider 1) tagged sonnet per manifest"
else
  fail "groq slot (provider 1) missing/incorrect MODEL_CLASS tag"
fi

if grep -q '^CHUMP_PROVIDER_2_MODEL_CLASS=sonnet$' "$CHUMP_DIR_1/.env"; then
  pass "cerebras slot (provider 2) tagged sonnet per manifest"
else
  fail "cerebras slot (provider 2) missing/incorrect MODEL_CLASS tag"
fi

# --- AC4: changing the manifest changes the generated tag (proves it's not hardcoded) ---
CUSTOM_MANIFEST="$SANDBOX/custom-provider-model-classes.env"
cat > "$CUSTOM_MANIFEST" <<'EOF'
PROVIDER_MODEL_CLASS_groq=opus
PROVIDER_MODEL_CLASS_cerebras=haiku
EOF

CHUMP_DIR_2="$SANDBOX/chump2"
mkdir -p "$CHUMP_DIR_2"
cp "$CHUMP_DIR_1/.env.mac" "$CHUMP_DIR_2/.env.mac"

run_apply_script "$CHUMP_DIR_2" "$CUSTOM_MANIFEST" || true

if grep -q '^CHUMP_PROVIDER_1_MODEL_CLASS=opus$' "$CHUMP_DIR_2/.env"; then
  pass "custom manifest overrides groq slot to opus"
else
  fail "custom manifest did not override groq slot to opus"
fi

if grep -q '^CHUMP_PROVIDER_2_MODEL_CLASS=haiku$' "$CHUMP_DIR_2/.env"; then
  pass "custom manifest overrides cerebras slot to haiku"
else
  fail "custom manifest did not override cerebras slot to haiku"
fi

# --- AC5: missing manifest still produces a (safe default) tag, never drops it silently ---
CHUMP_DIR_3="$SANDBOX/chump3"
mkdir -p "$CHUMP_DIR_3"
cp "$CHUMP_DIR_1/.env.mac" "$CHUMP_DIR_3/.env.mac"

run_apply_script "$CHUMP_DIR_3" "$SANDBOX/does-not-exist.env" || true

if grep -q '^CHUMP_PROVIDER_1_MODEL_CLASS=sonnet$' "$CHUMP_DIR_3/.env"; then
  pass "missing manifest falls back to a safe default tag instead of dropping it"
else
  fail "missing manifest did not fall back to a default MODEL_CLASS tag"
fi

echo ""
echo "=== test-provider-model-class-manifest.sh: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
