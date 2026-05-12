#!/usr/bin/env bash
# test-model-registry.sh — INFRA-739
#
# CI gate: validates docs/dispatch/model_registry.yaml
#   1. File exists and is valid YAML (requires python3 + pyyaml)
#   2. All required fields are present on each model entry
#   3. At least 5 models are registered
#   4. All pricing fields are non-negative numbers
#   5. All family values are one of the known enum variants
#
# Exit codes:
#   0 — schema valid, count check passed
#   1 — validation failure (with descriptive error output)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY="$REPO_ROOT/docs/dispatch/model_registry.yaml"

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-739 model-registry CI validation ==="
echo "Registry: $REGISTRY"
echo

# ── 1. File exists ────────────────────────────────────────────────────────────
if [[ ! -f "$REGISTRY" ]]; then
    echo "FATAL: $REGISTRY not found — INFRA-739 not yet implemented."
    exit 1
fi
ok "registry file exists"

# ── 2. Python + PyYAML available ─────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
    echo "FATAL: python3 required for YAML validation"
    exit 1
fi
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "FATAL: PyYAML required (pip install pyyaml)"
    exit 1
fi
ok "python3 + pyyaml available"

# ── 3. Schema validation via Python ──────────────────────────────────────────
VALIDATION_OUTPUT=$(python3 - "$REGISTRY" <<'PYEOF'
import sys, yaml

registry_path = sys.argv[1]

REQUIRED_FIELDS = [
    "model_id",
    "input_per_mtk",
    "output_per_mtk",
    "cache_read_per_mtk",
    "context_k",
    "supports_tool_use",
    "supports_thinking",
    "family",
    "provider_hint",
]

KNOWN_FAMILIES = {
    "Sonnet", "Haiku", "Opus", "QwenChat", "QwenCoder",
    "LlamaInstruct", "DeepSeek", "Other",
}

MIN_MODELS = 5

try:
    data = yaml.safe_load(open(registry_path).read())
except Exception as e:
    print(f"YAML_PARSE_ERROR: {e}")
    sys.exit(1)

models = data.get("models", [])
errors = []

for i, entry in enumerate(models):
    model_id = entry.get("model_id", f"<entry #{i}>")
    # Required fields
    for field in REQUIRED_FIELDS:
        if field not in entry:
            errors.append(f"{model_id}: missing required field '{field}'")
    # Pricing non-negative
    for price_field in ["input_per_mtk", "output_per_mtk", "cache_read_per_mtk"]:
        val = entry.get(price_field)
        if val is not None and float(val) < 0:
            errors.append(f"{model_id}: {price_field} must be >= 0 (got {val})")
    # context_k positive
    ctx = entry.get("context_k")
    if ctx is not None and int(ctx) <= 0:
        errors.append(f"{model_id}: context_k must be > 0 (got {ctx})")
    # family must be known
    fam = entry.get("family")
    if fam is not None and fam not in KNOWN_FAMILIES:
        errors.append(f"{model_id}: unknown family '{fam}' (known: {sorted(KNOWN_FAMILIES)})")
    # bool fields
    for bool_field in ["supports_tool_use", "supports_thinking"]:
        bval = entry.get(bool_field)
        if bval is not None and not isinstance(bval, bool):
            errors.append(f"{model_id}: {bool_field} must be boolean (got {type(bval).__name__})")

count = len(models)
print(f"MODEL_COUNT:{count}")

if count < MIN_MODELS:
    errors.append(f"registry has only {count} model(s); minimum is {MIN_MODELS}")

for e in errors:
    print(f"SCHEMA_ERROR:{e}")

sys.exit(1 if errors else 0)
PYEOF
)

VALIDATION_RC=$?

# Parse output
MODEL_COUNT=$(echo "$VALIDATION_OUTPUT" | grep "^MODEL_COUNT:" | cut -d: -f2 || echo "0")
SCHEMA_ERRORS=$(echo "$VALIDATION_OUTPUT" | grep "^SCHEMA_ERROR:" | sed 's/^SCHEMA_ERROR://')
YAML_ERROR=$(echo "$VALIDATION_OUTPUT" | grep "^YAML_PARSE_ERROR:" | sed 's/^YAML_PARSE_ERROR://')

if [[ -n "$YAML_ERROR" ]]; then
    fail "YAML parse failed: $YAML_ERROR"
elif [[ "$VALIDATION_RC" -ne 0 ]]; then
    while IFS= read -r err; do
        [[ -z "$err" ]] && continue
        fail "$err"
    done <<< "$SCHEMA_ERRORS"
else
    ok "all required fields present on each model entry"
    ok "pricing fields are non-negative"
    ok "family values are valid enum variants"
fi

# ── 4. Model count ────────────────────────────────────────────────────────────
if [[ "${MODEL_COUNT:-0}" -ge 5 ]]; then
    ok "at least 5 models registered (got $MODEL_COUNT)"
else
    fail "too few models: expected >= 5, got ${MODEL_COUNT:-0}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
echo "model_registry.yaml schema OK ($MODEL_COUNT models)."
exit 0
