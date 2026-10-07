#!/usr/bin/env bash
# test-private-topology-guard.sh — CI smoke test for RESILIENT-1546
#
# Verifies scripts/git-hooks/pre-commit-private-topology-guard.sh actually
# rejects docs/fleet/nodes/*.json (real node entries) and
# scripts/ops/fleet-nodes.conf re-appearing in the tree, that the allowed
# shape-only examples (example-node.json, README.md, fleet-nodes.conf.example)
# still pass, and that an already-clean tree passes. This test must FAIL if
# the guard script is deleted or made a no-op.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GUARD="$REPO_ROOT/scripts/git-hooks/pre-commit-private-topology-guard.sh"
PASS=0
FAIL=0

_ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

echo "=== private-topology-guard smoke tests ==="

if [[ ! -x "$GUARD" ]]; then
    echo "FATAL: $GUARD not found or not executable" >&2
    exit 2
fi

TMPDIR_FIXTURE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

(
    cd "$TMPDIR_FIXTURE" || exit 1
    git init -q
    git config user.email test@test.local
    git config user.name test
    mkdir -p docs/fleet/nodes scripts/ops
)

# Test 1: a real node registry file must make the guard exit non-zero and
# name INFRA-7881 in its message.
echo '{"node_id":"closetjunky","role":"worker"}' > "$TMPDIR_FIXTURE/docs/fleet/nodes/closetjunky.json"
if (
    cd "$TMPDIR_FIXTURE" || exit 1
    git add docs/fleet/nodes/closetjunky.json
    bash "$GUARD" >/tmp/private-topology-guard-test1.out 2>&1
); then
    _fail "guard should reject a real node registry file (exited 0)"
else
    if grep -q "INFRA-7881" /tmp/private-topology-guard-test1.out 2>/dev/null; then
        _ok "guard rejects real node file and names INFRA-7881"
    else
        _fail "guard exited non-zero but did not name INFRA-7881 in the message"
    fi
fi
(cd "$TMPDIR_FIXTURE" && git reset -q && rm -f docs/fleet/nodes/closetjunky.json)

# Test 2: scripts/ops/fleet-nodes.conf (real, not .example) must also be rejected.
echo "closetjunky:worker:10.0.0.5" > "$TMPDIR_FIXTURE/scripts/ops/fleet-nodes.conf"
if (
    cd "$TMPDIR_FIXTURE" || exit 1
    git add scripts/ops/fleet-nodes.conf
    bash "$GUARD" >/tmp/private-topology-guard-test2.out 2>&1
); then
    _fail "guard should reject scripts/ops/fleet-nodes.conf (exited 0)"
else
    _ok "guard rejects scripts/ops/fleet-nodes.conf"
fi
(cd "$TMPDIR_FIXTURE" && git reset -q && rm -f scripts/ops/fleet-nodes.conf)

# Test 3: allowed shape-only files must pass.
echo '{"node_id":"example","role":"worker"}' > "$TMPDIR_FIXTURE/docs/fleet/nodes/example-node.json"
echo "# fleet node registry" > "$TMPDIR_FIXTURE/docs/fleet/nodes/README.md"
echo "example:worker:0.0.0.0" > "$TMPDIR_FIXTURE/scripts/ops/fleet-nodes.conf.example"
if (
    cd "$TMPDIR_FIXTURE" || exit 1
    git add docs/fleet/nodes/example-node.json docs/fleet/nodes/README.md scripts/ops/fleet-nodes.conf.example
    bash "$GUARD" >/tmp/private-topology-guard-test3.out 2>&1
); then
    _ok "guard passes allowed shape-only examples"
else
    _fail "guard should pass shape-only examples (exited non-zero): $(cat /tmp/private-topology-guard-test3.out)"
fi

# Test 4: clean tree (no fleet/nodes json, no fleet-nodes.conf) passes.
(
    cd "$TMPDIR_FIXTURE" || exit 1
    git rm --cached -q docs/fleet/nodes/example-node.json docs/fleet/nodes/README.md scripts/ops/fleet-nodes.conf.example 2>/dev/null || true
    rm -f docs/fleet/nodes/example-node.json docs/fleet/nodes/README.md scripts/ops/fleet-nodes.conf.example
    echo "hi" > README.md
    git add README.md
)
if (
    cd "$TMPDIR_FIXTURE" || exit 1
    bash "$GUARD" >/tmp/private-topology-guard-test4.out 2>&1
); then
    _ok "guard passes a clean tree with no private topology files"
else
    _fail "guard should pass clean tree: $(cat /tmp/private-topology-guard-test4.out)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
