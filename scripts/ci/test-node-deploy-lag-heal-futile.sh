#!/usr/bin/env bash
# INFRA-8052: node-deploy-lag-watchdog must stop restart-looping a refresh unit
# that runs but leaves the binary stale, and escalate instead.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WD="$REPO_ROOT/scripts/coord/node-deploy-lag-watchdog.sh"
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# A throwaway repo whose origin/main is old (lag far past SLO) and a binary at another sha.
git init -q "$T/origin"; git -C "$T/origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c --date="2020-01-01T00:00:00"
GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$T/origin" -c user.email=t@t -c user.name=t commit -q --amend --allow-empty -m c --date="2020-01-01T00:00:00"
git clone -q "$T/origin" "$T/repo" 2>/dev/null
git -C "$T/repo" branch -q -M main 2>/dev/null; git -C "$T/origin" branch -q -M main 2>/dev/null
git -C "$T/repo" fetch -q origin main 2>/dev/null
printf '#!/usr/bin/env bash\necho "chump 0.1 (deadbeef0000 built x)"\n' > "$T/chump"
cat > "$T/systemctl" <<SC
#!/usr/bin/env bash
case "\$*" in *restart*) echo r >> "$T/restarts" ;; esac
exit 0
SC
printf '#!/usr/bin/env bash\necho "$@" >> "%s/routed"\n' "$T" > "$T/duty"
chmod +x "$T/chump" "$T/systemctl" "$T/duty"
mkdir -p "$T/repo/.chump-locks"

run() {
  CHUMP_REPO_ROOT="$T/repo" CHUMP_NODE_BIN="$T/chump" CHUMP_NODE_DEPLOY_LAG_SYSTEMCTL_BIN="$T/systemctl" \
  CHUMP_DUTY_OFFICER_BIN="$T/duty" CHUMP_NODE_DEPLOY_LAG_MAX_RESTARTS=2 bash "$WD" >/dev/null 2>&1
}
run; run; run; run
n=$(wc -l < "$T/restarts" 2>/dev/null || echo 0)
[[ "$n" -eq 2 ]] && pass "unit restarted exactly MAX_RESTARTS times, then no more" || fail "restart count=$n (want 2)"
grep -q node_deploy_heal_futile "$T/repo/.chump-locks/ambient.jsonl" && pass "node_deploy_heal_futile emitted" || fail "no heal_futile event"
grep -q "node_deploy_heal_futile" "$T/routed" 2>/dev/null && pass "escalation routed to duty officer" || fail "not routed to duty officer"

echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
