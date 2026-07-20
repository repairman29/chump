#!/usr/bin/env bash
# test-pr-unstick-observability.sh — INFRA-2728
#
# Verifies observability for Decision 4 (pr_unstick, stuck-PR scan) in
# scripts/coord/opus-curator.sh:
#   1. Success emits kind=curator_decision with gh_calls + failure_class:none
#   2. `chump gap reserve` failure emits a failure_class (transient|permanent)
#   3. A hung `gh pr list` (timeout) emits failure_class:transient and does
#      NOT fall through to `chump gap reserve`
#   4. `_curator_classify_failure` distinguishes transient vs permanent by
#      exit code / message content

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CURATOR="$REPO_ROOT/scripts/coord/opus-curator.sh"
[[ -f "$CURATOR" ]] || { echo "FAIL: missing $CURATOR"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
AMB="$LOCK_DIR/ambient.jsonl"
FS="$LOCK_DIR/fleet-state.json"
echo '{}' > "$FS"

SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"

cat > "$SHIM_DIR/chump" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "health --slo-check") echo "  pass L1-SLO-1 silent_agent"; exit 0 ;;
  "waste-tally --window") echo '{"waste_rate":0}'; exit 0 ;;
  "gap audit-priorities") echo '{"p0_count":2,"vague_pickable":0}'; exit 0 ;;
  "gap list") echo '[]'; exit 0 ;;
  "gap reserve")
    if [[ "${GAP_RESERVE_MODE:-ok}" == "fail_permanent" ]]; then
      echo "error: invalid title" >&2
      exit 1
    elif [[ "${GAP_RESERVE_MODE:-ok}" == "fail_transient" ]]; then
      echo "error: connection reset by peer" >&2
      exit 1
    fi
    echo "reserving ID... done INFRA-90001"
    exit 0 ;;
  "gap set") exit 0 ;;
  *) echo "{}"; exit 0 ;;
esac
SHIM
chmod +x "$SHIM_DIR/chump"

cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then
  case "${GH_PR_LIST_MODE:-ok}" in
    ok) echo 3; exit 0 ;;
    hang) sleep 5; echo 0; exit 0 ;;
    error) echo "gh: some other error" >&2; exit 1 ;;
  esac
fi
exit 0
SHIM
chmod +x "$SHIM_DIR/gh"

# Real `timeout` binary must stay on PATH alongside the gh/chump shims —
# without it the fleet's `timeout <secs> gh pr list` line fails with
# "command not found" (rc=127) rather than the scenario under test.
REAL_PATH="$PATH"

run_curator() {
  env \
    PATH="$SHIM_DIR:$REAL_PATH" \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_FLEET_STATE="$FS" \
    LOCK_DIR="$LOCK_DIR" \
    REPO_ROOT="$REPO_ROOT" \
    HOME="$TMP" \
    "$@" \
    bash "$CURATOR" --once >/dev/null 2>&1 || true
}

# ── Scenario 1: success path emits gh_calls + failure_class:none ──────────
: > "$AMB"
GAP_RESERVE_MODE=ok GH_PR_LIST_MODE=ok run_curator
grep -q '"decision_type":"pr_unstick".*"action_taken":"filed INFRA-.*"gh_calls":1,"failure_class":"none"' "$AMB" \
  && ok "success path: gh_calls + failure_class:none recorded" \
  || fail "success path missing gh_calls/failure_class:none: $(grep pr_unstick "$AMB")"

# ── Scenario 2: chump gap reserve fails with a permanent-looking error ────
: > "$AMB"
rm -f "$LOCK_DIR"/curator-filed-*.json
GAP_RESERVE_MODE=fail_permanent GH_PR_LIST_MODE=ok run_curator
grep -q '"decision_type":"pr_unstick".*"action_taken":"error: chump gap reserve failed".*"failure_class":"permanent"' "$AMB" \
  && ok "gap-reserve permanent failure classified correctly" \
  || fail "permanent failure not classified: $(grep pr_unstick "$AMB")"

# ── Scenario 3: chump gap reserve fails with a transient-looking error ────
: > "$AMB"
rm -f "$LOCK_DIR"/curator-filed-*.json
GAP_RESERVE_MODE=fail_transient GH_PR_LIST_MODE=ok run_curator
grep -q '"decision_type":"pr_unstick".*"action_taken":"error: chump gap reserve failed".*"failure_class":"transient"' "$AMB" \
  && ok "gap-reserve transient failure classified correctly" \
  || fail "transient failure not classified: $(grep pr_unstick "$AMB")"

# ── Scenario 4: hung gh pr list times out and is classified transient ─────
: > "$AMB"
rm -f "$LOCK_DIR"/curator-filed-*.json
env \
  PATH="$SHIM_DIR:$REAL_PATH" \
  CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_FLEET_STATE="$FS" \
  LOCK_DIR="$LOCK_DIR" \
  REPO_ROOT="$REPO_ROOT" \
  HOME="$TMP" \
  GH_PR_LIST_MODE=hang \
  CHUMP_CURATOR_GH_TIMEOUT_S=1 \
  bash "$CURATOR" --once >/dev/null 2>&1 || true
grep -q '"decision_type":"pr_unstick".*"action_taken":"error: gh pr list failed".*"failure_class":"transient"' "$AMB" \
  && ok "hung gh pr list classified transient (timeout)" \
  || fail "timeout not classified transient: $(grep pr_unstick "$AMB")"
grep '"decision_type":"pr_unstick"' "$AMB" | grep -q "INFRA-90001" \
  && fail "timeout scenario should not have reached chump gap reserve" \
  || ok "timeout scenario did not fall through to chump gap reserve"

echo
echo "=== test-pr-unstick-observability.sh PASSED ==="
