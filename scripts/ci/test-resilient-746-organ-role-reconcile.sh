#!/usr/bin/env bash
# test-resilient-746-organ-role-reconcile.sh — RESILIENT-746
#
# Proves the ORGANS phase of chump-node-install.sh actually installs the
# role's organ set from scripts/ops/organ-manifest.txt instead of stopping at
# the two hand-coded organs (node-heartbeat, process-organ-heal) — the exact
# half-built hole from the helsinki teardown (docs/process/COTG_NODE_INSTALL.md
# says ORGANS installs "the role's organ set... from a manifest"; the code
# never called the manifest-driven reconciler until this ship).
#
# Two properties, both of which FAIL without this change:
#   1. scripts/ops/organ-reconcile.sh honors CHUMP_ORGAN_RECONCILE_ROLE — a
#      comma-separated role= filter that scopes which `enabled` manifest
#      lines it touches (empty/unset = all roles, back-compat).
#   2. chump-node-install.sh's install_organs() calls organ-reconcile.sh
#      --apply, scoped by --role brain|muscle|all via organ_role_filter().
#
# Network-free + deterministic: organ-reconcile.sh is driven with a stubbed
# systemctl (mirrors test-organ-reconcile.sh's harness); chump-node-install.sh
# is sourced (BASH_SOURCE guard keeps its top-level run from firing) and
# install_organs()/organ_role_filter() are invoked directly in --dry-run mode.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

[ -f "$RECONCILE" ] || { echo "FAIL: missing $RECONCILE"; exit 1; }
[ -f "$INSTALLER" ] || { echo "FAIL: missing $INSTALLER"; exit 1; }
bash -n "$RECONCILE" || { echo "FAIL: organ-reconcile.sh syntax"; exit 1; }
bash -n "$INSTALLER" || { echo "FAIL: chump-node-install.sh syntax"; exit 1; }

echo "=== test-resilient-746-organ-role-reconcile.sh ==="

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-r746-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── 1. organ-reconcile.sh: CHUMP_ORGAN_RECONCILE_ROLE scopes ENABLED units ──
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
ACTIVE_FILE="$STATE_DIR/active.txt"; touch "$ACTIVE_FILE"
CALL_LOG="$TMP/calls.log"

STUB="$TMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    is-active)
        unit="${@: -1}"
        grep -qxF "$unit" "$ACTIVE_FILE" 2>/dev/null && exit 0 || exit 3
        ;;
    enable)
        unit="${@: -1}"
        echo "$unit" >> "$ACTIVE_FILE"
        exit 0
        ;;
    disable|stop|daemon-reload)
        exit 0
        ;;
    show)
        echo "ExecStart=/bin/true"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$STUB"

MANIFEST="$TMP/manifest-roles.txt"
cat > "$MANIFEST" <<'EOF'
enabled  chump-brain-organ.service   role=brain
enabled  chump-muscle-organ.service  role=muscle
enabled  chump-data-organ.service    role=data
EOF

BACKOFF_DIR="$TMP/organ-backoff"
AMBIENT="$TMP/ambient.jsonl"

run_reconcile() {  # role-filter, mode
  : > "$CALL_LOG"
  CHUMP_ORGAN_RECONCILE_ROLE="$1" \
  CALL_LOG="$CALL_LOG" \
  ACTIVE_FILE="$ACTIVE_FILE" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
  CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR" \
  CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
  CHUMP_ORGAN_MANIFEST="$MANIFEST" \
  NODE_AMBIENT="$AMBIENT" \
  bash "$RECONCILE" "$2"
}

# 1a. role filter "muscle" -> only the muscle-tagged unit is touched.
: > "$ACTIVE_FILE"; rm -rf "$BACKOFF_DIR"; : > "$AMBIENT"
run_reconcile "muscle" --apply >/dev/null
grep -q "enable --now chump-muscle-organ.service" "$CALL_LOG" \
  || fail "role filter 'muscle' should enable the muscle-tagged organ; calls: $(cat "$CALL_LOG")"
grep -q "enable --now chump-brain-organ.service" "$CALL_LOG" \
  && fail "role filter 'muscle' must NOT touch the brain-tagged organ; calls: $(cat "$CALL_LOG")"
