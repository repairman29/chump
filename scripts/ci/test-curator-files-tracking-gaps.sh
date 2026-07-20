#!/usr/bin/env bash
# test-curator-files-tracking-gaps.sh — INFRA-979
#
# Verifies the curator now FILES tracking gaps for Decisions 3/4/5 rather
# than emitting action_taken=identified_only. Also verifies daily dedup and
# CHUMP_CURATOR_DRY_RUN=1 suppression.

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

RESERVE_COUNTER="$TMP/counter"
echo 100 > "$RESERVE_COUNTER"

SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"

cat > "$SHIM_DIR/chump" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "health --slo-check") echo "  pass L1-SLO-1 silent_agent"; exit 0 ;;
  "waste-tally --window") echo '{"waste_rate":42}'; exit 0 ;;
  "gap audit-priorities") echo '{"p0_count":2,"vague_pickable":0}'; exit 0 ;;
  "gap list") echo '[]'; exit 0 ;;
  "gap reserve")
    n=\$(cat "$RESERVE_COUNTER")
    echo \$((n + 1)) > "$RESERVE_COUNTER"
    echo "reserving ID... done INFRA-\$n"
    exit 0 ;;
  "gap set") exit 0 ;;
  *) echo "{}"; exit 0 ;;
esac
SHIM
chmod +x "$SHIM_DIR/chump"

cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
# Return 3 stuck PRs so pr_unstick fires.
if [[ "$1 $2" == "pr list" ]]; then
  echo 3
  exit 0
fi
exit 0
SHIM
chmod +x "$SHIM_DIR/gh"

run_curator() {
  env \
    PATH="$SHIM_DIR:$PATH" \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_FLEET_STATE="$FS" \
    LOCK_DIR="$LOCK_DIR" \
    REPO_ROOT="$REPO_ROOT" \
    HOME="$TMP" \
    "$@" \
    bash "$CURATOR" --once 2>&1
}

# Scenario 1: real run files tracking gaps.
: > "$AMB"
run_curator >/dev/null

PR_FILED=$(grep '"decision_type":"pr_unstick"' "$AMB" | grep -c '"action_taken":"filed INFRA-' || true)
[[ "$PR_FILED" -ge 1 ]] || fail "pr_unstick did not file a gap"
ok "pr_unstick filed a tracking gap"

WASTE_FILED=$(grep '"decision_type":"waste_investigation"' "$AMB" | grep -c '"action_taken":"filed INFRA-' || true)
[[ "$WASTE_FILED" -ge 1 ]] || fail "waste_investigation did not file a gap"
ok "waste_investigation filed a tracking gap"

BAL_FILED=$(grep '"decision_type":"balance_restock"' "$AMB" | grep -c '"action_taken":"filed INFRA-' || true)
[[ "$BAL_FILED" -ge 1 ]] || fail "balance_restock did not file any gap"
ok "balance_restock filed a tracking gap"

ID_ONLY=$(grep -E '"(pr_unstick|waste_investigation|balance_restock)"' "$AMB" | grep -c '"action_taken":"identified_only' || true)
[[ "$ID_ONLY" -eq 0 ]] || fail "still found identified_only emissions"
ok "no identified_only emissions for INFRA-979 decisions"

# Scenario 2: dedup
PRE_COUNT=$(grep -c '"action_taken":"filed INFRA-' "$AMB")
run_curator >/dev/null
POST_COUNT=$(grep -c '"action_taken":"filed INFRA-' "$AMB")
DIFF=$((POST_COUNT - PRE_COUNT))
[[ "$DIFF" -eq 0 ]] || fail "second run on same day re-filed $DIFF gaps (dedup broken)"
ok "dedup: second run on same day does not re-file"

# Scenario 3: dry-run never invokes `chump gap reserve`.
echo 999 > "$RESERVE_COUNTER"
rm -f "$LOCK_DIR"/curator-filed-*.json
: > "$AMB"
env \
  PATH="$SHIM_DIR:$PATH" \
  CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_FLEET_STATE="$FS" \
  LOCK_DIR="$LOCK_DIR" \
  REPO_ROOT="$REPO_ROOT" \
  HOME="$TMP" \
  CHUMP_CURATOR_DRY_RUN=1 \
  bash "$CURATOR" --once --dry-run >/dev/null 2>&1

DRY_COUNTER=$(cat "$RESERVE_COUNTER")
[[ "$DRY_COUNTER" == "999" ]] || fail "dry-run advanced reserve counter to $DRY_COUNTER"
ok "dry-run does not invoke chump gap reserve"

grep -q '"action_taken":"dry_run: would file' "$AMB" \
  || fail "dry-run did not record dry_run action_taken"
ok "dry-run records 'dry_run: would file ...' action_taken"

echo
echo "=== test-curator-files-tracking-gaps.sh PASSED ==="
