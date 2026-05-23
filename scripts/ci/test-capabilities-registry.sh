#!/usr/bin/env bash
# test-capabilities-registry.sh — INFRA-1729 (CI gate for canonical AC #7)
#
# Verifies:
#   1. docs/CAPABILITIES_REGISTRY.json exists and parses as JSON
#   2. Every primitive's file_paths entry resolves to a real file (or is empty)
#   3. The registry validates against docs/schemas/capabilities-registry.schema.json
#   4. Drift gate: inject a stale entry → drift detection exits non-zero
#
# Bypass: CHUMP_CAPABILITIES_REGISTRY_SKIP=1 (logs reason via ambient).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="docs/CAPABILITIES_REGISTRY.json"
SCHEMA="docs/schemas/capabilities-registry.schema.json"

if [[ "${CHUMP_CAPABILITIES_REGISTRY_SKIP:-0}" == "1" ]]; then
    echo "[test-capabilities-registry] skipped (CHUMP_CAPABILITIES_REGISTRY_SKIP=1)"
    exit 0
fi

FAIL=0

# ── 1. Registry exists + parseable ───────────────────────────────────────────
if [[ ! -f "$REGISTRY" ]]; then
    echo "FAIL: $REGISTRY does not exist; run scripts/dev/build-capabilities-registry.sh"
    exit 1
fi
if ! python3 -c "import json; json.load(open('$REGISTRY'))" 2>/dev/null; then
    echo "FAIL: $REGISTRY is not valid JSON"
    exit 1
fi
echo "PASS: $REGISTRY exists and parses"

# ── 2. Every file_paths entry resolves ────────────────────────────────────────
missing="$(python3 - <<'PYEOF'
import json, os, sys
d = json.load(open("docs/CAPABILITIES_REGISTRY.json"))
missing = []
for p in d.get("primitives", []):
    for fp in p.get("file_paths", []) or []:
        if not fp:
            continue
        if not os.path.exists(fp):
            missing.append(f"{p.get('primitive_id','?')}: {fp}")
for m in missing[:10]:
    print(m)
sys.exit(1 if missing else 0)
PYEOF
)"
if [[ -n "$missing" ]]; then
    echo "FAIL: primitives reference missing file_paths:"
    printf '  %s\n' $missing
    FAIL=1
else
    echo "PASS: all file_paths resolve"
fi

# ── 3. Schema validation (best-effort; skips if jsonschema not installed) ────
if python3 -c "import jsonschema" 2>/dev/null; then
    if ! python3 - <<PYEOF
import json, jsonschema, sys
schema = json.load(open("$SCHEMA"))
data = json.load(open("$REGISTRY"))
v = jsonschema.Draft202012Validator(schema)
errs = list(v.iter_errors(data))
if errs:
    for e in errs[:5]:
        print(f"SCHEMA-ERR: path={list(e.absolute_path)[:3]} msg={e.message[:200]}")
    sys.exit(1)
sys.exit(0)
PYEOF
    then
        FAIL=1
    else
        echo "PASS: validates against schema (draft 2020-12)"
    fi
else
    echo "SKIP: jsonschema python module not installed (pip install jsonschema)"
fi

# ── 4. Drift detection — inject a stale entry into a copy + re-validate ──────
tmp="$(mktemp -t chump-capreg-drift-XXXXXX.json)"
trap 'rm -f "$tmp"' EXIT
python3 - <<PYEOF
import json
d = json.load(open("$REGISTRY"))
# Inject a stale primitive pointing at a file that cannot exist.
d.setdefault("primitives", []).append({
    "primitive_id": "stale-entry-for-drift-test",
    "kind": "script",
    "file_paths": ["scripts/this/path/does/not/exist/ever.sh"],
    "purpose_one_line": "synthetic stale entry",
})
open("$tmp", "w").write(json.dumps(d))
PYEOF

drift_rc=0
python3 - <<PYEOF || drift_rc=$?
import json, os, sys
d = json.load(open("$tmp"))
bad = 0
for p in d.get("primitives", []):
    for fp in p.get("file_paths", []) or []:
        if fp and not os.path.exists(fp):
            bad += 1
sys.exit(1 if bad else 0)
PYEOF

if [[ "$drift_rc" -eq 0 ]]; then
    echo "FAIL: drift detection did not flag the injected stale entry"
    FAIL=1
else
    echo "PASS: drift detection caught injected stale entry (rc=$drift_rc)"
fi

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "[test-capabilities-registry] OK"
