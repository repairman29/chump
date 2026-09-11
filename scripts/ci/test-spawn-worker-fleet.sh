#!/usr/bin/env bash
# test-spawn-worker-fleet.sh — INFRA-471
#
# Regression test for the reproducible multi-worker / model-class provisioning
# tool (scripts/dispatch/spawn-worker-fleet.sh) and its template wiring.
#
# The failure this guards: a node ran ONE FLEET_MODEL=sonnet worker on a
# 1907-gap backlog; the picker's model-class gate makes a sonnet worker refuse
# effort=xs, so the 883 xs gaps (46% of the backlog) were unpickable and the
# node starved. The fix is a tool that (a) renders a haiku/xs instance that eats
# that backlog and (b) sizes instance count to cores — both from a TRACKED
# template, never hand-set on the node.
#
# Asserts (all network-free + no writes to the real $HOME):
#   1. the launcher template carries the __FLEET_MODEL__/__FLEET_EFFORT_FILTER__
#      placeholders, and a sed-render substitutes them into real exports.
#   2. the default model mix makes instance-1 a haiku/xs xs-eater.
#   3. CHUMP_WORKER_COUNT sizes the fleet; a custom CHUMP_WORKER_MODEL_MIX is
#      honored and assigned round-robin.
#   4. --print-units emits one systemd unit per instance whose ExecStart points
#      at that instance's rendered launcher.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL="$REPO_ROOT/scripts/dispatch/spawn-worker-fleet.sh"
TEMPLATE="$REPO_ROOT/scripts/dispatch/worker-launcher.template.sh"

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-spawn-worker-fleet.sh (INFRA-471) ==="

[ -f "$TOOL" ]     || fail "tool missing: $TOOL"
[ -x "$TOOL" ]     || fail "tool not executable: $TOOL"
[ -f "$TEMPLATE" ] || fail "template missing: $TEMPLATE"

# ── 1. template placeholders + a real render substitutes them ───────────────
grep -q '__FLEET_MODEL__'         "$TEMPLATE" && pass "template has __FLEET_MODEL__"         || fail "template missing __FLEET_MODEL__"
grep -q '__FLEET_EFFORT_FILTER__' "$TEMPLATE" && pass "template has __FLEET_EFFORT_FILTER__" || fail "template missing __FLEET_EFFORT_FILTER__"

RENDERED="$(sed \
  -e 's|__AGENT_ID__|n-worker-1|g' \
  -e 's|__WORKER_MACHINE__|n|g' \
  -e 's|__FLEET_SESSION__|n|g' \
  -e 's|__WORKER_SKILLS__||g' \
  -e 's|__FLEET_DOMAIN_FILTER__||g' \
  -e 's|__REPO_ROOT__|/tmp/x|g' \
  -e 's|__FLEET_MODEL__|haiku|g' \
  -e 's|__FLEET_EFFORT_FILTER__|xs|g' \
  "$TEMPLATE")"
echo "$RENDERED" | grep -Eq 'FLEET_MODEL="\$\{FLEET_MODEL:-haiku\}"' \
  && pass "render substitutes FLEET_MODEL=haiku" || fail "render did not substitute FLEET_MODEL"
echo "$RENDERED" | grep -Eq 'FLEET_EFFORT_FILTER="\$\{FLEET_EFFORT_FILTER:-xs\}"' \
  && pass "render substitutes FLEET_EFFORT_FILTER=xs" || fail "render did not substitute FLEET_EFFORT_FILTER"
echo "$RENDERED" | grep -q '__[A-Z_]*__' \
  && fail "rendered launcher still has unsubstituted placeholder(s)" \
  || pass "no leftover placeholders after render"

# ── 2. default mix: instance-1 is a haiku/xs xs-eater ───────────────────────
OUT="$(cd "$REPO_ROOT" && CHUMP_WORKER_COUNT=4 bash "$TOOL" 2>&1)"
echo "$OUT" | grep -Eq 'worker-1 +model=haiku +effort=xs' \
  && pass "instance-1 is haiku/xs (eats the xs backlog sonnet refuses)" \
  || fail "instance-1 is not haiku/xs; got: $(echo "$OUT" | grep worker-1)"
echo "$OUT" | grep -Eq 'worker-2 +model=sonnet +effort=s,m,l' \
  && pass "instance-2 is sonnet/s,m,l" || fail "instance-2 not sonnet/s,m,l"

# ── 3. count sizing + custom mix round-robin ────────────────────────────────
N="$(echo "$OUT" | grep -cE 'worker-[0-9]+ +model=')"
[ "$N" -eq 4 ] && pass "CHUMP_WORKER_COUNT=4 produced 4 instances" || fail "expected 4 instances, got $N"

OUT2="$(cd "$REPO_ROOT" && CHUMP_WORKER_COUNT=2 CHUMP_WORKER_MODEL_MIX='opus:m,l;haiku:xs' bash "$TOOL" 2>&1)"
echo "$OUT2" | grep -Eq 'worker-1 +model=opus +effort=m,l'  && pass "custom mix entry-1 (opus/m,l) honored"  || fail "custom mix entry-1 wrong"
echo "$OUT2" | grep -Eq 'worker-2 +model=haiku +effort=xs' && pass "custom mix entry-2 (haiku/xs) honored" || fail "custom mix entry-2 wrong"

# ── 4. --print-units emits a unit per instance -> its own launcher ──────────
UNITS="$(cd "$REPO_ROOT" && CHUMP_WORKER_COUNT=2 CHUMP_WORKER_AGENT_PREFIX=tnode-worker bash "$TOOL" --print-units 2>&1)"
u="$(echo "$UNITS" | grep -c '==> /etc/systemd/system/chump-tnode-worker-')"
[ "$u" -eq 2 ] && pass "--print-units emitted 2 unit headers" || fail "expected 2 unit headers, got $u"
echo "$UNITS" | grep -q 'ExecStart=/usr/bin/env bash .*worker-tnode-worker-1.sh' \
  && pass "unit ExecStart points at instance-1 rendered launcher" || fail "unit ExecStart wrong for instance-1"

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: spawn-worker-fleet (0 failures)"; exit 0
else
  echo "FAIL: spawn-worker-fleet ($fails failure(s))"; exit 1
fi
