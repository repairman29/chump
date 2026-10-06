#!/usr/bin/env bash
# RESILIENT-1528: proves check-agent-roles-registered.sh lists positive-path
# --role usages, fails on an unregistered one (the fleet-test omission),
# allowlists negative-test roles, and passes on the real tree.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/check-agent-roles-registered.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

mkdir -p "$T/scripts"
cat > "$T/scripts/positive.sh" <<'S'
chump claim GAP-1 --role fleet-test --skip-doctor
chump claim GAP-2 \
    --role fleet-worker \
    --paths x
# chump claim GAP-3 --role commented-out
chump claim GAP-4 --role "$ROLE"
bash role-card-emit.sh --role not-a-claim --claim GAP-5
S
cat > "$T/scripts/negative.sh" <<'S'
chump claim GAP-9 --role bogus && exit 1
S
printf 'roles:\n  - name: fleet-worker\n  - name: fleet-test\n' > "$T/reg.yaml"
run() { CHECK_AGENT_ROLES_REGISTRY="$T/reg.yaml" CHECK_AGENT_ROLES_SCAN_DIR="$T/scripts" bash "$GATE" "$@" 2>&1; }

list="$(run --list)"
grep -q ' fleet-test$' <<<"$list" && grep -q ' fleet-worker$' <<<"$list" && ok "--list shows single-line and continuation-line usages" || bad "list: $list"
grep -qE 'commented-out|not-a-claim|ROLE' <<<"$list" && bad "list included comment/non-claim/variable usage: $list" || ok "comments, non-claim commands and variable roles are ignored"

out="$(run)"; rc=$?
[[ $rc -eq 0 ]] && ok "passes when all used roles are registered (bogus allowlisted)" || bad "expected pass, got rc=$rc: $out"

# The fleet-test omission: registry without fleet-test must FAIL.
printf 'roles:\n  - name: fleet-worker\n' > "$T/reg.yaml"
out="$(run)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "UNREGISTERED role 'fleet-test'" <<<"$out" && ok "fails when fleet-test is unregistered (the INFRA-5773 omission)" || bad "did not catch missing fleet-test: $out"
grep -q "role 'bogus'" <<<"$out" && bad "bogus should be allowlisted" || ok "negative-test role bogus stays allowlisted"

bash "$GATE" >/dev/null 2>&1 && ok "real tree: every claim --role in scripts/ is registered" || bad "real tree has unregistered roles: $(bash "$GATE" 2>&1 | tail -3)"

echo "=== check-agent-roles-registered: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
