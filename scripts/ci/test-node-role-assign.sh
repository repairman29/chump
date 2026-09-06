#!/usr/bin/env bash
# scripts/ci/test-node-role-assign.sh — RESILIENT-1031
#
# Proves the placement kernel: node-role-assign.sh reads each node's declared
# capability + roles_fit (from node-describe.sh) and ASSIGNS + PERSISTS a
# role_assigned of brain/muscle/gpu-embed/operator into the node's JSON file
# in docs/fleet/nodes/. Without this script, nothing ever writes
# role_assigned — every assertion below fails on main pre-RESILIENT-1031
# (the script does not exist).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ASSIGNER="$REPO_ROOT/scripts/dispatch/node-role-assign.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-node-role-assign.sh (RESILIENT-1031) ==="

[[ -f "$ASSIGNER" ]] || fail "node-role-assign.sh missing: $ASSIGNER"
[[ -x "$ASSIGNER" ]] || fail "node-role-assign.sh not executable"
bash -n "$ASSIGNER" || fail "node-role-assign.sh bash -n failed"
pass "script present, executable, syntax clean"

command -v jq >/dev/null 2>&1 || fail "jq required for this test"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NODES_DIR="$WORK/nodes"
mkdir -p "$NODES_DIR"

# ── fixture: gpu-embed node (has GPU fit) ───────────────────────────────────
cat > "$NODES_DIR/gpu.json" <<'EOF'
{
  "node_id": "gpu-node",
  "hardware": {"always_on": true},
  "roles_fit": ["gpu-embed","gpu-inference-small","build-worker","ci-runner","atc-heartbeat","broker"]
}
EOF

# ── fixture: brain node (always-on coordinator, no GPU) ─────────────────────
cat > "$NODES_DIR/brain.json" <<'EOF'
{
  "node_id": "brain-node",
  "hardware": {"always_on": true},
  "roles_fit": ["build-worker","ci-runner","atc-heartbeat","broker"]
}
EOF

# ── fixture: muscle node (always-on workhorse, no broker/heartbeat fit) ─────
cat > "$NODES_DIR/muscle.json" <<'EOF'
{
  "node_id": "muscle-node",
  "hardware": {"always_on": true},
  "roles_fit": ["build-worker","ci-runner"]
}
EOF

# ── fixture: operator node (laptop, sleeps) ─────────────────────────────────
cat > "$NODES_DIR/operator.json" <<'EOF'
{
  "node_id": "operator-node",
  "hardware": {"always_on": false},
  "roles_fit": ["build-worker","ci-runner","atc-interactive"]
}
EOF

# ── 1. --apply assigns the expected role per node and persists it ──────────
"$ASSIGNER" --apply --dir "$NODES_DIR" >/tmp/node-role-assign.out 2>&1 \
  || fail "assigner --apply exited non-zero: $(cat /tmp/node-role-assign.out)"

check_role() {
  local file="$1" expect="$2" got
  got="$(jq -r '.role_assigned // empty' "$file")"
  [[ "$got" == "$expect" ]] || fail "$file: expected role_assigned=$expect, got '$got'"
  pass "$file -> role_assigned=$got"
}
check_role "$NODES_DIR/gpu.json" "gpu-embed"
check_role "$NODES_DIR/brain.json" "brain"
check_role "$NODES_DIR/muscle.json" "muscle"
check_role "$NODES_DIR/operator.json" "operator"

# ── 2. persistence preserves other fields (non-destructive merge) ──────────
node_id_still_there="$(jq -r '.node_id' "$NODES_DIR/gpu.json")"
[[ "$node_id_still_there" == "gpu-node" ]] || fail "apply clobbered unrelated fields"
pass "apply preserves existing fields (non-destructive merge)"

# ── 3. --check reports no drift after --apply (idempotent) ─────────────────
"$ASSIGNER" --check --dir "$NODES_DIR" >/tmp/node-role-check.out 2>&1
rc=$?
[[ $rc -eq 0 ]] || fail "--check reported drift right after --apply: $(cat /tmp/node-role-check.out)"
pass "--check is clean immediately after --apply (idempotent)"

# ── 4. --check detects drift when persisted role diverges from computed ────
tmp="$NODES_DIR/gpu.json.tmp"
jq '.role_assigned = "operator"' "$NODES_DIR/gpu.json" > "$tmp" && mv "$tmp" "$NODES_DIR/gpu.json"
"$ASSIGNER" --check --dir "$NODES_DIR" >/tmp/node-role-drift.out 2>&1
rc=$?
[[ $rc -ne 0 ]] || fail "--check did not detect a forced drift"
grep -q "DRIFT gpu-node" /tmp/node-role-drift.out || fail "--check output missing DRIFT line: $(cat /tmp/node-role-drift.out)"
pass "--check detects drift and exits non-zero"

# ── 5. --host filters to a single node ──────────────────────────────────────
jq '.role_assigned = "operator"' "$NODES_DIR/muscle.json" > "$tmp" && mv "$tmp" "$NODES_DIR/muscle.json"
"$ASSIGNER" --apply --dir "$NODES_DIR" --host "muscle-node" >/dev/null 2>&1
check_role "$NODES_DIR/muscle.json" "muscle"
still_wrong="$(jq -r '.role_assigned' "$NODES_DIR/gpu.json")"
[[ "$still_wrong" == "operator" ]] || fail "--host filter processed a non-matching node too"
pass "--host filters processing to the matching node_id only"

echo "=== test-node-role-assign.sh: ALL PASS ==="