grep -q "enable --now chump-data-organ.service" "$CALL_LOG" \
  && fail "role filter 'muscle' must NOT touch the data-tagged organ; calls: $(cat "$CALL_LOG")"
pass "1a: CHUMP_ORGAN_RECONCILE_ROLE=muscle scopes --apply to only the muscle-tagged unit"

# 1b. role filter "brain,data" (a multi-role list, as --role brain maps to) ──
: > "$ACTIVE_FILE"; rm -rf "$BACKOFF_DIR"; : > "$AMBIENT"
run_reconcile "brain,data" --apply >/dev/null
grep -q "enable --now chump-brain-organ.service" "$CALL_LOG" \
  || fail "role filter 'brain,data' should enable the brain-tagged organ"
grep -q "enable --now chump-data-organ.service" "$CALL_LOG" \
  || fail "role filter 'brain,data' should enable the data-tagged organ"
grep -q "enable --now chump-muscle-organ.service" "$CALL_LOG" \
  && fail "role filter 'brain,data' must NOT touch the muscle-tagged organ"
pass "1b: a comma-separated role filter enables every listed role's organs and nothing else"

# 1c. empty/unset role filter -> back-compat, every enabled unit is touched ──
: > "$ACTIVE_FILE"; rm -rf "$BACKOFF_DIR"; : > "$AMBIENT"
run_reconcile "" --apply >/dev/null
for unit in chump-brain-organ.service chump-muscle-organ.service chump-data-organ.service; do
  grep -q "enable --now $unit" "$CALL_LOG" \
    || fail "empty role filter must reconcile every unit (back-compat); missing $unit"
done
pass "1c: empty CHUMP_ORGAN_RECONCILE_ROLE reconciles the whole manifest (back-compat)"

# 1d. --check mode also honors the role filter (used by SELF-TEST) ─────────
: > "$ACTIVE_FILE"; rm -rf "$BACKOFF_DIR"
out="$(run_reconcile "muscle" --check)"
echo "$out" | grep -q "chump-muscle-organ.service" \
  || fail "--check with role filter 'muscle' should report on the muscle organ; got: $out"
echo "$out" | grep -q "chump-brain-organ.service" \
  && fail "--check with role filter 'muscle' must not mention the brain organ; got: $out"
pass "1d: --check mode (SELF-TEST's path) also scopes to the role filter"

# ── 2. chump-node-install.sh: install_organs() wires --role -> role filter
#       -> organ-reconcile.sh --apply (the actual ORGANS-phase fix) ─────────
export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/nodestate"
mkdir -p "$CHUMP_NODE_DIR/bin" "$CHUMP_NODE_DIR/organs" "$CHUMP_NODE_DIR/logs"

check_role_wiring() {  # --role value, expected filter substring (or "" for none)
  local role="$1" want="$2"
  set -- --role "$role" --dry-run
  # shellcheck disable=SC1090
  . "$INSTALLER"
  local out; out="$(install_organs 2>&1)"
  if ! printf '%s\n' "$out" | grep -q "organ-reconcile.sh' --apply"; then
    fail "install_organs (--role $role) never invokes organ-reconcile.sh --apply; got: $out"
    return
  fi
  if [ -n "$want" ]; then
    printf '%s\n' "$out" | grep -q "CHUMP_ORGAN_RECONCILE_ROLE='$want'" \
      || fail "install_organs (--role $role) should scope with CHUMP_ORGAN_RECONCILE_ROLE='$want'; got: $out"
  else
    printf '%s\n' "$out" | grep -q "CHUMP_ORGAN_RECONCILE_ROLE=''" \
      || fail "install_organs (--role $role) should pass an empty role filter (all roles); got: $out"
  fi
  pass "install_organs --role $role wires organ-reconcile.sh with role filter '${want:-<all>}'"
}

check_role_wiring brain "brain,data,janitor,trust"
check_role_wiring muscle "muscle"
check_role_wiring all ""

echo
if [ "$fails" -eq 0 ]; then echo "PASS: RESILIENT-746 organ-role reconcile wiring holds ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
