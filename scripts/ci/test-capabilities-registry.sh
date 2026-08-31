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

# ── 5. Freshness: a backdated generated_at must be FLAGGED (CREDIBLE-240) ────
#
# The failure this guards against: the committed catalog sat 11 weeks stale
# while almanac served it with a file:line receipt, and nothing anywhere said
# it was old. Below we deliberately backdate a copy and assert the freshness
# checker refuses to pass it silently.
FRESHNESS="$REPO_ROOT/scripts/ci/check-capabilities-freshness.sh"
if [[ ! -f "$FRESHNESS" ]]; then
    echo "FAIL: missing freshness checker: $FRESHNESS"
    FAIL=1
else
    backdated="$(mktemp -t chump-capreg-backdated-XXXXXX.json)"
    fresh_copy="$(mktemp -t chump-capreg-fresh-XXXXXX.json)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp' '$backdated' '$fresh_copy'" EXIT

    REGISTRY="$REGISTRY" BACKDATED="$backdated" FRESH_COPY="$fresh_copy" python3 - <<'PYEOF'
import json, os
from datetime import datetime, timedelta, timezone

doc = json.load(open(os.environ["REGISTRY"]))

old = datetime.now(timezone.utc) - timedelta(days=999)
doc["generated_at"] = old.replace(microsecond=0).isoformat().replace("+00:00", "Z")
json.dump(doc, open(os.environ["BACKDATED"], "w"), indent=2)

now = datetime.now(timezone.utc).replace(microsecond=0)
doc["generated_at"] = now.isoformat().replace("+00:00", "Z")
json.dump(doc, open(os.environ["FRESH_COPY"], "w"), indent=2)
PYEOF

    # 5a. Backdated + --strict must exit non-zero.
    stale_rc=0
    stale_out="$(bash "$FRESHNESS" --registry "$backdated" --strict 2>&1)" || stale_rc=$?
    if [[ "$stale_rc" -eq 0 ]]; then
        echo "FAIL: backdated generated_at (999d) silently trusted — checker exited 0 under --strict"
        FAIL=1
    else
        echo "PASS: backdated generated_at flagged under --strict (rc=$stale_rc)"
    fi

    # 5b. ...and it must SAY so, not merely exit non-zero. A silent non-zero is
    #     unreadable in a CI log; the banner is what a human or agent sees.
    if ! grep -q '\[STALE\]' <<<"$stale_out"; then
        echo "FAIL: backdated registry produced no [STALE] banner; output was:"
        printf '  %s\n' "$stale_out"
        FAIL=1
    else
        echo "PASS: backdated registry prints a loud [STALE] banner"
    fi

    # 5c. Advisory (default) mode must still say STALE even though it exits 0 —
    #     otherwise promoting the gate to blocking would be the only way to
    #     ever learn the catalog had rotted.
    advisory_out="$(bash "$FRESHNESS" --registry "$backdated" 2>&1)" || true
    if ! grep -q '\[STALE\]' <<<"$advisory_out"; then
        echo "FAIL: advisory mode stayed silent on a 999-day-old registry"
        FAIL=1
    else
        echo "PASS: advisory mode still reports [STALE] out loud"
    fi

    # 5d. A genuinely fresh registry must pass — a checker that flags
    #     everything teaches everyone to ignore it.
    fresh_rc=0
    fresh_out="$(bash "$FRESHNESS" --registry "$fresh_copy" --strict 2>&1)" || fresh_rc=$?
    if [[ "$fresh_rc" -ne 0 ]]; then
        echo "FAIL: freshly-stamped registry was flagged (rc=$fresh_rc):"
        printf '  %s\n' "$fresh_out"
        FAIL=1
    else
        echo "PASS: freshly-stamped registry passes --strict"
    fi
fi

# ── 6. Self-reporting fields are present (CREDIBLE-240) ──────────────────────
# A reader who only ever sees the JSON — an agent handed a chunk of it by
# almanac — must be able to judge freshness without running anything.
if ! REGISTRY="$REGISTRY" python3 - <<'PYEOF'
import json, os, sys
doc = json.load(open(os.environ["REGISTRY"]))
missing = [k for k in ("_read_me_first", "stale_after", "staleness_policy",
                       "content_sha256", "related_registries") if k not in doc]
if missing:
    print(f"missing self-reporting fields: {missing}")
    sys.exit(1)
if "stale" not in doc["_read_me_first"].lower():
    print("_read_me_first does not mention staleness")
    sys.exit(1)
# AC#5: the cross-reference must actually name charter.json.
if not any("charter.json" in json.dumps(r) for r in doc["related_registries"]):
    print("related_registries does not reference privateer/charter.json")
    sys.exit(1)
sys.exit(0)
PYEOF
then
    echo "FAIL: registry is missing its self-reporting metadata"
    FAIL=1
else
    echo "PASS: registry self-reports staleness policy + charter cross-reference"
fi

