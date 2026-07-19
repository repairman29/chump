#!/usr/bin/env bash
# test-ingest-phase34-smoke.sh — INFRA-1783 (CI gate for the Phase 3/4 ingest artifacts)
#
# Smoke test: run scripts/ops/generate-hidden-gems.sh and
# scripts/ops/generate-capabilities-registry.sh against a tiny synthetic
# fixture repo (not this repo) and assert both deliverables land and
# CAPABILITIES_REGISTRY.json validates against its schema.
#
# Bypass: CHUMP_INGEST_PHASE34_SKIP=1 (logs reason via ambient).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

if [[ "${CHUMP_INGEST_PHASE34_SKIP:-0}" == "1" ]]; then
    echo "[test-ingest-phase34-smoke] skipped (CHUMP_INGEST_PHASE34_SKIP=1)"
    exit 0
fi

FAIL=0
FIXTURE="$(mktemp -d -t chump-ingest-fixture-XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/scripts/dev"
cat > "$FIXTURE/scripts/README.md" <<'EOF'
# scripts
- scripts/dev/hello.sh - prints hello
EOF
cat > "$FIXTURE/scripts/dev/hello.sh" <<'EOF'
#!/usr/bin/env bash
echo hello
EOF
chmod +x "$FIXTURE/scripts/dev/hello.sh"
git -C "$FIXTURE" init -q 2>/dev/null || true

# ── Phase 3 Evangelist: HIDDEN_GEMS.md ────────────────────────────────────────
if ! bash scripts/ops/generate-hidden-gems.sh "$FIXTURE" >/tmp/chump-ingest-p3.log 2>&1; then
    echo "FAIL: generate-hidden-gems.sh exited non-zero"
    cat /tmp/chump-ingest-p3.log
    FAIL=1
elif [[ ! -f "$FIXTURE/docs/HIDDEN_GEMS.md" ]]; then
    echo "FAIL: $FIXTURE/docs/HIDDEN_GEMS.md was not created"
    FAIL=1
elif ! grep -q "scripts/dev/hello.sh" "$FIXTURE/docs/HIDDEN_GEMS.md"; then
    echo "FAIL: HIDDEN_GEMS.md did not pick up fixture's scripts/dev/hello.sh"
    FAIL=1
else
    echo "PASS: generate-hidden-gems.sh produced HIDDEN_GEMS.md for foreign repo"
fi

# ── Phase 4 Systematizer: CAPABILITIES_REGISTRY.json ─────────────────────────
if ! bash scripts/ops/generate-capabilities-registry.sh "$FIXTURE" >/tmp/chump-ingest-p4.log 2>&1; then
    echo "FAIL: generate-capabilities-registry.sh exited non-zero"
    cat /tmp/chump-ingest-p4.log
    FAIL=1
elif [[ ! -f "$FIXTURE/docs/CAPABILITIES_REGISTRY.json" ]]; then
    echo "FAIL: $FIXTURE/docs/CAPABILITIES_REGISTRY.json was not created"
    FAIL=1
elif ! python3 -c "import json; json.load(open('$FIXTURE/docs/CAPABILITIES_REGISTRY.json'))" 2>/dev/null; then
    echo "FAIL: CAPABILITIES_REGISTRY.json is not valid JSON"
    FAIL=1
else
    echo "PASS: generate-capabilities-registry.sh produced CAPABILITIES_REGISTRY.json for foreign repo"
fi

# ── Schema validation (best-effort; skips if jsonschema not installed) ───────
SCHEMA="$REPO_ROOT/docs/schemas/capabilities-registry.schema.json"
if [[ -f "$FIXTURE/docs/CAPABILITIES_REGISTRY.json" ]] && python3 -c "import jsonschema" 2>/dev/null; then
    if ! python3 - "$SCHEMA" "$FIXTURE/docs/CAPABILITIES_REGISTRY.json" <<'PYEOF'
import json, jsonschema, sys
schema = json.load(open(sys.argv[1]))
data = json.load(open(sys.argv[2]))
v = jsonschema.Draft202012Validator(schema)
errs = list(v.iter_errors(data))
if errs:
    for e in errs[:5]:
        print(f"SCHEMA-ERR: path={list(e.absolute_path)[:3]} msg={e.message[:200]}")
    sys.exit(1)
sys.exit(0)
PYEOF
    then
        echo "FAIL: fixture CAPABILITIES_REGISTRY.json does not validate against schema"
        FAIL=1
    else
        echo "PASS: fixture CAPABILITIES_REGISTRY.json validates against schema"
    fi
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo "[test-ingest-phase34-smoke] all checks passed"
fi

exit "$FAIL"
