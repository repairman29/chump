#!/usr/bin/env bash
# scripts/ci/test-self-model.sh — RESILIENT-1113 (DESIGN GAP 5: no faithful
# self-model). Proves scripts/ops/self-model.sh cross-references what
# organ-manifest.txt CLAIMS is enabled against what systemd (stubbed here)
# ACTUALLY reports, and surfaces the disagreement as `drifted` — the single
# honest mirror the operator previously had to hand-build.
#
# Without the change, scripts/ops/self-model.sh does not exist and this test
# fails at step 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SELF_MODEL_SH="${REPO_ROOT}/scripts/ops/self-model.sh"

FAIL=0
ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; FAIL=1; }

echo "[test-self-model] RESILIENT-1113 — faithful self-model: manifest-claim vs systemd-truth cross-reference"

if [[ ! -f "$SELF_MODEL_SH" ]]; then
    echo "  [FAIL] scripts/ops/self-model.sh not found" >&2
    exit 1
fi
[[ -x "$SELF_MODEL_SH" ]] || { echo "  [FAIL] self-model.sh not executable" >&2; exit 1; }
bash -n "$SELF_MODEL_SH" || { echo "  [FAIL] self-model.sh bash -n failed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] jq not found" >&2; exit 1; }
ok "script present, executable, syntax clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── fixture manifest: 2 services, 2 timers ───────────────────────────────
cat > "$TMP/organ-manifest.txt" <<'EOF'
# fixture manifest
enabled  chump-alive.service      role=brain
enabled  chump-dead.service       role=brain
enabled  chump-alive.timer        role=brain
enabled  chump-dead.timer         role=brain
paging_off chump-silenced.service
EOF

# ── stub systemctl: alive-* report active, dead-* report inactive ────────
STUB="$TMP/systemctl-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
# stub: is-active --quiet <unit> -> exit 0 for *alive*, exit 3 (inactive) otherwise
if [[ "$1" == "is-active" ]]; then
    unit="${@: -1}"
    case "$unit" in
        *alive*) exit 0 ;;
        *) exit 3 ;;
    esac
fi
exit 0
EOF
chmod +x "$STUB"

mkdir -p "$TMP/repo/.chump-locks" "$TMP/repo/web/cockpit" "$TMP/repo/crates/chump-fleet-server"
touch "$TMP/repo/web/v2/cockpit.js" 2>/dev/null || mkdir -p "$TMP/repo/web/v2" && touch "$TMP/repo/web/v2/cockpit.js"
touch "$TMP/repo/.chump-locks/ambient.jsonl"

OUT_JSON="$TMP/self-model.json"

echo "[1. dry-run cross-reference against fixture manifest + stub systemctl]"
out="$(CHUMP_REPO_ROOT="$REPO_ROOT" \
       CHUMP_SELF_MODEL_MANIFEST="$TMP/organ-manifest.txt" \
       CHUMP_SELF_MODEL_SYSTEMCTL_BIN="$STUB" \
       CHUMP_SELF_MODEL_OUT="$OUT_JSON" \
       bash "$SELF_MODEL_SH" --dry-run 2>/dev/null)"

[[ -n "$out" ]] || { fail "no JSON output from --dry-run"; }
echo "$out" | jq . >/dev/null 2>&1 || fail "output is not valid JSON: $out"

organs_total="$(printf '%s' "$out" | jq -r '.organs.manifest_total')"
organs_active="$(printf '%s' "$out" | jq -r '.organs.active')"
timers_total="$(printf '%s' "$out" | jq -r '.timers.manifest_total')"
timers_active="$(printf '%s' "$out" | jq -r '.timers.active')"
drifted_total="$(printf '%s' "$out" | jq -r '.drifted.total')"

[[ "$organs_total" == "2" ]] && ok "organs.manifest_total == 2" || fail "organs.manifest_total expected 2 got $organs_total"
[[ "$organs_active" == "1" ]] && ok "organs.active == 1 (chump-alive.service only)" || fail "organs.active expected 1 got $organs_active"
[[ "$timers_total" == "2" ]] && ok "timers.manifest_total == 2" || fail "timers.manifest_total expected 2 got $timers_total"
[[ "$timers_active" == "1" ]] && ok "timers.active == 1 (chump-alive.timer only)" || fail "timers.active expected 1 got $timers_active"
[[ "$drifted_total" == "2" ]] && ok "drifted.total == 2 (chump-dead.service + chump-dead.timer)" || fail "drifted.total expected 2 got $drifted_total"

drifted_has_dead_service="$(printf '%s' "$out" | jq -e '.drifted.units | index("chump-dead.service")' >/dev/null 2>&1 && echo yes || echo no)"
[[ "$drifted_has_dead_service" == "yes" ]] && ok "drifted.units names chump-dead.service explicitly" || fail "drifted.units missing chump-dead.service — the whole point is naming what's wrong, not just counting it"

paging_off_absent="$(printf '%s' "$out" | jq -e '(.organs.names + .timers.names) | index("chump-silenced.service")' 2>/dev/null)"
[[ "$paging_off_absent" == "null" ]] && ok "paging_off units are excluded from the organ/timer roster" || fail "chump-silenced.service (paging_off) leaked into the roster"

echo "[2. --dry-run must not write the output file]"
[[ -f "$OUT_JSON" ]] && fail "--dry-run wrote $OUT_JSON (should only print to stdout)" || ok "--dry-run wrote nothing to disk"

echo "[3. non-dry-run write path + ambient heartbeat]"
ambient="$TMP/repo/.chump-locks/ambient.jsonl"
CHUMP_REPO_ROOT="$REPO_ROOT" \
CHUMP_SELF_MODEL_MANIFEST="$TMP/organ-manifest.txt" \
CHUMP_SELF_MODEL_SYSTEMCTL_BIN="$STUB" \
CHUMP_SELF_MODEL_OUT="$OUT_JSON" \
CHUMP_AMBIENT_LOG="$ambient" \
bash "$SELF_MODEL_SH" >/dev/null 2>&1

[[ -f "$OUT_JSON" ]] && ok "wrote $OUT_JSON" || fail "did not write $OUT_JSON"
jq -e '.honest == true' "$OUT_JSON" >/dev/null 2>&1 && ok "written doc carries honest:true" || fail "written doc missing honest:true"
grep -q '"kind":"self_model_tick"' "$ambient" 2>/dev/null && ok "emitted self_model_tick ambient heartbeat" || fail "no self_model_tick heartbeat in $ambient"

echo "[4. self_model_tick registered in EVENT_REGISTRY.yaml]"
grep -q "kind: self_model_tick" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" 2>/dev/null \
    && ok "self_model_tick registered" || fail "self_model_tick NOT registered in docs/observability/EVENT_REGISTRY.yaml"

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "=== test-self-model: ALL PASS ==="
    exit 0
else
    echo "=== test-self-model: FAILURES PRESENT ===" >&2
    exit 1
fi
