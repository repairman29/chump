#!/usr/bin/env bash
# scripts/ci/test-queue-tender.sh — META-243
# 7 tests for the queue-tender loop, installer, and lane discipline.
set -uo pipefail

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOOP="$REPO_ROOT/scripts/coord/queue-tender-loop.sh"
INSTALL="$REPO_ROOT/scripts/setup/install-queue-tender.sh"
PLIST="$REPO_ROOT/scripts/launchd/com.chump.queue-tender.plist"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "=== META-243: queue-tender tests ==="

# 1. Files exist; loop is executable with tick/heartbeat/help; plist StartInterval=300.
if [[ -x "$LOOP" && -f "$PLIST" ]] \
   && grep -A1 '<key>StartInterval</key>' "$PLIST" | grep -q '<integer>300</integer>' \
   && bash "$LOOP" help | grep -q 'tick' && bash "$LOOP" help | grep -q 'heartbeat'; then
    ok "1: loop executable with help; plist StartInterval=300"
else bad "1: loop/plist shape wrong"; fi

# 2. tick emits kind=queue_tend_tick; heartbeat emits queue_tend_heartbeat.
AMB="$TMP/amb.jsonl"; printf '5\tCLEAN\n' > "$TMP/prs.txt"
CHUMP_AMBIENT_LOG="$AMB" CHUMP_QUEUE_TENDER_PR_FIXTURE="$TMP/prs.txt" CHUMP_QUEUE_TENDER_STATE_DIR="$TMP/st" bash "$LOOP" tick >/dev/null 2>&1
CHUMP_AMBIENT_LOG="$AMB" bash "$LOOP" heartbeat >/dev/null 2>&1
if grep -q '"kind":"queue_tend_tick"' "$AMB" && grep -q '"kind":"queue_tend_heartbeat"' "$AMB"; then
    ok "2: tick emits queue_tend_tick, heartbeat emits queue_tend_heartbeat"
else bad "2: expected events missing"; fi

# 3. CHUMP_SKIP_QUEUE_TENDER=1 exits 0 immediately and emits nothing.
AMB3="$TMP/amb3.jsonl"
if CHUMP_SKIP_QUEUE_TENDER=1 CHUMP_AMBIENT_LOG="$AMB3" bash "$LOOP" tick >/dev/null 2>&1 && [[ ! -s "$AMB3" ]]; then
    ok "3: CHUMP_SKIP_QUEUE_TENDER=1 exits 0 with no work"
else bad "3: skip switch did not short-circuit"; fi

# 4. Dry-run tick sees BEHIND PRs and reports intent (does not need gh).
printf '7\tBEHIND\n8\tCLEAN\n9\tBEHIND\n' > "$TMP/prs4.txt"
out="$(CHUMP_AMBIENT_LOG="$TMP/a4.jsonl" CHUMP_QUEUE_TENDER_PR_FIXTURE="$TMP/prs4.txt" CHUMP_QUEUE_TENDER_STATE_DIR="$TMP/st4" bash "$LOOP" tick 2>&1)"
if grep -q 'would update-branch #7' <<<"$out" && grep -q 'would update-branch #9' <<<"$out" && ! grep -q '#8' <<<"$out" \
   && grep -q '"behind":2' "$TMP/a4.jsonl"; then
    ok "4: dry-run tick targets only BEHIND PRs"
else bad "4: dry-run classification wrong: $out"; fi

# 5. Hysteresis: a PR updated within 5 min is held, not re-updated.
mkdir -p "$TMP/st5"; date +%s > "$TMP/st5/pr-7.ts"
printf '7\tBEHIND\n' > "$TMP/prs5.txt"
out="$(CHUMP_AMBIENT_LOG="$TMP/a5.jsonl" CHUMP_QUEUE_TENDER_PR_FIXTURE="$TMP/prs5.txt" CHUMP_QUEUE_TENDER_STATE_DIR="$TMP/st5" bash "$LOOP" tick 2>&1)"
if grep -q 'hold: #7' <<<"$out" && grep -q '"updated":0' "$TMP/a5.jsonl" && grep -q '"held":1' "$TMP/a5.jsonl"; then
    ok "5: hysteresis holds a recently-tended PR"
else bad "5: hysteresis failed: $out"; fi
echo $(( $(date +%s) - 400 )) > "$TMP/st5/pr-7.ts"
out="$(CHUMP_AMBIENT_LOG="$TMP/a5b.jsonl" CHUMP_QUEUE_TENDER_PR_FIXTURE="$TMP/prs5.txt" CHUMP_QUEUE_TENDER_STATE_DIR="$TMP/st5" bash "$LOOP" tick 2>&1)"
if grep -q 'would update-branch #7' <<<"$out"; then ok "5b: PR eligible again after hysteresis window"; else bad "5b: still held after window: $out"; fi

# 6. Installer install/status/check/uninstall are idempotent (no launchctl).
export CHUMP_QT_LAUNCH_AGENTS_DIR="$TMP/agents" CHUMP_QT_NO_LAUNCHCTL=1
r=0
bash "$INSTALL" check >/dev/null 2>&1 && r=1                       # not installed -> must fail
bash "$INSTALL" install >/dev/null 2>&1 || r=1
bash "$INSTALL" install >/dev/null 2>&1 || r=1                     # idempotent
bash "$INSTALL" check  >/dev/null 2>&1 || r=1
bash "$INSTALL" status | grep -q 'plist: installed' || r=1
grep -q '__REPO_ROOT__\|__HOME__' "$TMP/agents/com.chump.queue-tender.plist" && r=1   # placeholders rendered
bash "$INSTALL" uninstall >/dev/null 2>&1 || r=1
bash "$INSTALL" uninstall >/dev/null 2>&1 || r=1                   # idempotent
bash "$INSTALL" check >/dev/null 2>&1 && r=1
if [[ $r -eq 0 ]]; then ok "6: installer install/uninstall/status/check idempotent"; else bad "6: installer behavior wrong"; fi
unset CHUMP_QT_LAUNCH_AGENTS_DIR CHUMP_QT_NO_LAUNCHCTL

# 7. Lane discipline + role files: no admin-bypass merge in source; agent/skill/doctrine exist.
if ! grep -rEn 'pr merge[^#]*--admin|--admin[^#]*pr merge' "$LOOP" "$INSTALL" "$PLIST" \
   && [[ -f "$REPO_ROOT/.claude/agents/curator-opus-queue-tender.md" \
      && -f "$REPO_ROOT/.claude/skills/queue-tender/SKILL.md" \
      && -f "$REPO_ROOT/docs/process/QUEUE_TENDER_DOCTRINE.md" ]]; then
    ok "7: lane discipline holds; agent, skill and doctrine present"
else bad "7: admin-bypass found or role files missing"; fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