# ── 7. Content-drift signal (CREDIBLE-240, informational) ────────────────────
#
# Regenerate into a scratch file and compare `content_sha256` — the hash over
# the substantive sections only, excluding timestamps. This is the exact
# comparison .github/workflows/capabilities-registry.yml uses to decide whether
# to commit, so running it here proves the signal works.
#
# Informational on purpose: a PR that legitimately adds a crate or event kind
# SHOULD drift, and the on-merge workflow regenerates main straight after. Set
# CHUMP_CAPABILITIES_DRIFT_STRICT=1 to make drift a hard failure.
drift_out="$(mktemp -t chump-capreg-regen-XXXXXX.json)"
# shellcheck disable=SC2064
trap "rm -f '$tmp' '${backdated:-}' '${fresh_copy:-}' '$drift_out'" EXIT

if ! python3 -c "import yaml" 2>/dev/null; then
    # Without PyYAML the generator cannot apply docs/CAPABILITIES_OVERLAY.yaml,
    # so its output legitimately differs from the committed file. Comparing
    # anyway would report drift that isn't there. Skip loudly instead.
    echo "SKIP: drift comparison needs PyYAML (pip install pyyaml) — overlay would be dropped"
elif bash scripts/dev/build-capabilities-registry.sh --out "$drift_out" --quiet 2>/dev/null; then
    committed_sha="$(python3 -c "import json;print(json.load(open('$REGISTRY')).get('content_sha256',''))")"
    regen_sha="$(python3 -c "import json;print(json.load(open('$drift_out')).get('content_sha256',''))")"
    if [[ -z "$regen_sha" ]]; then
        echo "WARN: regenerated registry has no content_sha256 — drift signal unavailable"
    elif [[ "$committed_sha" == "$regen_sha" ]]; then
        echo "PASS: committed registry matches a fresh generation (content_sha256=${regen_sha:0:12})"
    else
        echo "WARN: capabilities registry has DRIFTED from the repo"
        echo "      committed   : ${committed_sha:0:12}"
        echo "      regenerated : ${regen_sha:0:12}"
        echo "      Fix: bash scripts/dev/build-capabilities-registry.sh"
        if [[ "${CHUMP_CAPABILITIES_DRIFT_STRICT:-0}" == "1" ]]; then
            FAIL=1
        fi
    fi
else
    echo "WARN: could not regenerate for the drift comparison — skipping"
fi

# ── 8. Ecosystem adapters beyond Rust (INFRA-3469) ───────────────────────────
#
# comprehend UAT pilot-1 B3: running the generator against a non-Rust repo
# produced zero crate_apis entries — the WIRING organ's #1 coverage gap. This
# builds a synthetic fixture repo with a JS/TS package and a Python package
# (no Cargo.toml anywhere) and asserts the generator now discovers both.
fixture_dir="$(mktemp -d -t chump-capreg-ecosystem-fixture-XXXXXX)"
fixture_out="$(mktemp -t chump-capreg-ecosystem-out-XXXXXX.json)"
# shellcheck disable=SC2064
trap "rm -f '$tmp' '${backdated:-}' '${fresh_copy:-}' '$drift_out' '$fixture_out'; rm -rf '$fixture_dir'" EXIT

mkdir -p "$fixture_dir/pkg-js/src"
cat > "$fixture_dir/pkg-js/package.json" <<'EOF'
{"name": "fixture-js-pkg", "main": "src/index.js"}
EOF
cat > "$fixture_dir/pkg-js/src/index.js" <<'EOF'
export function widgetFrobnicate() {}
export class WidgetGadget {}
EOF

mkdir -p "$fixture_dir/pkg_py"
cat > "$fixture_dir/pkg_py/__init__.py" <<'EOF'
def frobnicate_widget():
    pass


class GadgetWidget:
    pass
EOF

if bash scripts/dev/build-capabilities-registry.sh --repo-root "$fixture_dir" --out "$fixture_out" --quiet 2>/dev/null; then
    ecosystem_check_rc=0
    FIXTURE_OUT="$fixture_out" python3 - <<'PYEOF' || ecosystem_check_rc=$?
import json, os, sys

doc = json.load(open(os.environ["FIXTURE_OUT"]))
apis = doc.get("crate_apis", [])

js_entries = [c for c in apis if c.get("ecosystem") == "js_ts"]
py_entries = [c for c in apis if c.get("ecosystem") == "python"]

if not js_entries:
    print("no js_ts crate_apis entry discovered for fixture package.json")
    sys.exit(1)
js_names = {i["name"] for i in js_entries[0].get("public_items", [])}
if "widgetFrobnicate" not in js_names or "WidgetGadget" not in js_names:
    print(f"js_ts public_items missing expected exports, got {js_names}")
    sys.exit(1)

if not py_entries:
    print("no python crate_apis entry discovered for fixture __init__.py")
    sys.exit(1)
py_names = {i["name"] for i in py_entries[0].get("public_items", [])}
if "frobnicate_widget" not in py_names or "GadgetWidget" not in py_names:
    print(f"python public_items missing expected def/class, got {py_names}")
    sys.exit(1)

sys.exit(0)
PYEOF
    if [[ "$ecosystem_check_rc" -ne 0 ]]; then
        echo "FAIL: ecosystem adapters did not discover JS/TS + Python fixture packages"
        FAIL=1
    else
        echo "PASS: js_ts + python ecosystem adapters discover fixture packages + public items"
    fi
else
    echo "FAIL: generator errored against ecosystem-adapter fixture repo"
    FAIL=1
fi

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "[test-capabilities-registry] OK"
