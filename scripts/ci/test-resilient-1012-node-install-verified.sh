#!/usr/bin/env bash
# scripts/ci/test-resilient-1012-node-install-verified.sh — RESILIENT-1012
#
# Proves two properties, both of which FAIL without this change:
#
#   1. scripts/ops/organ-reconcile.sh's new `--counts` mode reports
#      machine-readable active-vs-expected organ counts (role-scoped, honors
#      CHUMP_ORGAN_RECONCILE_ROLE and `requires=` applicability the same way
#      --check does) — this is what self_test() reads to build the
#      node_install_verified signal's active_organs/expected_organs fields.
#
#   2. chump-node-install.sh's self_test() emits a `kind=node_install_verified`
#      ambient event carrying host/role/pass/active_organs/expected_organs —
#      the "fresh node self-reports came-up-0-failed-mirroring-roster" signal
#      this gap exists to add. Before this change self_test() emitted nothing
#      to ambient.jsonl at all; the ONLY proof a node installed correctly was
#      a human SSHing in and eyeballing systemctl.
#
# Network-free + deterministic: organ-reconcile.sh driven with a stubbed
# systemctl; chump-node-install.sh is sourced (BASH_SOURCE guard keeps its
# top-level run from firing) and self_test() is invoked directly against a
# synthetic NODE_DIR/STATE_DIR so no real host state is touched.
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

echo "=== test-resilient-1012-node-install-verified.sh ==="

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-r1012-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── 1. organ-reconcile.sh --counts: active-vs-expected, role-scoped ────────
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
ACTIVE_FILE="$STATE_DIR/active.txt"

STUB="$TMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    is-active)
        unit="${@: -1}"
        grep -qxF "$unit" "$ACTIVE_FILE" 2>/dev/null && exit 0 || exit 3
        ;;
    show) echo "ExecStart=/bin/true"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$STUB"

MANIFEST="$TMP/manifest-counts.txt"
cat > "$MANIFEST" <<'EOF'
enabled  chump-brain-a.service   role=brain
enabled  chump-brain-b.service   role=brain
enabled  chump-muscle-a.service  role=muscle
EOF

run_counts() {  # role-filter
  CHUMP_ORGAN_RECONCILE_ROLE="$1" \
  ACTIVE_FILE="$ACTIVE_FILE" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
  CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/backoff" \
  CHUMP_ORGAN_MANIFEST="$MANIFEST" \
  NODE_AMBIENT="$TMP/ambient-unused.jsonl" \
  bash "$RECONCILE" --counts
}

# Only one of the two brain-role organs is active.
printf 'chump-brain-a.service\n' > "$ACTIVE_FILE"
out="$(run_counts "brain")"
echo "$out" | grep -q '"active":1' || fail "expected active=1 for role=brain, got: $out"
echo "$out" | grep -q '"expected":2' || fail "expected expected=2 for role=brain (2 brain-tagged units), got: $out"
pass "1a: --counts reports active=1 expected=2 for a role with 1/2 organs up"

# Muscle role: 0 of 1 up.
: > "$ACTIVE_FILE"
out="$(run_counts "muscle")"
echo "$out" | grep -q '"active":0' || fail "expected active=0 for role=muscle with nothing up, got: $out"
echo "$out" | grep -q '"expected":1' || fail "expected expected=1 for role=muscle (1 muscle-tagged unit), got: $out"
pass "1b: --counts scopes to the role filter (muscle) independently of brain"

# ── 2. chump-node-install.sh self_test() emits node_install_verified ───────
FAKE_NODE_DIR="$TMP/chumpnode"
FAKE_STATE_DIR="$TMP/chumphome"
mkdir -p "$FAKE_NODE_DIR/repo/.chump-locks" "$FAKE_NODE_DIR/repo/scripts/ops" "$FAKE_STATE_DIR"
AMBIENT="$FAKE_NODE_DIR/repo/.chump-locks/ambient.jsonl"
: > "$AMBIENT"
cp "$RECONCILE" "$FAKE_NODE_DIR/repo/scripts/ops/organ-reconcile.sh"

(
  export CHUMP_NODE_DIR="$FAKE_NODE_DIR" CHUMP_STATE_DIR="$FAKE_STATE_DIR"
  export CHUMP_STATE_DB="$FAKE_STATE_DIR/state.db"
  export CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB"
  export CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1
  export ACTIVE_FILE="$TMP/active-2.txt"
  : > "$ACTIVE_FILE"
  export CHUMP_ORGAN_MANIFEST="$FAKE_NODE_DIR/repo/scripts/ops/organ-manifest.txt"
  cp "$MANIFEST" "$CHUMP_ORGAN_MANIFEST"
  # Source the installer without letting its top-level run fire (BASH_SOURCE
  # guard) — --self-test-only just sets SELF_TEST_ONLY=1 as a side effect.
  source "$INSTALLER" --self-test-only >/dev/null 2>&1 || true
  detect_host >/dev/null 2>&1 || true
  self_test >/dev/null 2>&1 || true
)

grep -q '"kind":"node_install_verified"' "$AMBIENT" \
  || fail "self_test() did not emit a node_install_verified ambient event; ambient.jsonl: $(cat "$AMBIENT")"
pass "2a: self_test() emits kind=node_install_verified"

line="$(grep '"kind":"node_install_verified"' "$AMBIENT" | tail -1)"
echo "$line" | grep -q '"host":"' || fail "node_install_verified event missing host field: $line"
echo "$line" | grep -qE '"pass":(true|false)' || fail "node_install_verified event missing boolean pass field: $line"
echo "$line" | grep -qE '"active_organs":[0-9]+' || fail "node_install_verified event missing active_organs field: $line"
echo "$line" | grep -qE '"expected_organs":[0-9]+' || fail "node_install_verified event missing expected_organs field: $line"
pass "2b: emitted event carries host/pass/active_organs/expected_organs"

# ── 3. EVENT_REGISTRY.yaml declares the new kind (INFRA-754 guard) ─────────
grep -q '^\s*- kind: node_install_verified$' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
  || fail "docs/observability/EVENT_REGISTRY.yaml missing 'kind: node_install_verified' entry"
pass "3: node_install_verified is registered in EVENT_REGISTRY.yaml"

echo
if [ "$fails" -eq 0 ]; then
  echo "=== ALL PASS ==="
  exit 0
else
  echo "=== $fails FAILURE(S) ==="
  exit 1
fi
