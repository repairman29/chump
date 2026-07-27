#!/usr/bin/env bash
# test-pr-unstick-observability.sh — INFRA-2728
#
# Verifies Decision 4 (pr_unstick) in opus-curator.sh emits
# kind=curator_decision with gh_calls + failure_class on every
# success/failure/timeout path, and that a `gh pr list` timeout is a hard
# stop that does NOT fall through to `chump gap reserve`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CURATOR="$REPO_ROOT/scripts/coord/opus-curator.sh"
[[ -f "$CURATOR" ]] || { echo "FAIL: missing $CURATOR"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

setup() {
  TMP="$(mktemp -d)"
  LOCK_DIR="$TMP/.chump-locks"
  mkdir -p "$LOCK_DIR"
  AMB="$LOCK_DIR/ambient.jsonl"
  FS="$LOCK_DIR/fleet-state.json"
  echo '{}' > "$FS"
  : > "$AMB"
  SHIM_DIR="$TMP/bin"
  mkdir -p "$SHIM_DIR"
}

teardown() {
  rm -rf "$TMP"
}

base_chump_shim() {
  # $1: "reserve_ok" | "reserve_permanent" | "reserve_transient"
  local mode="$1"
  cat > "$SHIM_DIR/chump" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "health --slo-check") echo "  pass L1-SLO-1 silent_agent"; exit 0 ;;
  "waste-tally --since") echo '{"waste_rate":0}'; exit 0 ;;
  "gap audit-priorities") echo '{"p0_count":2,"vague_pickable":0}'; exit 0 ;;
  "gap list") echo '[]'; exit 0 ;;
  "gap reserve")
    case "$mode" in
      reserve_ok) echo "reserving ID... done INFRA-4242"; exit 0 ;;
      reserve_permanent) echo "error: title too similar to an existing gap (duplicate)"; exit 1 ;;
      reserve_transient) echo "error: connection reset by peer"; exit 1 ;;
    esac
    ;;
  "gap set") exit 0 ;;
  *) echo "{}"; exit 0 ;;
esac
SHIM
  chmod +x "$SHIM_DIR/chump"
}

gh_shim_stuck() {
  # Stuck PRs present -> triggers the pr_unstick file-gap path.
  cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then
  echo 2
  exit 0
fi
exit 0
SHIM
  chmod +x "$SHIM_DIR/gh"
}

gh_shim_timeout() {
  # Simulate a `gh pr list` that hangs past the 30s timeout wrapper: sleep
  # longer than the harness needs to observe rc=124 quickly, using a short
  # sleep + SIGTERM trap is unnecessary — `timeout` in the curator handles
  # the real kill; here we just need gh itself to never produce valid
  # output so classify-as-transient logic is exercised via a nonzero rc
  # with a timeout-flavored message on stderr instead of a real 30s wait.
  cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then
  echo "error: context deadline exceeded (Client.Timeout exceeded while awaiting headers)" >&2
  exit 1
fi
exit 0
SHIM
  chmod +x "$SHIM_DIR/gh"
}

run_curator() {
  env \
    PATH="$SHIM_DIR:/usr/bin:/bin" \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_FLEET_STATE="$FS" \
    LOCK_DIR="$LOCK_DIR" \
    REPO_ROOT="$REPO_ROOT" \
    HOME="$TMP" \
    bash "$CURATOR" --once >"$TMP/out.log" 2>&1 || true
}

pr_unstick_lines() {
  grep '"decision_type":"pr_unstick"' "$AMB" || true
}

# ---------------------------------------------------------------------------
# Scenario 1: success path — gap reserve succeeds. gh_calls + no failure_class.
# ---------------------------------------------------------------------------
setup
base_chump_shim reserve_ok
gh_shim_stuck
run_curator

LINE="$(pr_unstick_lines)"
[[ -n "$LINE" ]] || fail "scenario1: no pr_unstick decision emitted"
echo "$LINE" | grep -q '"action_taken":"filed INFRA-' \
  || fail "scenario1: expected a filed-gap action_taken, got: $LINE"
echo "$LINE" | grep -q '"gh_calls":1' \
  || fail "scenario1: expected gh_calls:1, got: $LINE"
ok "scenario1: success path emits gh_calls and files the gap"
teardown

# ---------------------------------------------------------------------------
# Scenario 2: gap-reserve PERMANENT failure — failure_class=permanent.
# ---------------------------------------------------------------------------
setup
base_chump_shim reserve_permanent
gh_shim_stuck
run_curator

LINE="$(pr_unstick_lines)"
[[ -n "$LINE" ]] || fail "scenario2: no pr_unstick decision emitted"
echo "$LINE" | grep -q '"action_taken":"error: chump gap reserve failed"' \
  || fail "scenario2: expected gap-reserve failure action_taken, got: $LINE"
echo "$LINE" | grep -q '"failure_class":"permanent"' \
  || fail "scenario2: expected failure_class:permanent, got: $LINE"
echo "$LINE" | grep -q '"gh_calls":1' \
  || fail "scenario2: expected gh_calls:1, got: $LINE"
ok "scenario2: gap-reserve permanent failure classified correctly"
teardown

# ---------------------------------------------------------------------------
# Scenario 3: gap-reserve TRANSIENT failure — failure_class=transient.
# ---------------------------------------------------------------------------
setup
base_chump_shim reserve_transient
gh_shim_stuck
run_curator

LINE="$(pr_unstick_lines)"
[[ -n "$LINE" ]] || fail "scenario3: no pr_unstick decision emitted"
echo "$LINE" | grep -q '"failure_class":"transient"' \
  || fail "scenario3: expected failure_class:transient, got: $LINE"
ok "scenario3: gap-reserve transient failure (connection reset) classified correctly"
teardown

# ---------------------------------------------------------------------------
# Scenario 4: gh pr list itself fails/times out — must NOT fall through to
# `chump gap reserve` at all (counter never advances / no reserve call).
# ---------------------------------------------------------------------------
setup
RESERVE_LOG="$TMP/reserve-calls.log"
: > "$RESERVE_LOG"
cat > "$SHIM_DIR/chump" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "health --slo-check") echo "  pass L1-SLO-1 silent_agent"; exit 0 ;;
  "waste-tally --since") echo '{"waste_rate":0}'; exit 0 ;;
  "gap audit-priorities") echo '{"p0_count":2,"vague_pickable":0}'; exit 0 ;;
  "gap list") echo '[]'; exit 0 ;;
  "gap reserve")
    printf '%s\n' "\$*" >> "$RESERVE_LOG"
    echo "reserving ID... done INFRA-9999"; exit 0 ;;
  "gap set") exit 0 ;;
  *) echo "{}"; exit 0 ;;
esac
SHIM
chmod +x "$SHIM_DIR/chump"
gh_shim_timeout
run_curator

# Other decisions (e.g. balance_restock) legitimately call `chump gap
# reserve` in this fixture — only the pr-stuck-cluster title must be absent.
grep -q 'pr-stuck-cluster' "$RESERVE_LOG" \
  && fail "scenario4: gh pr list failure fell through to chump gap reserve"
ok "scenario4: gh pr list failure does not fall through to gap reserve"

LINE="$(pr_unstick_lines)"
[[ -n "$LINE" ]] || fail "scenario4: no pr_unstick decision emitted for gh pr list failure"
echo "$LINE" | grep -q '"action_taken":"error: gh pr list rc=' \
  || fail "scenario4: expected gh-pr-list error action_taken, got: $LINE"
echo "$LINE" | grep -q '"failure_class":"transient"' \
  || fail "scenario4: expected failure_class:transient (timeout-flavored message), got: $LINE"
echo "$LINE" | grep -q '"gh_calls":1' \
  || fail "scenario4: expected gh_calls:1, got: $LINE"
ok "scenario4: gh pr list timeout classified transient with gh_calls reported"
teardown

echo
echo "=== test-pr-unstick-observability.sh PASSED ==="
